# Build the euphemia-data-v1.1 artifact by RE-SORTING the existing v1 parquet
# directory — no Postgres re-export needed (the parquet already carries every
# column). v1.1 changes ONLY the physical layout of the published data:
#
#   * every table is materialized ORDER BY (zone, date) [chunked/unit tables get
#     the appropriate composite order], so DuckDB row-group zonemaps prune
#     per-zone / per-day scans; and
#   * the unavailability table's text start/end_outage_utc columns are cast to
#     TIMESTAMP, so the daily outage probe compares pruned timestamps instead of
#     casting every row.
#
# Same tables, same rows (row counts asserted equal to v1), same values — only
# order/dtype changed. Emits a canonical parquet dir + runtime .duckdb +
# MANIFEST.json (artifact_version=v1.1) + SHA256SUMS.
#
# Usage:
#   PARQUET_IN=data/public/euphemia-data-v1 \
#   PARQUET_OUT=data/public/euphemia-data-v1.1 \
#   OUT=data/public/euphemia-public-v1.1.duckdb \
#   ARTIFACT_VERSION=v1.1 \
#     julia --project=. bin/build_duckdb_v11.jl
#
# DuckDB + stdlib only — no Euphemia/Postgres load.

using DuckDB
using SHA
using Printf
import DuckDB.DBInterface as DBInterface
using DataFrames

const PARQUET_IN  = get(ENV, "PARQUET_IN",  "data/public/euphemia-data-v1")
const PARQUET_OUT = get(ENV, "PARQUET_OUT", "data/public/euphemia-data-v1.1")
const OUT         = get(ENV, "OUT",         "data/public/euphemia-public-v1.1.duckdb")
const ARTIFACT_VERSION = get(ENV, "ARTIFACT_VERSION", "v1.1")
# DuckDB engine settings for the (memory-heavy) global sorts.
const SORT_THREADS = get(ENV, "V11_THREADS", string(max(1, Sys.CPU_THREADS ÷ 2)))
const SORT_MEMORY  = get(ENV, "V11_MEMORY", "")  # e.g. "64GB"; default = DuckDB auto

# Per-table (ORDER BY, casts). The per-unit table uses month-primary order so the
# date-pruned 60-day probe still narrows to a unit's row groups within the month.
const SORT_BY = Dict(
    "entsoe.day_ahead_total_load_forecast"          => "area_map_code, date_time_utc",
    "entsoe.generation_forecasts_for_wind_and_solar"=> "area_map_code, date_time_utc",
    "entsoe.energy_prices"                          => "map_code, date_time_utc",
    "entsoe.offered_transfer_capacities_implicit"   => "out_map_code, in_map_code, date_time_utc",
    "entsoe.offered_transfer_capacities_explicit"   => "out_map_code, in_map_code, date_time_utc",
    "entsoe.physical_flows"                         => "in_area_map_code, out_area_map_code, date_time_utc",
    "entsoe.aggregated_generation_per_type"         => "area_map_code, production_type, date_time_utc",
    "entsoe.aggregated_hydro_storage_filling_rate"  => "area_map_code, year, week",
    "entsoe.production_and_generation_units"        => "area_map_code, generation_unit_code",
    "entsoe.unavailability_of_production_and_generation_units" => "asset_code, start_outage_utc",
    "entsoe.actual_generation_output_per_generation_unit" =>
        "date_trunc('month', date_time_utc), generation_unit_code, date_time_utc",
)
# Column -> target type casts applied at materialization (order preserved).
const CASTS = Dict(
    "entsoe.unavailability_of_production_and_generation_units" =>
        Dict("start_outage_utc" => "TIMESTAMP", "end_outage_utc" => "TIMESTAMP"),
)

parse_fqtn(fname) = (p = split(replace(fname, r"\.parquet$" => ""), ".");
                     (String(p[1]), String(p[2])))
json_str(s) = '"' * replace(String(s), "\\" => "\\\\", "\"" => "\\\"") * '"'

# Build a column projection preserving the parquet's column order, substituting
# any cast for the named columns.
function projection(con, in_pq::String, casts::Dict)
    isempty(casts) && return "*"
    df = DataFrame(DBInterface.execute(con, "DESCRIBE SELECT * FROM read_parquet('$in_pq')"))
    parts = String[]
    for r in eachrow(df)
        col = String(r.column_name)
        if haskey(casts, col)
            push!(parts, "\"$col\"::$(casts[col]) AS \"$col\"")
        else
            push!(parts, "\"$col\"")
        end
    end
    return join(parts, ", ")
end

