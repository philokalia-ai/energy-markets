# Build a self-contained DuckDB extract of the SEE market data the Euphemia
# library reads, so single-zone merit-order pricing and scenario analysis can
# run fully offline (no Postgres). The extract mirrors the same `schema.table`
# names, with every `timestamp with time zone` column converted to naive UTC
# (`... AT TIME ZONE 'UTC'`) — which is exactly what the DuckDB dialect
# rewrite in src/dbutils.jl assumes (it strips ` AT TIME ZONE 'UTC'`).
#
# Usage (all via env vars):
#   ZONES="GR,BG,RO,RS,HU" START_DATE=2026-01-01 END_DATE=2026-06-30 \
#     OUT=data/extracts/euphemia_2026_see.duckdb \
#     julia --project=. bin/build_duckdb_extract.jl
#
# Reads from Postgres (normal .env / ENERGY_CONN_STR); writes a .duckdb file.
# The DuckDB backend the extract feeds is READ-ONLY in the library (v1).

using Euphemia
using DataFrames
using Dates
using DuckDB
using Printf

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
const ZONES = String[strip(z) for z in split(get(ENV, "ZONES", "GR,BG,RO,RS,HU"), ",") if !isempty(strip(z))]
const START_DATE = Date(get(ENV, "START_DATE", "2026-01-01"))
const END_DATE = Date(get(ENV, "END_DATE", "2026-06-30"))
const OUT = get(ENV, "OUT", "data/extracts/euphemia_2026_see.duckdb")

# Lookbacks: 400 days back covers the 365-day ramp/output inference window,
# the 60-day recent-generation filter, and the 30-day p95 hydro/type window.
const BACK400 = START_DATE - Day(400)
# Window end is exclusive at END_DATE + 1 day (whole END_DATE included).
const END_EXCL = END_DATE + Day(1)

const MAX_SIZE_GB = 8.0
# Conservative bytes/row for the pre-flight projection (DuckDB compresses, so
# the real file is smaller). The big unit-level table dominates the total.
const EST_BYTES_PER_ROW = 250

# --------------------------------------------------------------------------
# Postgres → naive-UTC projection helper
# --------------------------------------------------------------------------
# Build `SELECT <cols> FROM schema.table` where every timestamptz column is
# emitted as `col AT TIME ZONE 'UTC' AS col` (naive UTC) and everything else
# is passed through unchanged. Keeps the extract's column names identical to
# the source so library queries work verbatim (after the dialect rewrite).
function projection(schema::String, table::String)
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
        if String(r.data_type) == "timestamp with time zone"
            push!(parts, "\"$col\" AT TIME ZONE 'UTC' AS \"$col\"")
        else
            push!(parts, "\"$col\"")
        end
    end
    return join(parts, ", ")
end

