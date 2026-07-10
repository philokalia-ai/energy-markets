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
# Reads from Postgres (normal .env / ENERGY_CONN_STR). The DuckDB backend the
# extract feeds is READ-ONLY in the library (writes route to a separate
# data/results.duckdb; see src/dbutils.jl).

using Euphemia
using DataFrames
using Dates
using DuckDB
using Printf
using SHA

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

# Deep-lookback tables (per-type aggregate + hydro availability) need 400 days
# back: the 365-day hydro-availability window, 60-day recent-generation filter,
# and 30-day p95. Shallow aux tables (day-ahead load/RES forecast, ATC, flows,
# actuals) are same-delivery-day and get a modest pre-roll for month-boundary
# lookbacks.
const BACK400 = START_DATE - Day(400)
const AUX_BACK = START_DATE - Day(parse(Int, get(ENV, "AUX_BACK_DAYS", "31")))

# Per-UNIT actual-generation output window. :merit_order never runs UC; its only
# use of the huge per-unit table is get_generators' 60-day recent-generation
# filter and get_day_outages' 7-day stale-override probe. AGEN_BACK_DAYS=90 keeps
# a short-window merit extract small; the public artifact uses 400 for robustness
# (also supports UC-based experiments).
const AGEN_BACK = START_DATE - Day(parse(Int, get(ENV, "AGEN_BACK_DAYS", "400")))
# Window end is exclusive at END_DATE + 1 day (whole END_DATE included).
const END_EXCL = END_DATE + Day(1)

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

