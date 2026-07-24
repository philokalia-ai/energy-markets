# Build a self-contained DuckDB extract (and a canonical parquet directory) of
# the market data the Euphemia library reads, so single-zone merit-order pricing,
# scenario analysis AND the full 39-zone multi-zone EU clearing run fully offline
# with no Postgres. The extract mirrors the same `schema.table` names, with every
# `timestamp with time zone` column converted to naive UTC (`... AT TIME ZONE
# 'UTC'`) — exactly what the DuckDB dialect rewrite in src/dbutils.jl assumes.
#
# Two artifacts are written from one Postgres read:
#   1. a runtime  <OUT>.duckdb  (materialized DuckDB database)
#   2. a canonical <PARQUET_DIR>/<schema>.<table>.parquet dir (zstd) — the
#      ENGINE-VERSION-DURABLE format that gets published. `bin/build_duckdb_from_parquet.jl`
#      rebuilds a bit-identical .duckdb from the parquet dir on any machine.
# Plus SHA256SUMS + MANIFEST.json describing the artifact.
#
# Usage (all via env vars):
#   # SEE 5-zone single-zone pricing
#   ZONES="GR,BG,RO,RS,HU" START_DATE=2026-01-01 END_DATE=2026-06-30 \
#     OUT=data/extracts/euphemia_2026_see.duckdb \
#     julia --project=. bin/build_duckdb_extract.jl
#
#   # The PUBLIC reproducibility artifact: 39 EU zones, 2023-01-01..2026-06-30
#   ZONES="AT,BE,BG,CZ,DE_LU,DK1,DK2,EE,ES,FI,FR,GR,HU,LT,LV,NL,NO1,NO2,NO3,NO4,NO5,PL,PT,RO,RS,SE1,SE2,SE3,SE4,SI,SK,IT-NORTH,IT-CNORTH,IT-CSOUTH,IT-SOUTH,IT-Calabria,IT-Sicily,IT-Sardinia,CH" \
#     START_DATE=2023-01-01 END_DATE=2026-06-30 AGEN_BACK_DAYS=400 \
#     OUT=data/public/euphemia-public.duckdb \
#     PARQUET_DIR=data/public/euphemia-data-v1 \
#     ARTIFACT_VERSION=v1 MAX_SIZE_GB=12 \
#     julia --project=. bin/build_duckdb_extract.jl
#
# Reads from Postgres: `entsoe.*` / `yfinance.*` / `simulations.*` via the
# normal .env ENERGY_CONN_STR, and (when WEATHER_CONN_STR is set) the `weather`
# schema from the SEPARATE weather database — `city` (full),
# `city_forecast` (last WEATHER_BACK_DAYS, default 400), `city_forecast_vintage`
# (full). Set INCLUDE_WEATHER=false to skip the weather schema explicitly.
#
# Optionally seeds `weather.cell_hourly` (zone, lat, lon, h, v100, ghi, source)
# from CELL_HOURLY_CSV — the ERA5 feature history at the wind-catalogue cells
# that the weather-RES models (bin/res_models_v1.json) were fitted on; filtered
# to ZONES. bin/refresh_duckdb_extract.jl keeps it current from the public
# open-meteo archive API.
#
# The DuckDB backend the extract feeds is READ-ONLY in the library (writes
# route to a separate data/results.duckdb; see src/dbutils.jl). Shared helpers
# (table specs, naive-UTC projection, chunked build) live in
# bin/extract_common.jl and are reused by bin/refresh_duckdb_extract.jl.

# The builder must read the LIVE Postgres, never an auto-detected local extract.
haskey(ENV, "EUPHEMIA_DATA_STORE") || (ENV["EUPHEMIA_DATA_STORE"] = "postgres")

using Euphemia
using DataFrames
using Dates
using DuckDB
using Printf
using SHA

include(joinpath(@__DIR__, "extract_common.jl"))
QUERY_FNS[:energy] = (sql, args=Any[]) -> Euphemia.sql2df_with_retry(sql, args)
QUERY_FNS[:weather] = weather_query

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
const ZONES = String[strip(z) for z in split(get(ENV, "ZONES", "GR,BG,RO,RS,HU"), ",") if !isempty(strip(z))]
const START_DATE = Date(get(ENV, "START_DATE", "2026-01-01"))
const END_DATE = Date(get(ENV, "END_DATE", "2026-06-30"))
const OUT = get(ENV, "OUT", "data/extracts/euphemia_2026_see.duckdb")

# Canonical parquet dir. Empty string disables parquet emission (runtime .duckdb
# only). Default: publish next to OUT under a versioned dir.
const ARTIFACT_VERSION = get(ENV, "ARTIFACT_VERSION", "v1")
const PARQUET_DIR = get(ENV, "PARQUET_DIR", "")