# --------------------------------------------------------------------------
# Table specifications: (schema, table, where_clause, args)
# The projection is prepended automatically. `where` may be "" for full table.
# --------------------------------------------------------------------------
function table_specs()
    specs = Vector{NamedTuple}()

    # Zone-code subqueries reused by the unit-level tables
    gen_codes = "SELECT generation_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$1)"
    unit_codes = "$gen_codes UNION SELECT production_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$1)"

    push!(specs, (schema="entsoe", table="day_ahead_total_load_forecast",
        where="area_map_code = ANY(\$1) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, START_DATE, END_EXCL]))

    push!(specs, (schema="entsoe", table="generation_forecasts_for_wind_and_solar",
        where="area_map_code = ANY(\$1) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, START_DATE, END_EXCL]))

    push!(specs, (schema="entsoe", table="energy_prices",
        where="map_code = ANY(\$1) AND contract_type = 'Day-ahead' AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, START_DATE, END_EXCL]))

    push!(specs, (schema="entsoe", table="offered_transfer_capacities_implicit",
        where="(out_map_code = ANY(\$1) OR in_map_code = ANY(\$1)) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, START_DATE, END_EXCL]))

    # physical_flows: match on either side, including _IPS-suffixed aliases
    push!(specs, (schema="entsoe", table="physical_flows",
        where="(regexp_replace(in_area_map_code, '_IPS\$', '') = ANY(\$1) OR regexp_replace(out_area_map_code, '_IPS\$', '') = ANY(\$1)) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, START_DATE, END_EXCL]))

    # aggregated_generation_per_type: 400-day-back window (30d p95 + 365d output)
    push!(specs, (schema="entsoe", table="aggregated_generation_per_type",
        where="area_map_code = ANY(\$1) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, BACK400, END_EXCL]))

    # aggregated_hydro_storage_filling_rate: FULL history for the zones. The
    # reservoir-dryness comparison medians over ALL prior years' same weeks, so
    # a 400-day window would truncate the norm and change dryness (and thus
    # water-value prices). The table is weekly and tiny, so full history is
    # free and keeps DuckDB prices bit-identical to Postgres. (Deviation from
    # the 400-day spec, for correctness.)
    push!(specs, (schema="entsoe", table="aggregated_hydro_storage_filling_rate",
        where="area_map_code = ANY(\$1)",
        args=Any[ZONES]))

    # production_and_generation_units: all history for the zones
    push!(specs, (schema="entsoe", table="production_and_generation_units",
        where="area_map_code = ANY(\$1)",
        args=Any[ZONES]))

    # unavailability: asset_code in zones' unit/production codes, outage window
    # overlapping [BACK400, END]. start/end_outage_utc are text timestamps.
    push!(specs, (schema="entsoe", table="unavailability_of_production_and_generation_units",
        where="asset_code IN ($unit_codes) AND start_outage_utc IS NOT NULL AND end_outage_utc IS NOT NULL AND start_outage_utc::timestamp <= \$2::date::timestamp AND end_outage_utc::timestamp >= \$3::date::timestamp",
        args=Any[ZONES, END_DATE, BACK400]))

    # actual_generation_output_per_generation_unit: the big one — zones' unit
    # codes, 400-day-back window
    push!(specs, (schema="entsoe", table="actual_generation_output_per_generation_unit",
        where="generation_unit_code IN ($gen_codes) AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')",
        args=Any[ZONES, BACK400, END_EXCL]))

    # yfinance: full history (no zone/date filter)
    push!(specs, (schema="yfinance", table="ttf_f", where="", args=Any[]))
    push!(specs, (schema="yfinance", table="eua_co2", where="", args=Any[]))

    # simulations reference caches used by the library / strategist context
    push!(specs, (schema="simulations", table="generator_inferred_parameters",
        where="bidding_zone = ANY(\$1)", args=Any[ZONES]))
    push!(specs, (schema="simulations", table="unit_firms",
        where="zone = ANY(\$1)", args=Any[ZONES]))

    return specs
end

count_sql(spec) = "SELECT count(*) AS c FROM $(spec.schema).$(spec.table)" *
                  (isempty(spec.where) ? "" : " WHERE $(spec.where)")

select_sql(spec) = "SELECT $(projection(spec.schema, spec.table)) FROM $(spec.schema).$(spec.table)" *
                   (isempty(spec.where) ? "" : " WHERE $(spec.where)")

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
function main()
    println("Building DuckDB extract")
    println("  zones : ", join(ZONES, ", "))
    println("  window: ", START_DATE, " .. ", END_DATE, "  (unit/output tables back to ", BACK400, ")")
    println("  out   : ", OUT)
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
        @printf("  %-55s %12d\n", "$(spec.schema).$(spec.table)", c)
    end
    proj_gb = total_rows * EST_BYTES_PER_ROW / 1e9
    @printf("  %-55s %12d\n", "TOTAL", total_rows)
    @printf("Projected uncompressed size ~%.2f GB (@ %d bytes/row)\n\n", proj_gb, EST_BYTES_PER_ROW)
    if proj_gb > MAX_SIZE_GB
        println("ABORT: projected size ~$(round(proj_gb, digits=2)) GB exceeds cap of $MAX_SIZE_GB GB.")
        println("Narrow ZONES or the date window and retry.")
        return 1
    end

    # --- Build ---
    mkpath(dirname(OUT))
    isfile(OUT) && (println("Removing existing $OUT"); rm(OUT))

    db = DuckDB.DB(OUT)
    con = DBInterface.connect(db)
    for sch in unique(s.schema for s in specs)
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS $sch")
    end

    for spec in specs
        fqtn = "$(spec.schema).$(spec.table)"
        print("  loading $fqtn ... "); flush(stdout)
        df = Euphemia.sql2df_with_retry(select_sql(spec), spec.args)
        viewname = "_stage_" * replace(fqtn, "." => "_")
        DuckDB.register_data_frame(con, df, viewname)
        DBInterface.execute(con, "CREATE TABLE \"$(spec.schema)\".\"$(spec.table)\" AS SELECT * FROM $viewname")
        DuckDB.unregister_data_frame(con, viewname)
        println(nrow(df), " rows")
    end

    DBInterface.close!(con)
    close(db)

    sz = filesize(OUT)
    @printf("\nDone. %s  (%.1f MB)\n", OUT, sz / 1e6)
    return 0
end

exit(main())
