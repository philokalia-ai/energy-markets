# Shared helpers for the DuckDB extract BUILDER (bin/build_duckdb_extract.jl)
# and the incremental REFRESHER (bin/refresh_duckdb_extract.jl).
#
# One spec model drives both scripts:
#   - the builder materializes each spec as `CREATE TABLE ... ORDER BY sort_by`
#     (windowed on `ts_col` when `window` is set, monthly-chunked when large);
#   - the refresher appends only rows with `ts_col` NEWER than the extract's
#     current max (`refresh = :append`), or re-pulls small registry-like tables
#     wholesale (`refresh = :replace`).
#
# Sources: `:energy` (Postgres `energy` DB via Euphemia's pool) and `:weather`
# (Postgres weather DB via WEATHER_CONN_STR — a SEPARATE database on the
# same server; see READING_WEATHER_DATA.md). Scripts register their query
# functions in `QUERY_FNS` — this file deliberately does NOT `using Euphemia`,
# so the pure helpers can be unit-tested (test/test_extract_refresh_logic.jl)
# with no database at all.
#
# NOTE on append-only refresh vs the sorted extract: the builder materializes
# every table `ORDER BY sort_by` so DuckDB row-group zonemaps prune per-zone /
# per-day scans. Appended slabs are sorted within themselves but land AFTER the
# original rows, so repeated daily appends slowly degrade zonemap pruning
# (queries stay correct, just gradually slower). A monthly FULL rebuild with
# bin/build_duckdb_extract.jl is recommended to restore the global sort.

using DataFrames
using Dates
using DuckDB   # brings DBInterface
using LibPQ
using Printf

const NOCAST = Dict{String,String}()

# Query functions per source, registered by the including script:
#   QUERY_FNS[:energy]  = (sql, args) -> Euphemia.sql2df_with_retry(sql, args)
#   QUERY_FNS[:weather] = weather_query
const QUERY_FNS = Dict{Symbol,Function}()

query_fn(source::Symbol) =
    haskey(QUERY_FNS, source) ? QUERY_FNS[source] :
    error("No query function registered for source :$source — " *
          "the including script must populate QUERY_FNS[:$source]")

# ---------------------------------------------------------------------------
# Weather DB access (separate weather database, WEATHER_CONN_STR, read-only role)
# ---------------------------------------------------------------------------
const _WEATHER_CNX = Ref{Any}(nothing)

function _weather_connect()
    haskey(ENV, "WEATHER_CONN_STR") ||
        error("WEATHER_CONN_STR not set — required to pull the weather schema " *
              "(the weather database). See READING_WEATHER_DATA.md.")
    # WEATHER_CONN_STR may be a postgres:// URI — pass the timeout as a kwarg
    # instead of appending conninfo keywords (mixing the two is invalid).
    return LibPQ.Connection(ENV["WEATHER_CONN_STR"]; connect_timeout=30)
end

"Run SQL against the weather database, returning a DataFrame.
Keeps one lazy connection; reconnects once on failure."
function weather_query(sql::AbstractString, args=Any[])
    _WEATHER_CNX[] === nothing && (_WEATHER_CNX[] = _weather_connect())
    try
        return DataFrame(LibPQ.execute(_WEATHER_CNX[], sql, args))
    catch
        try
            close(_WEATHER_CNX[])
        catch
        end
        _WEATHER_CNX[] = _weather_connect()
        return DataFrame(LibPQ.execute(_WEATHER_CNX[], sql, args))
    end
end

function close_weather_connection!()
    if _WEATHER_CNX[] !== nothing
        try
            close(_WEATHER_CNX[])
        catch
        end
        _WEATHER_CNX[] = nothing
    end
end