# --------------------------------------------------------------------------
# Postgres → naive-UTC projection helper
# --------------------------------------------------------------------------
# Build the column list where every timestamptz column is emitted as
# `col AT TIME ZONE 'UTC' AS col` (naive UTC) and everything else is passed
# through unchanged. Keeps the extract's column names identical to the source.
function projection(schema::String, table::String,
                    casts::AbstractDict=Dict{String,String}())
    df = Euphemia.sql2df_with_retry(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = \$1 AND table_name = \$2
        ORDER BY ordinal_position
        """,
        [schema, table])
    isempty(df) && error("Table $schema.$table not found in Postgres")
    parts = String[]
    for r in eachrow(df)
        col = String(r.column_name)
        if haskey(casts, col)
            # Explicit type conversion at build time (e.g. the unavailability
            # table's text start/end_outage_utc → TIMESTAMP, so the daily outage
            # probe compares pruned timestamps instead of casting every row).
            push!(parts, "\"$col\"::$(casts[col]) AS \"$col\"")
        elseif String(r.data_type) == "timestamp with time zone"
            push!(parts, "\"$col\" AT TIME ZONE 'UTC' AS \"$col\"")
        else
            push!(parts, "\"$col\"")
        end
    end
    return join(parts, ", ")
end

# --------------------------------------------------------------------------
# Table specifications: (schema, table, where, args, chunk_col)
# `where` may be "" for a full table. `chunk_col` names the timestamptz column to
# window on when the table is large enough to require monthly chunking (or "").
# --------------------------------------------------------------------------
# Empty cast map reused by every spec that needs no explicit type conversion.
const NOCAST = Dict{String,String}()

function table_specs()
    specs = Vector{NamedTuple}()

    gen_codes = "SELECT generation_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$1)"
    unit_codes = "$gen_codes UNION SELECT production_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$1)"

    # `sort_by` is the ORDER BY the table is MATERIALIZED with, so DuckDB row-group
    # zonemaps on (zone, date) actually prune per-zone/per-day scans (unsorted
    # heap order pruned nothing). Chunked tables are sorted WITHIN each monthly
    # chunk (giving month-level date locality plus in-chunk zone/unit locality).
    push!(specs, (schema="entsoe", table="day_ahead_total_load_forecast",
        where="area_map_code = ANY(\$1) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AUX_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="area_map_code, date_time_utc", casts=NOCAST))

    push!(specs, (schema="entsoe", table="generation_forecasts_for_wind_and_solar",
        where="area_map_code = ANY(\$1) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AUX_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="area_map_code, date_time_utc", casts=NOCAST))

    push!(specs, (schema="entsoe", table="energy_prices",
        where="map_code = ANY(\$1) AND contract_type = 'Day-ahead' AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AUX_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="map_code, date_time_utc", casts=NOCAST))

    push!(specs, (schema="entsoe", table="offered_transfer_capacities_implicit",
        where="(out_map_code = ANY(\$1) OR in_map_code = ANY(\$1)) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AUX_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="out_map_code, in_map_code, date_time_utc", casts=NOCAST))

    # Explicit (LT + DA-auction) ATC — required by the enriched multi-zone network
    # build (CH is outside SDAC implicit coupling; Serbia's borders are auctioned).
    push!(specs, (schema="entsoe", table="offered_transfer_capacities_explicit",
        where="(out_map_code = ANY(\$1) OR in_map_code = ANY(\$1)) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AUX_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="out_map_code, in_map_code, date_time_utc", casts=NOCAST))

    # physical_flows: match on either side, including _IPS-suffixed aliases
    push!(specs, (schema="entsoe", table="physical_flows",
        where="(regexp_replace(in_area_map_code, '_IPS\$', '') = ANY(\$1) OR regexp_replace(out_area_map_code, '_IPS\$', '') = ANY(\$1)) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AUX_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="in_area_map_code, out_area_map_code, date_time_utc", casts=NOCAST))

    # aggregated_generation_per_type: 400-day-back window (30d p95 + 365d hydro avail)
    push!(specs, (schema="entsoe", table="aggregated_generation_per_type",
        where="area_map_code = ANY(\$1) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, BACK400, END_EXCL], chunk_col="date_time_utc",
        sort_by="area_map_code, production_type, date_time_utc", casts=NOCAST))

    # aggregated_hydro_storage_filling_rate: FULL history for the zones. The
    # reservoir-dryness comparison medians over ALL prior years' same weeks, so a
    # windowed table would truncate the norm and change water-value prices. Weekly
    # and tiny, so full history is free and keeps prices bit-identical.
    push!(specs, (schema="entsoe", table="aggregated_hydro_storage_filling_rate",
        where="area_map_code = ANY(\$1)",
        args=Any[ZONES], chunk_col="",
        sort_by="area_map_code, year, week", casts=NOCAST))

    # production_and_generation_units: all history for the zones
    push!(specs, (schema="entsoe", table="production_and_generation_units",
        where="area_map_code = ANY(\$1)",
        args=Any[ZONES], chunk_col="",
        sort_by="area_map_code, generation_unit_code", casts=NOCAST))

    # unavailability: asset_code in zones' unit/production codes, outage window
    # overlapping [BACK400, END]. start/end_outage_utc are TEXT timestamps in the
    # source — cast to TIMESTAMP at build time so the daily outage-overlap probe
    # is a pruned comparison, not a per-row string cast.
    push!(specs, (schema="entsoe", table="unavailability_of_production_and_generation_units",
        where="asset_code IN ($unit_codes) AND start_outage_utc IS NOT NULL AND end_outage_utc IS NOT NULL AND start_outage_utc::timestamp <= \$2::date::timestamp AND end_outage_utc::timestamp >= \$3::date::timestamp",
        args=Any[ZONES, END_DATE, BACK400], chunk_col="",
        sort_by="asset_code, start_outage_utc",
        casts=Dict("start_outage_utc" => "TIMESTAMP", "end_outage_utc" => "TIMESTAMP")))

    # actual_generation_output_per_generation_unit: the big one (~125M rows for a
    # 39-zone 3.5-year build). Built in monthly chunks via chunk_col; each chunk
    # sorted by (unit, date) so the 60-day recent-generation probe and unit-level
    # point probes prune to a unit's row groups within the date-pruned months.
    push!(specs, (schema="entsoe", table="actual_generation_output_per_generation_unit",
        where="generation_unit_code IN ($gen_codes) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, AGEN_BACK, END_EXCL], chunk_col="date_time_utc",
        sort_by="generation_unit_code, date_time_utc", casts=NOCAST))

    # yfinance: full history (no zone/date filter) — ~1k rows each
    push!(specs, (schema="yfinance", table="ttf_f", where="", args=Any[], chunk_col="",
        sort_by="", casts=NOCAST))
    push!(specs, (schema="yfinance", table="eua_co2", where="", args=Any[], chunk_col="",
        sort_by="", casts=NOCAST))

    # simulations reference caches used by the library / strategist context
    push!(specs, (schema="simulations", table="generator_inferred_parameters",
        where="bidding_zone = ANY(\$1)", args=Any[ZONES], chunk_col="",
        sort_by="", casts=NOCAST))
    push!(specs, (schema="simulations", table="unit_firms",
        where="zone = ANY(\$1)", args=Any[ZONES], chunk_col="",
        sort_by="", casts=NOCAST))

    return specs
end

count_sql(spec) = "SELECT count(*) AS c FROM $(spec.schema).$(spec.table)" *
                  (isempty(spec.where) ? "" : " WHERE $(spec.where)")

select_sql(spec) = "SELECT $(projection(spec.schema, spec.table, spec.casts)) FROM $(spec.schema).$(spec.table)" *
                   (isempty(spec.where) ? "" : " WHERE $(spec.where)")

# Month boundaries [lo, hi) covering [from, until).
function month_ranges(from::Date, until::Date)
    ranges = Tuple{Date,Date}[]
    lo = firstdayofmonth(from)
    while lo < until
        hi = lo + Month(1)
        push!(ranges, (max(lo, from), min(hi, until)))
        lo = hi
    end
    return ranges
end

# --------------------------------------------------------------------------
# Build one DuckDB table from a spec (whole or monthly-chunked), returning rows.
# --------------------------------------------------------------------------
function build_table!(con, spec, cols::String, rowcount::Int)
    fqtn = "$(spec.schema).$(spec.table)"
    tgt = "\"$(spec.schema)\".\"$(spec.table)\""
    order = isempty(spec.sort_by) ? "" : " ORDER BY $(spec.sort_by)"

    if rowcount > CHUNK_THRESHOLD && !isempty(spec.chunk_col)
        # Monthly-chunked build: the window is (args[2], args[3]) as Dates.
        from = Date(spec.args[2]); until = Date(spec.args[3])
        ranges = month_ranges(from, until)
        base_where = spec.where
        created = false
        total = 0
        for (i, (lo, hi)) in enumerate(ranges)
            # Append month bounds using two fresh positional params after the
            # spec's own args (postgres binds by position).
            n = length(spec.args)
            mwhere = base_where *
                " AND $(spec.chunk_col) >= (\$$(n+1)::date::timestamp AT TIME ZONE 'UTC')" *
                " AND $(spec.chunk_col) <  (\$$(n+2)::date::timestamp AT TIME ZONE 'UTC')"
            sql = "SELECT $cols FROM $(spec.schema).$(spec.table) WHERE $mwhere"
            df = Euphemia.sql2df_with_retry(sql, Any[spec.args..., lo, hi])
            view = "_stage_chunk"
            DuckDB.register_data_frame(con, df, view)
            if !created
                DBInterface.execute(con, "CREATE TABLE $tgt AS SELECT * FROM $view$order")
                created = true
            else
                DBInterface.execute(con, "INSERT INTO $tgt SELECT * FROM $view$order")
            end
            DuckDB.unregister_data_frame(con, view)
            total += nrow(df)
            @printf("      chunk %2d/%2d  %s..%s  %10d rows  (cum %d)\n",
                    i, length(ranges), lo, hi, nrow(df), total)
            flush(stdout)
        end
        return total
    else
        df = Euphemia.sql2df_with_retry(select_sql(spec), spec.args)
        view = "_stage_" * replace(fqtn, "." => "_")
        DuckDB.register_data_frame(con, df, view)
        DBInterface.execute(con, "CREATE TABLE $tgt AS SELECT * FROM $view$order")
        DuckDB.unregister_data_frame(con, view)
        return nrow(df)
    end
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
    println(io, "  \"per_unit_output_lookback_start\": ", json_str(string(AGEN_BACK)), ",")
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

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
function main()
    t0 = time()
    println("Building DuckDB extract + parquet artifact")
    println("  artifact : ", ARTIFACT_VERSION)
    println("  zones    : ", length(ZONES), "  (", join(ZONES, ","), ")")
    println("  window   : ", START_DATE, " .. ", END_DATE,
            "  (aux back to ", AUX_BACK, "; per-type back to ", BACK400,
            "; per-unit output back to ", AGEN_BACK, ")")
    println("  duckdb   : ", OUT)
    println("  parquet  : ", isempty(PARQUET_DIR) ? "(disabled)" : PARQUET_DIR)
    println()

    specs = table_specs()

    # --- Pre-flight: COUNT(*) per table, abort if projected size too big ---
    println("Pre-flight row counts:")
    total_rows = 0
    counts = Dict{String,Int}()
    for spec in specs
        c = Euphemia.sql2df_with_retry(count_sql(spec), spec.args).c[1]
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
        chunked = expected > CHUNK_THRESHOLD && !isempty(spec.chunk_col)
        fg = free_gb(OUT)
        if fg < MIN_FREE_GB
            return abort_build("free space $(round(fg, digits=1)) GB < floor $(MIN_FREE_GB) GB before $fqtn")
        end
        @printf("  loading %-55s %s  [free %.1f GB]\n", fqtn, chunked ? "(monthly chunks)" : "", fg)
        flush(stdout)
        cols = projection(spec.schema, spec.table, spec.casts)
        n = build_table!(con, spec, cols, expected)

        # Emit parquet (zstd) for this table.
        parquet_rel = nothing; parquet_bytes = 0; sha = nothing
        if !isempty(PARQUET_DIR)
            parquet_rel = "$(spec.schema).$(spec.table).parquet"
            pq = joinpath(PARQUET_DIR, parquet_rel)
            DBInterface.execute(con,
                "COPY \"$(spec.schema)\".\"$(spec.table)\" TO '$pq' (FORMAT PARQUET, COMPRESSION 'zstd')")
            parquet_bytes = filesize(pq)
            sha = open(f -> bytes2hex(sha256(f)), pq)
        end
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

    DBInterface.close!(con)
    close(db)

    duckdb_bytes = filesize(OUT)

    # --- Manifest + checksums for published files ---
    if !isempty(PARQUET_DIR)
        manifest_path = joinpath(PARQUET_DIR, "MANIFEST.json")
        write_manifest(manifest_path, manifest_tables, total_rows)

        # SHA256SUMS: one line per published file (parquet + manifest), sha256sum
        # format ("<hex>  <relative path>"), relative to PARQUET_DIR.
        sums = IOBuffer()
        for t in manifest_tables
            t.parquet === nothing && continue
            println(sums, t.sha, "  ", t.parquet)
        end
        mdigest = open(f -> bytes2hex(sha256(f)), manifest_path)
        println(sums, mdigest, "  MANIFEST.json")
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