const AUX_BACK_DAYS = parse(Int, get(ENV, "AUX_BACK_DAYS", "31"))

# Per-UNIT actual-generation output window. :merit_order never runs UC; its only
# use of the huge per-unit table is get_generators' 60-day recent-generation
# filter and get_day_outages' 7-day stale-override probe. AGEN_BACK_DAYS=90 keeps
# a short-window merit extract small; the public artifact uses 400 for robustness
# (also supports UC-based experiments).
const AGEN_BACK_DAYS = parse(Int, get(ENV, "AGEN_BACK_DAYS", "400"))

# Weather schema (separate weather DB): pulled when WEATHER_CONN_STR is available
# unless INCLUDE_WEATHER=false. city_forecast is windowed to WEATHER_BACK_DAYS.
const INCLUDE_WEATHER = lowercase(get(ENV, "INCLUDE_WEATHER", "true")) == "true" &&
                        haskey(ENV, "WEATHER_CONN_STR")
const WEATHER_BACK_DAYS = parse(Int, get(ENV, "WEATHER_BACK_DAYS", "400"))

# ERA5 cell-feature seed CSV (header zone,lat,lon,h,v100,ghi). Empty = skip.
const CELL_HOURLY_CSV = get(ENV, "CELL_HOURLY_CSV", "")

# Size guard. The dominant per-unit table compresses to ~15-20 bytes/row on disk
# (repeated codes, monotone timestamps), so the uncompressed 250 bytes/row of the
# original SEE guard massively over-projects a 3.5-year build. Defaults tuned for
# the compressed reality; both env-overridable.
const MAX_SIZE_GB = parse(Float64, get(ENV, "MAX_SIZE_GB", "12.0"))
const EST_BYTES_PER_ROW = parse(Int, get(ENV, "EST_BYTES_PER_ROW", "40"))

# Tables above this row count are built in monthly chunks to bound Julia memory
# (the 39-zone 3.5-year per-unit table is ~125M rows).
const CHUNK_THRESHOLD = parse(Int, get(ENV, "CHUNK_THRESHOLD", "8000000"))

# Abort the build (removing partial output) if free space on the OUTPUT
# filesystem would drop below this floor. Everything is written under the repo's
# data/ dirs (on /home) — never /tmp or /.
const MIN_FREE_GB = parse(Float64, get(ENV, "MIN_FREE_GB", "60.0"))

# Free gigabytes on the filesystem holding `path` (its nearest existing dir).
function free_gb(path::AbstractString)
    dir = isdir(path) ? path : dirname(path)
    isempty(dir) && (dir = ".")
    while !isdir(dir) && dir != "/" && !isempty(dir)
        dir = dirname(dir)
    end
    out = readchomp(`df -Pk $dir`)
    avail_kb = parse(Int, split(split(out, '\n')[end])[4])
    return avail_kb / 1e6
end

function table_specs()
    specs = entsoe_table_specs(ZONES; start_date=START_DATE, end_date=END_DATE,
                               aux_back_days=AUX_BACK_DAYS,
                               agen_back_days=AGEN_BACK_DAYS)
    append!(specs, yfinance_table_specs())
    append!(specs, simulations_table_specs(ZONES))
    INCLUDE_WEATHER && append!(specs, weather_table_specs(back_days=WEATHER_BACK_DAYS))
    return specs
end

# --------------------------------------------------------------------------
# Manifest / checksum helpers (hand-rolled JSON — controlled structure)
# --------------------------------------------------------------------------
json_str(s) = '"' * replace(String(s), "\\" => "\\\\", "\"" => "\\\"") * '"'

function write_manifest(path::String, tables::Vector{<:NamedTuple}, total_rows::Int)
    io = IOBuffer()
    println(io, "{")
    println(io, "  \"artifact_version\": ", json_str(ARTIFACT_VERSION), ",")
    println(io, "  \"build_timestamp_utc\": ", json_str(string(now(UTC))), ",")
    println(io, "  \"clearing_window\": {\"start\": ", json_str(string(START_DATE)),
            ", \"end\": ", json_str(string(END_DATE)), "},")
    println(io, "  \"per_unit_output_lookback_start\": ", json_str(string(START_DATE - Day(AGEN_BACK_DAYS))), ",")
    println(io, "  \"source_data_cutoff\": ", json_str(string(END_DATE)), ",")
    println(io, "  \"zones\": [", join(json_str.(ZONES), ", "), "],")
    println(io, "  \"total_rows\": ", total_rows, ",")
    println(io, "  \"tables\": [")
    for (i, t) in enumerate(tables)
        comma = i == length(tables) ? "" : ","
        parquet = t.parquet === nothing ? "null" : json_str(t.parquet)
        sha = t.sha === nothing ? "null" : json_str(t.sha)
        println(io, "    {\"name\": ", json_str(t.name),
                ", \"rows\": ", t.rows,
                ", \"parquet\": ", parquet,
                ", \"parquet_bytes\": ", t.parquet_bytes,
                ", \"sha256\": ", sha, "}", comma)
    end
    println(io, "  ]")
    println(io, "}")
    write(path, take!(io))