# ---------------------------------------------------------------------------
# Postgres → naive-UTC projection
# ---------------------------------------------------------------------------
"""
    projection(qfn, schema, table, casts=NOCAST) -> String

Column list where every `timestamp with time zone` column is emitted as
`col AT TIME ZONE 'UTC' AS col` (naive UTC) and everything else passes through
unchanged (already-naive timestamps — e.g. the weather tables' `measure_ts` —
need no conversion). `casts` forces explicit `col::TYPE AS col` conversions
(e.g. the unavailability table's TEXT outage timestamps → TIMESTAMP).
Introspects information_schema on the SOURCE database via `qfn`, so newly
added source columns (e.g. weather's shortwave_radiation / wind_speed_100m /
cloud_cover / diffuse_radiation) are carried automatically when present and
tolerated when absent.
"""
function projection(qfn::Function, schema::String, table::String,
                    casts::AbstractDict=NOCAST)
    df = qfn(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = \$1 AND table_name = \$2
        ORDER BY ordinal_position
        """,
        [schema, table])
    isempty(df) && error("Table $schema.$table not found in source database")
    parts = String[]
    for r in eachrow(df)
        col = String(r.column_name)
        if haskey(casts, col)
            push!(parts, "\"$col\"::$(casts[col]) AS \"$col\"")
        elseif String(r.data_type) == "timestamp with time zone"
            push!(parts, "\"$col\" AT TIME ZONE 'UTC' AS \"$col\"")
        else
            push!(parts, "\"$col\"")
        end
    end
    return join(parts, ", ")
end

# ---------------------------------------------------------------------------
# Table specs
# ---------------------------------------------------------------------------
"""
    mkspec(; schema, table, kwargs...) -> NamedTuple

One extract table. Fields:
- `source`     :energy | :weather
- `base_where` filter WITHOUT any time window (zones etc.; "" = none)
- `base_args`  positional args for `base_where`
- `ts_col`     the time column used for windowing (build) and watermark
               (refresh); "" = table has no usable time column
- `ts_tz`      true when `ts_col` is timestamptz in the SOURCE (bounds are
               written as `\$n::date::timestamp AT TIME ZONE 'UTC'`); false for
               naive-timestamp sources (weather measure_ts, yfinance date)
- `window`     `(lo_date, hi_date_excl)` build window on `ts_col`, or
               `nothing` for a full-table build
- `sort_by`    ORDER BY the table is materialized with (zonemap pruning)
- `casts`      explicit column type conversions (see `projection`)
- `refresh`    :append (watermark on `ts_col`) | :replace (re-pull wholesale)
"""
function mkspec(; source::Symbol=:energy, schema::String, table::String,
                base_where::String="", base_args::Vector{Any}=Any[],
                ts_col::String="", ts_tz::Bool=true,
                window::Union{Nothing,Tuple{Date,Date}}=nothing,
                sort_by::String="", casts::AbstractDict=NOCAST,
                refresh::Symbol=isempty(ts_col) ? :replace : :append)
    return (source=source, schema=schema, table=table,
            base_where=base_where, base_args=base_args,
            ts_col=ts_col, ts_tz=ts_tz, window=window,
            sort_by=sort_by, casts=casts, refresh=refresh)
end

# A date bound rendered for the source's timestamp flavor.
ts_bound(spec, n::Int) =
    spec.ts_tz ? "(\$$n::date::timestamp AT TIME ZONE 'UTC')" :
                 "(\$$n::date::timestamp)"

"WHERE + args for the full (windowed) build of `spec`."
function build_where_args(spec)
    if spec.window === nothing || isempty(spec.ts_col)
        return (spec.base_where, Any[spec.base_args...])
    end
    n = length(spec.base_args)
    cond = "$(spec.ts_col) >= $(ts_bound(spec, n + 1)) AND " *
           "$(spec.ts_col) < $(ts_bound(spec, n + 2))"
    w = isempty(spec.base_where) ? cond : "$(spec.base_where) AND $cond"
    return (w, Any[spec.base_args..., spec.window[1], spec.window[2]])
end

"""
    incremental_where_args(spec, watermark::DateTime, lo::Date, hi::Date)

WHERE + args for one refresh chunk: rows STRICTLY after the naive-UTC
`watermark`, restricted to the `[lo, hi)` day range (monthly chunking bounds
memory on long catch-ups). The watermark is bound as a naive timestamp and
converted to timestamptz for tz-aware sources.
"""
function incremental_where_args(spec, watermark::DateTime, lo::Date, hi::Date)
    isempty(spec.ts_col) && error("incremental refresh needs a ts_col ($(spec.schema).$(spec.table))")
    n = length(spec.base_args)
    wm_expr = spec.ts_tz ? "(\$$(n + 1)::timestamp AT TIME ZONE 'UTC')" :
                           "(\$$(n + 1)::timestamp)"
    cond = "$(spec.ts_col) > $wm_expr AND " *
           "$(spec.ts_col) >= $(ts_bound(spec, n + 2)) AND " *
           "$(spec.ts_col) < $(ts_bound(spec, n + 3))"
    w = isempty(spec.base_where) ? cond : "$(spec.base_where) AND $cond"
    args = Any[spec.base_args...,
               Dates.format(watermark, dateformat"yyyy-mm-dd HH:MM:SS.sss"),
               lo, hi]
    return (w, args)
end

count_sql(spec, where::String) =
    "SELECT count(*) AS c FROM $(spec.schema).$(spec.table)" *
    (isempty(where) ? "" : " WHERE $where")

select_sql(spec, cols::String, where::String) =
    "SELECT $cols FROM $(spec.schema).$(spec.table)" *
    (isempty(where) ? "" : " WHERE $where")

"Month boundaries [lo, hi) covering [from, until)."
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

# ---------------------------------------------------------------------------
# entsoe / yfinance / simulations specs (energy DB)
# ---------------------------------------------------------------------------
"""
    entsoe_table_specs(zones; start_date, end_date, aux_back_days=31,
                       agen_back_days=400) -> Vector

The energy-DB table set of the extract (same WHERE clauses / windows / sort
orders as the historical builder — extracts stay byte-comparable). Deep
lookbacks: per-type aggregate 400 days (365-day hydro availability + 30-day
p95); per-unit output `agen_back_days`; aux tables `aux_back_days`.
"""
function entsoe_table_specs(zones::Vector{String};
                            start_date::Date, end_date::Date,
                            aux_back_days::Int=31, agen_back_days::Int=400)
    back400 = start_date - Day(400)
    aux_back = start_date - Day(aux_back_days)
    agen_back = start_date - Day(agen_back_days)
    end_excl = end_date + Day(1)

    zone_where = "area_map_code = ANY(\$1)"
    specs = NamedTuple[]

    push!(specs, mkspec(schema="entsoe", table="day_ahead_total_load_forecast",
        base_where=zone_where, base_args=Any[zones],
        ts_col="date_time_utc", window=(aux_back, end_excl),
        sort_by="area_map_code, date_time_utc"))

    # Realized load — the :v3 analogue-day selector matches the delivery day's
    # load-forecast vector against the trailing 365 days of REALIZED load, so
    # the extract needs the 400-day back window (same rationale as the
    # aggregate-output tables). Absent this table :v3 degrades gracefully to
    # exact :v2 (warn + calendar climatology).
    push!(specs, mkspec(schema="entsoe", table="actual_total_load",
        base_where=zone_where, base_args=Any[zones],
        ts_col="date_time_utc", window=(back400, end_excl),
        sort_by="area_map_code, date_time_utc"))

    push!(specs, mkspec(schema="entsoe", table="generation_forecasts_for_wind_and_solar",
        base_where=zone_where, base_args=Any[zones],
        ts_col="date_time_utc", window=(aux_back, end_excl),
        sort_by="area_map_code, date_time_utc"))

    push!(specs, mkspec(schema="entsoe", table="energy_prices",
        base_where="map_code = ANY(\$1) AND contract_type = 'Day-ahead'",
        base_args=Any[zones],
        ts_col="date_time_utc", window=(aux_back, end_excl),
        sort_by="map_code, date_time_utc"))

    for tbl in ("offered_transfer_capacities_implicit",
                "offered_transfer_capacities_explicit")
        push!(specs, mkspec(schema="entsoe", table=tbl,
            base_where="(out_map_code = ANY(\$1) OR in_map_code = ANY(\$1))",
            base_args=Any[zones],
            ts_col="date_time_utc", window=(aux_back, end_excl),
            sort_by="out_map_code, in_map_code, date_time_utc"))
    end

    push!(specs, mkspec(schema="entsoe", table="physical_flows",
        base_where="(regexp_replace(in_area_map_code, '_IPS\$', '') = ANY(\$1) OR regexp_replace(out_area_map_code, '_IPS\$', '') = ANY(\$1))",
        base_args=Any[zones],
        ts_col="date_time_utc", window=(aux_back, end_excl),
        sort_by="in_area_map_code, out_area_map_code, date_time_utc"))

    push!(specs, mkspec(schema="entsoe", table="aggregated_generation_per_type",
        base_where=zone_where, base_args=Any[zones],
        ts_col="date_time_utc", window=(back400, end_excl),
        sort_by="area_map_code, production_type, date_time_utc"))

    # Weekly + tiny; full history keeps the prior-year reservoir-dryness norm
    # exact. No time column usable for a watermark → wholesale replace.
    push!(specs, mkspec(schema="entsoe", table="aggregated_hydro_storage_filling_rate",
        base_where=zone_where, base_args=Any[zones],
        sort_by="area_map_code, year, week", refresh=:replace))

    # Unit registry: validity rows get UPDATED (not appended) → replace.
    push!(specs, mkspec(schema="entsoe", table="production_and_generation_units",
        base_where=zone_where, base_args=Any[zones],
        sort_by="area_map_code, generation_unit_code", refresh=:replace))

    # Outages overlapping [back400, end_date]: existing records change status /
    # end time, so append-by-watermark would go stale → replace.
    gen_codes = "SELECT generation_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$1)"
    unit_codes = "$gen_codes UNION SELECT production_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$1)"
    push!(specs, mkspec(schema="entsoe", table="unavailability_of_production_and_generation_units",
        base_where="asset_code IN ($unit_codes) AND start_outage_utc IS NOT NULL AND end_outage_utc IS NOT NULL AND start_outage_utc::timestamp <= \$2::date::timestamp AND end_outage_utc::timestamp >= \$3::date::timestamp",
        base_args=Any[zones, end_date, back400],
        sort_by="asset_code, start_outage_utc",
        casts=Dict("start_outage_utc" => "TIMESTAMP", "end_outage_utc" => "TIMESTAMP"),
        refresh=:replace))

    push!(specs, mkspec(schema="entsoe", table="actual_generation_output_per_generation_unit",
        base_where="generation_unit_code IN ($gen_codes)", base_args=Any[zones],
        ts_col="date_time_utc", window=(agen_back, end_excl),
        sort_by="generation_unit_code, date_time_utc"))

    return specs
end

"yfinance price feeds: full history, tiny; `date` is a NAIVE timestamp."
function yfinance_table_specs()
    return NamedTuple[
        mkspec(schema="yfinance", table="ttf_f", ts_col="date", ts_tz=false,
               sort_by="date", refresh=:append),
        mkspec(schema="yfinance", table="eua_co2", ts_col="date", ts_tz=false,
               sort_by="date", refresh=:append),
    ]
end

"simulations reference caches: tiny, mutable → replace."
function simulations_table_specs(zones::Vector{String})
    return NamedTuple[
        mkspec(schema="simulations", table="unit_firms",
               base_where="zone = ANY(\$1)", base_args=Any[zones],
               refresh=:replace),
    ]
end

# ---------------------------------------------------------------------------
# weather specs (separate weather DB)
# ---------------------------------------------------------------------------
"""
    weather_table_specs(; back_days=400, today=Dates.today()) -> Vector

The `weather` schema (separate weather DB): `city` (full registry), `city_forecast`
(last `back_days`; measure_ts is a NAIVE GMT timestamp in the source, so it is
already the naive UTC the extract stores), `city_forecast_vintage` (full).

Refresh semantics: `city_forecast` / `city_forecast_vintage` append rows with
`measure_ts` beyond the extract's max. Forecast REVISIONS of already-carried
future hours are upserts in the source and are NOT re-fetched by an append —
the vintage table carries issue-time snapshots, and the recommended monthly
full rebuild trues up the revised hours.
"""
function weather_table_specs(; back_days::Int=400, today::Date=Dates.today())
    return NamedTuple[
        mkspec(source=:weather, schema="weather", table="city",
               sort_by="city_id", refresh=:replace),
        mkspec(source=:weather, schema="weather", table="city_forecast",
               ts_col="measure_ts", ts_tz=false,
               window=(today - Day(back_days), today + Day(17)),
               sort_by="city_id, measure_ts"),
        mkspec(source=:weather, schema="weather", table="city_forecast_vintage",
               ts_col="measure_ts", ts_tz=false,
               sort_by="city_id, measure_ts"),
    ]
end

# ---------------------------------------------------------------------------
# DuckDB build / append primitives
# ---------------------------------------------------------------------------
duckdb_target(spec) = "\"$(spec.schema)\".\"$(spec.table)\""

"Does `schema.table` exist in the DuckDB extract?"
function duckdb_table_exists(con, schema::String, table::String)
    df = DataFrame(DBInterface.execute(con,
        "SELECT count(*) AS c FROM information_schema.tables " *
        "WHERE table_schema = '$schema' AND table_name = '$table'"))
    return df.c[1] > 0
end

"Max value of `ts_col` in the extract table (naive UTC), or `nothing`."
function duckdb_max_ts(con, spec)
    df = DataFrame(DBInterface.execute(con,
        "SELECT max($(spec.ts_col)) AS m FROM $(duckdb_target(spec))"))
    m = df.m[1]
    m === missing && return nothing
    m isa DateTime && return m
    m isa Date && return DateTime(m)
    return DateTime(string(m)[1:min(end, 23)])  # tolerate string-typed results
end

function duckdb_rowcount(con, spec)
    df = DataFrame(DBInterface.execute(con,
        "SELECT count(*) AS c FROM $(duckdb_target(spec))"))
    return Int(df.c[1])
end

"""
    build_table!(con, spec; chunk_threshold, expected=nothing, replace=false) -> rows

Materialize `spec` in the extract (CREATE TABLE ... ORDER BY sort_by; CREATE OR
REPLACE when `replace`). Tables above `chunk_threshold` rows with a windowed
`ts_col` are built in monthly chunks to bound Julia memory (each chunk sorted
within itself). `expected` skips the pre-count when the caller already has it.
"""
function build_table!(con, spec; chunk_threshold::Int, expected::Union{Nothing,Int}=nothing,
                      replace::Bool=false)
    qfn = query_fn(spec.source)
    cols = projection(qfn, spec.schema, spec.table, spec.casts)
    (where, args) = build_where_args(spec)
    if expected === nothing
        c = qfn(count_sql(spec, where), args).c[1]
        expected = c === missing ? 0 : Int(c)
    end
    tgt = duckdb_target(spec)
    order = isempty(spec.sort_by) ? "" : " ORDER BY $(spec.sort_by)"
    create = replace ? "CREATE OR REPLACE TABLE" : "CREATE TABLE"

    if expected > chunk_threshold && spec.window !== nothing && !isempty(spec.ts_col)
        ranges = month_ranges(spec.window[1], spec.window[2])
        created = false
        total = 0
        for (i, (lo, hi)) in enumerate(ranges)
            n = length(args)
            mwhere = where *
                     " AND $(spec.ts_col) >= $(ts_bound(spec, n + 1))" *
                     " AND $(spec.ts_col) < $(ts_bound(spec, n + 2))"
            df = qfn(select_sql(spec, cols, mwhere), Any[args..., lo, hi])
            view = "_stage_chunk"
            DuckDB.register_data_frame(con, df, view)
            if !created
                DBInterface.execute(con, "$create $tgt AS SELECT * FROM $view$order")
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
        # A chunked CREATE with zero ranges never creates the table.
        if !created
            df = qfn(select_sql(spec, cols, where), args)
            view = "_stage_empty"
            DuckDB.register_data_frame(con, df, view)
            DBInterface.execute(con, "$create $tgt AS SELECT * FROM $view$order")
            DuckDB.unregister_data_frame(con, view)
            total = nrow(df)
        end
        return total
    else
        df = qfn(select_sql(spec, cols, where), args)
        view = "_stage_" * spec.schema * "_" * spec.table
        DuckDB.register_data_frame(con, df, view)
        DBInterface.execute(con, "$create $tgt AS SELECT * FROM $view$order")
        DuckDB.unregister_data_frame(con, view)
        return nrow(df)
    end
end

"""
    append_incremental!(con, spec; today=Dates.today(), horizon_days=17,
                        rewindow_days=14) -> rows

Refresh rows of `spec` from the source in MONTHLY chunks up to
`today + horizon_days` (future-dated rows: D+1 delivery data, weather
forecast horizon). NOT a pure strictly-after-watermark append: ENTSO-E
publishes rows for a delivery timestamp over the FOLLOWING days (measured:
Day-ahead ATC for 2026-07-16..27 arrived after rows for 07-28 existed, so a
strict watermark skipped 55 of 57 borders forever — the cv23 backfill's 11
failed tail days). The trailing `rewindow_days` before the watermark are
therefore DELETED and re-fetched wholesale (idempotent; a few days of rows),
so late arrivals heal on every refresh. Each slab is sorted by `sort_by`
within itself before insertion (see the header note on zonemap degradation).
"""
function append_incremental!(con, spec; today::Date=Dates.today(), horizon_days::Int=17,
                             rewindow_days::Int=14)
    qfn = query_fn(spec.source)
    watermark = duckdb_max_ts(con, spec)
    watermark === nothing &&
        error("append_incremental!: $(duckdb_target(spec)) is empty — build it first")
    cols = projection(qfn, spec.schema, spec.table, spec.casts)
    tgt = duckdb_target(spec)
    order = isempty(spec.sort_by) ? "" : " ORDER BY $(spec.sort_by)"
    hi_end = today + Day(horizon_days)
    # Rewindow: pull the fetch window back and clear those extract rows first,
    # so late-published source rows inside it are (re)captured.
    rw_start = Date(watermark) - Day(rewindow_days)
    if rewindow_days > 0
        DBInterface.execute(con,
            "DELETE FROM $tgt WHERE CAST($(spec.ts_col) AS TIMESTAMP) >= ?",
            [DateTime(rw_start)])
    end
    watermark = DateTime(rw_start) - Second(1)
    lo_start = rw_start
    lo_start >= hi_end && return 0
    total = 0
    for (lo, hi) in month_ranges(lo_start, hi_end)
        (where, args) = incremental_where_args(spec, watermark, lo, hi)
        df = qfn(select_sql(spec, cols, where), args)
        isempty(df) && continue
        view = "_stage_append"
        DuckDB.register_data_frame(con, df, view)
        DBInterface.execute(con, "INSERT INTO $tgt SELECT * FROM $view$order")
        DuckDB.unregister_data_frame(con, view)
        total += nrow(df)
    end
    return total
end

# ---------------------------------------------------------------------------
# weather.cell_hourly — the ERA5 feature history at the wind-catalogue cells
# ---------------------------------------------------------------------------
const CELL_HOURLY_DDL = """
    CREATE TABLE IF NOT EXISTS weather.cell_hourly(
        zone TEXT, lat DOUBLE, lon DOUBLE, h TIMESTAMP,
        v100 DOUBLE, ghi DOUBLE, source TEXT)"""

"""
    seed_cell_hourly!(con, csv_path; zones=String[], source="era5") -> rows

Create `weather.cell_hourly` and seed it from a CSV with header
`zone,lat,lon,h,v100,ghi` (the ERA5 fitting history of the weather-RES models,
bin/res_models_v1.json). `zones` restricts the seed to the extract's zones
(empty = all). Units follow the open-meteo archive defaults the models were
fitted on: v100 in km/h, ghi (shortwave_radiation) in W/m².
"""
function seed_cell_hourly!(con, csv_path::AbstractString;
                           zones::Vector{String}=String[], source::String="era5")
    isfile(csv_path) || error("cell_hourly seed CSV not found: $csv_path")
    DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS weather")
    DBInterface.execute(con, CELL_HOURLY_DDL)
    zf = isempty(zones) ? "" :
         " WHERE zone IN (" * join(("'" * z * "'" for z in zones), ",") * ")"
    DBInterface.execute(con, """
        INSERT INTO weather.cell_hourly
        SELECT zone, lat, lon, h, v100, ghi, '$source' AS source
        FROM read_csv('$(csv_path)', header=true, timestampformat='%Y-%m-%dT%H:%M',
                      columns={'zone':'TEXT','lat':'DOUBLE','lon':'DOUBLE',
                               'h':'TIMESTAMP','v100':'DOUBLE','ghi':'DOUBLE'})$zf
        ORDER BY zone, lat, lon, h""")
    df = DataFrame(DBInterface.execute(con,
        "SELECT count(*) AS c FROM weather.cell_hourly WHERE source = '$source'"))
    return Int(df.c[1])
end

"""
    cell_fetch_window(watermark, today; lag_days=5) -> Union{Nothing,Tuple{Date,Date}}

The `[start_date, end_date]` day range the open-meteo ERA5 archive refresh
should fetch: from the watermark's day (the last day may be partial — fetched
rows at or before the watermark are filtered out by the caller) up to
`today - lag_days` (ERA5 lags ~5 days). `nothing` when already up to date.
"""
function cell_fetch_window(watermark::Union{Nothing,DateTime}, today::Date;
                           lag_days::Int=5)
    end_date = today - Day(lag_days)
    start_date = watermark === nothing ? end_date - Day(400) : Date(watermark)
    # Up to date when the watermark already covers end_date's final hour.
    watermark !== nothing && watermark >= DateTime(end_date) + Hour(23) && return nothing
    start_date > end_date && return nothing
    return (start_date, end_date)
end