function main()
    t0 = time()
    isdir(PARQUET_IN) || error("Input parquet dir not found: $PARQUET_IN")
    files = sort(filter(f -> endswith(f, ".parquet"), readdir(PARQUET_IN)))
    isempty(files) && error("No .parquet files in $PARQUET_IN")
    mkpath(PARQUET_OUT)
    mkpath(dirname(OUT))
    isfile(OUT) && (println("Removing existing $OUT"); rm(OUT))

    db = DuckDB.DB(OUT); con = DBInterface.connect(db)
    try; DBInterface.execute(con, "SET threads = $SORT_THREADS"); catch e; @warn "SET threads" e; end
    if !isempty(SORT_MEMORY)
        try; DBInterface.execute(con, "SET memory_limit = '$SORT_MEMORY'"); catch e; @warn "SET memory_limit" e; end
    end
    let tmp = joinpath(dirname(OUT) == "" ? "." : dirname(OUT), ".duckdb_v11_tmp")
        mkpath(tmp)
        DBInterface.execute(con, "SET temp_directory = '$tmp'")
    end

    schemas = unique(parse_fqtn(f)[1] for f in files)
    for s in schemas
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS \"$s\"")
    end

    println("Re-sorting v1 parquet → $ARTIFACT_VERSION")
    println("  in     : $PARQUET_IN")
    println("  parquet: $PARQUET_OUT")
    println("  duckdb : $OUT\n")

    manifest = NamedTuple[]
    total_rows = 0
    allok = true
    for f in files
        schema, table = parse_fqtn(f)
        fqtn = "$schema.$table"
        in_pq  = joinpath(PARQUET_IN, f)
        out_pq = joinpath(PARQUET_OUT, f)
        casts = get(CASTS, fqtn, Dict{String,String}())
        proj = projection(con, in_pq, casts)
        order = haskey(SORT_BY, fqtn) ? " ORDER BY $(SORT_BY[fqtn])" : ""
        sel = "SELECT $proj FROM read_parquet('$in_pq')$order"

        n_in = DataFrame(DBInterface.execute(con,
            "SELECT count(*) AS c FROM read_parquet('$in_pq')")).c[1]

        # Write the re-sorted parquet, then materialize the duckdb table from it
        # (so parquet and duckdb are guaranteed identical).
        DBInterface.execute(con,
            "COPY ($sel) TO '$out_pq' (FORMAT PARQUET, COMPRESSION 'zstd')")
        DBInterface.execute(con,
            "CREATE TABLE \"$schema\".\"$table\" AS SELECT * FROM read_parquet('$out_pq')")
        n_out = DataFrame(DBInterface.execute(con,
            "SELECT count(*) AS c FROM \"$schema\".\"$table\"")).c[1]

        rows_ok = n_in == n_out
        allok &= rows_ok
        pbytes = filesize(out_pq)
        sha = open(x -> bytes2hex(sha256(x)), out_pq)
        push!(manifest, (name=fqtn, rows=n_out, parquet=f, parquet_bytes=pbytes, sha=sha))
        total_rows += n_out
        @printf("  %-58s %12d rows  %s  parquet %.1f MB  %s\n",
                fqtn, n_out, order == "" ? "(unsorted)" : "(sorted)",
                pbytes / 1e6, rows_ok ? "OK" : "ROW MISMATCH v1=$n_in")
        flush(stdout)
    end
    DBInterface.close!(con); close(db)

    # MANIFEST.json (version field = v1.1) + SHA256SUMS
    mio = IOBuffer()
    println(mio, "{")
    println(mio, "  \"artifact_version\": ", json_str(ARTIFACT_VERSION), ",")
    println(mio, "  \"derived_from\": ", json_str("euphemia-data-v1"), ",")
    println(mio, "  \"physical_layout\": ", json_str("sorted by (zone,date); unavailability outage timestamps cast to TIMESTAMP"), ",")
    println(mio, "  \"total_rows\": ", total_rows, ",")
    println(mio, "  \"tables\": [")
    for (i, t) in enumerate(manifest)
        comma = i == length(manifest) ? "" : ","
        println(mio, "    {\"name\": ", json_str(t.name), ", \"rows\": ", t.rows,
                ", \"parquet\": ", json_str(t.parquet), ", \"parquet_bytes\": ", t.parquet_bytes,
                ", \"sha256\": ", json_str(t.sha), "}", comma)
    end
    println(mio, "  ]")
    println(mio, "}")
    manifest_path = joinpath(PARQUET_OUT, "MANIFEST.json")
    write(manifest_path, take!(mio))

    sio = IOBuffer()
    for t in manifest
        println(sio, t.sha, "  ", t.parquet)
    end
    println(sio, open(x -> bytes2hex(sha256(x)), manifest_path), "  MANIFEST.json")
    write(joinpath(PARQUET_OUT, "SHA256SUMS"), take!(sio))

    @printf("\n%s in %.0f s. total rows %d.  %s\n",
            allok ? "Done" : "DONE WITH ROW MISMATCHES", time() - t0, total_rows,
            allok ? "All row counts match v1." : "ROW COUNT MISMATCH — investigate.")
    @printf("  duckdb : %s (%.1f MB)\n", OUT, filesize(OUT) / 1e6)
    return allok ? 0 : 1
end

exit(main())