end

# Emit one extract table to the canonical parquet dir; returns the manifest
# fields (parquet path relative to PARQUET_DIR, bytes, sha256).
function emit_parquet(con, schema::String, table::String)
    isempty(PARQUET_DIR) && return (nothing, 0, nothing)
    parquet_rel = "$schema.$table.parquet"
    pq = joinpath(PARQUET_DIR, parquet_rel)
    DBInterface.execute(con,
        "COPY \"$schema\".\"$table\" TO '$pq' (FORMAT PARQUET, COMPRESSION 'zstd')")
    return (parquet_rel, filesize(pq), open(f -> bytes2hex(sha256(f)), pq))
end

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
function main()
    t0 = time()
    println("Building DuckDB extract + parquet artifact")
    println("  artifact : ", ARTIFACT_VERSION)
    println("  zones    : ", length(ZONES), "  (", join(ZONES, ","), ")")
    println("  window   : ", START_DATE, " .. ", END_DATE,
            "  (aux back to ", START_DATE - Day(AUX_BACK_DAYS),
            "; per-type back to ", START_DATE - Day(400),
            "; per-unit output back to ", START_DATE - Day(AGEN_BACK_DAYS), ")")
    println("  duckdb   : ", OUT)
    println("  parquet  : ", isempty(PARQUET_DIR) ? "(disabled)" : PARQUET_DIR)
    println("  weather  : ", INCLUDE_WEATHER ?
            "yes (city_forecast back $(WEATHER_BACK_DAYS) days)" :
            "no (WEATHER_CONN_STR unset or INCLUDE_WEATHER=false)")
    println("  cell CSV : ", isempty(CELL_HOURLY_CSV) ? "(none)" : CELL_HOURLY_CSV)
    println()

    specs = table_specs()

    # --- Pre-flight: COUNT(*) per table, abort if projected size too big ---
    println("Pre-flight row counts:")
    total_rows = 0
    counts = Dict{String,Int}()
    for spec in specs
        (where, args) = build_where_args(spec)
        c = query_fn(spec.source)(count_sql(spec, where), args).c[1]
        c = c === missing ? 0 : Int(c)
        counts["$(spec.schema).$(spec.table)"] = c
        total_rows += c
        @printf("  %-55s %14d\n", "$(spec.schema).$(spec.table)", c)
    end
    proj_gb = total_rows * EST_BYTES_PER_ROW / 1e9
    @printf("  %-55s %14d\n", "TOTAL", total_rows)
    @printf("Projected size ~%.2f GB (@ %d bytes/row); cap %.1f GB\n\n",
            proj_gb, EST_BYTES_PER_ROW, MAX_SIZE_GB)
    if proj_gb > MAX_SIZE_GB
        println("ABORT: projected size ~$(round(proj_gb, digits=2)) GB exceeds cap of $MAX_SIZE_GB GB.")
        println("Narrow ZONES / the date window, or raise MAX_SIZE_GB.")
        return 1
    end

    # --- Build DuckDB ---
    mkpath(dirname(OUT))
    isfile(OUT) && (println("Removing existing $OUT"); rm(OUT))
    !isempty(PARQUET_DIR) && mkpath(PARQUET_DIR)

    db = DuckDB.DB(OUT)
    con = DBInterface.connect(db)
    # Keep DuckDB's spill workspace on /home (next to OUT), never /tmp or /.
    let tmp = joinpath(dirname(OUT) == "" ? "." : dirname(OUT), ".duckdb_tmp")
        mkpath(tmp)
        DBInterface.execute(con, "SET temp_directory = '$tmp'")
    end
    for sch in unique(s.schema for s in specs)
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS $sch")
    end

    # Graceful abort: close, remove partial artifacts, return 1.
    function abort_build(reason)
        println("\nABORT: ", reason)
        try; DBInterface.close!(con); catch; end
        try; close(db); catch; end
        try; isfile(OUT) && rm(OUT); catch; end
        try; rm(OUT * ".wal", force=true); catch; end
        try; !isempty(PARQUET_DIR) && isdir(PARQUET_DIR) && rm(PARQUET_DIR, recursive=true); catch; end
        return 1
    end

    @printf("Disk free on target before build: %.1f GB (floor %.0f GB)\n", free_gb(OUT), MIN_FREE_GB)

    manifest_tables = NamedTuple[]
    for spec in specs
        fqtn = "$(spec.schema).$(spec.table)"
        expected = counts[fqtn]
        chunked = expected > CHUNK_THRESHOLD && spec.window !== nothing
        fg = free_gb(OUT)
        if fg < MIN_FREE_GB
            return abort_build("free space $(round(fg, digits=1)) GB < floor $(MIN_FREE_GB) GB before $fqtn")
        end
        @printf("  loading %-55s %s  [free %.1f GB]\n", fqtn, chunked ? "(monthly chunks)" : "", fg)
        flush(stdout)
        n = build_table!(con, spec; chunk_threshold=CHUNK_THRESHOLD, expected=expected)

        (parquet_rel, parquet_bytes, sha) = emit_parquet(con, spec.schema, spec.table)
        push!(manifest_tables, (name=fqtn, rows=n, parquet=parquet_rel,
                                parquet_bytes=parquet_bytes, sha=sha))
        fg2 = free_gb(OUT)
        @printf("      %10d rows%s  [free %.1f GB]\n", n,
                parquet_bytes > 0 ? @sprintf("  parquet %.1f MB", parquet_bytes/1e6) : "", fg2)
        flush(stdout)
        if fg2 < MIN_FREE_GB
            return abort_build("free space $(round(fg2, digits=1)) GB < floor $(MIN_FREE_GB) GB after $fqtn")
        end
    end

    # --- weather.cell_hourly seed (ERA5 feature history, filtered to ZONES) ---
    if !isempty(CELL_HOURLY_CSV)
        println("  seeding weather.cell_hourly from ", CELL_HOURLY_CSV)
        flush(stdout)
        n = seed_cell_hourly!(con, CELL_HOURLY_CSV; zones=ZONES)
        (parquet_rel, parquet_bytes, sha) = emit_parquet(con, "weather", "cell_hourly")
        push!(manifest_tables, (name="weather.cell_hourly", rows=n, parquet=parquet_rel,
                                parquet_bytes=parquet_bytes, sha=sha))
        total_rows += n
        @printf("      %10d rows (source='era5')\n", n)
    end

    DBInterface.close!(con)
    close(db)
    close_weather_connection!()

    duckdb_bytes = filesize(OUT)

    # --- Manifest + checksums for published files ---
    if !isempty(PARQUET_DIR)
        manifest_path = joinpath(PARQUET_DIR, "MANIFEST.json")
        write_manifest(manifest_path, manifest_tables, total_rows)

        # Bundle the column-level data dictionary (per-table provenance and
        # gotchas) so the artifact is self-documenting.
        dict_src = joinpath(@__DIR__, "..", "docs", "data-dictionary.md")
        isfile(dict_src) && cp(dict_src, joinpath(PARQUET_DIR, "DATA-DICTIONARY.md");
                               force=true)

        # SHA256SUMS: one line per published file (parquet + manifest +
        # dictionary), sha256sum format ("<hex>  <relative path>"), relative
        # to PARQUET_DIR.
        sums = IOBuffer()
        for t in manifest_tables
            t.parquet === nothing && continue
            println(sums, t.sha, "  ", t.parquet)
        end
        mdigest = open(f -> bytes2hex(sha256(f)), manifest_path)
        println(sums, mdigest, "  MANIFEST.json")
        dict_dst = joinpath(PARQUET_DIR, "DATA-DICTIONARY.md")
        if isfile(dict_dst)
            ddigest = open(f -> bytes2hex(sha256(f)), dict_dst)
            println(sums, ddigest, "  DATA-DICTIONARY.md")
        end
        write(joinpath(PARQUET_DIR, "SHA256SUMS"), take!(sums))
        println("\nWrote MANIFEST.json + SHA256SUMS to ", PARQUET_DIR)
    end

    println()
    @printf("Done in %.0f s.\n", time() - t0)
    @printf("  duckdb : %s  (%.1f MB)\n", OUT, duckdb_bytes / 1e6)
    if !isempty(PARQUET_DIR)
        pqtotal = sum(t.parquet_bytes for t in manifest_tables)
        @printf("  parquet: %s  (%.1f MB across %d files)\n",
                PARQUET_DIR, pqtotal / 1e6, count(t -> t.parquet !== nothing, manifest_tables))
    end
    @printf("  rows   : %d\n", total_rows)
    return 0
end

exit(main())
