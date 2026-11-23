# Fill manifest + fill step (owner rule, 2026-11-23: DuckDB between Postgres and Julia).
#
# A run (record days or the daily forecast's UTC days) declares its delivery DAYS and ZONES.
# `fill_run_duckdb` copies exactly the input rows the run's readers need from Postgres into a
# run-local DuckDB, through DuckDB's postgres extension (`postgres_query`: the filter runs inside
# Postgres; rows stream engine to engine, never through Julia). Same `schema.table` names, naive
# UTC timestamps and `ORDER BY` layout as the extract (bin/extract_common.jl), so the existing
# DuckDB backend reads it unchanged. Windows come from the CODE's lookbacks (FILL_SPECS), so the
# fill is faithful to production Postgres, which holds full history.
#
# `_fill.windows` records every filled (table, lo, hi); the strict guard in `_duckdb_sql2df`
# rejects a read of a table or a date outside them (fail loudly, never fall back to Postgres).

"""
One manifest entry. `back`/`ahead` are days around each delivery day `d`: the table's filled
window is the union over DAYS of `[d - back, d + ahead + 1)`. `zone_pred` is a Postgres
predicate template where `\$ZONES` becomes the zone array literal ("" = no zone filter).
`kind`: `:window` (time column), `:full` (whole table, small), `:overlap` (interval tables:
all versions of every message with a version overlapping a run day window), `:per_unit` (per-unit generation: window plus
the per-zone stale-feed extension), `:da_sentinel` (offered implicit ATC: window plus one
earliest Day-ahead row per border, which keeps `_da_ever_borders`' all-history DISTINCT exact).
"""
const FillSpec = NamedTuple{(:schema, :table, :kind, :zone_pred, :ts_col, :ts_tz, :back, :ahead,
                             :sort_by, :casts),
                            Tuple{String,String,Symbol,String,String,Bool,Int,Int,String,Dict{String,String}}}

_fs(schema, table, kind; zone_pred="", ts_col="", ts_tz=true, back=0, ahead=0, sort_by="",
    casts=Dict{String,String}()) =
    FillSpec((schema, table, kind, zone_pred, ts_col, ts_tz, back, ahead, sort_by, casts))

const _ZONE_AREA = "area_map_code = ANY(\$ZONES)"
const _UNITS_OF_ZONES = "SELECT generation_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$ZONES)"

"""
    FILL_SPECS

The clearing path's input tables (record and forecast). Lookbacks (days) from the readers:
load/RES forecasts and ATC/JAO: the delivery day plus the trailing windows the readers use
(trailing Day-ahead ATC 7 d, RES baseline, analogue features); actual load 400 (:v3 analogue
days, 365); physical flows 400 (366-day demonstrated capability, 365-day boundary flows,
net-import lags/analogues); aggregated generation 400 (365-day hydro availability, 30-day p95,
14-day pump profile); per-unit generation 75 (60-day recent generation from the feed bound,
7-day stale override, 7-day feed probe) plus the stale-feed extension.
"""
const FILL_SPECS = FillSpec[
    _fs("entsoe", "day_ahead_total_load_forecast", :window; zone_pred=_ZONE_AREA,
        ts_col="date_time_utc", back=31, ahead=2, sort_by="area_map_code, date_time_utc"),
    _fs("entsoe", "actual_total_load", :window; zone_pred=_ZONE_AREA,
        ts_col="date_time_utc", back=400, ahead=0, sort_by="area_map_code, date_time_utc"),
    _fs("entsoe", "generation_forecasts_for_wind_and_solar", :window; zone_pred=_ZONE_AREA,
        ts_col="date_time_utc", back=31, ahead=2, sort_by="area_map_code, date_time_utc"),
    _fs("entsoe", "energy_prices", :window;
        zone_pred="map_code = ANY(\$ZONES) AND contract_type = 'Day-ahead'",
        ts_col="date_time_utc", back=31, ahead=1, sort_by="map_code, date_time_utc"),
    _fs("entsoe", "offered_transfer_capacities_implicit", :da_sentinel;
        zone_pred="(out_map_code = ANY(\$ZONES) OR in_map_code = ANY(\$ZONES))",
        ts_col="date_time_utc", back=31, ahead=1, sort_by="out_map_code, in_map_code, date_time_utc"),
    _fs("entsoe", "offered_transfer_capacities_explicit", :window;
        zone_pred="(out_map_code = ANY(\$ZONES) OR in_map_code = ANY(\$ZONES))",
        ts_col="date_time_utc", back=31, ahead=1, sort_by="out_map_code, in_map_code, date_time_utc"),
    _fs("jao", "max_exchanges", :window; ts_col="date_time_utc", back=31, ahead=1,
        sort_by="ccr, border_from, border_to, date_time_utc"),
    _fs("jao", "hub_net_positions", :window; ts_col="date_time_utc", back=31, ahead=1,
        sort_by="ccr, hub, date_time_utc"),
    _fs("entsoe", "physical_flows", :window;
        zone_pred="(regexp_replace(in_area_map_code, '_IPS\$', '') = ANY(\$ZONES) OR regexp_replace(out_area_map_code, '_IPS\$', '') = ANY(\$ZONES))",
        ts_col="date_time_utc", back=400, ahead=0, sort_by="in_area_map_code, out_area_map_code, date_time_utc"),
    _fs("entsoe", "aggregated_generation_per_type", :window; zone_pred=_ZONE_AREA,
        ts_col="date_time_utc", back=400, ahead=0, sort_by="area_map_code, production_type, date_time_utc"),
    _fs("entsoe", "aggregated_hydro_storage_filling_rate", :full; zone_pred=_ZONE_AREA,
        sort_by="area_map_code, year, week"),
    _fs("entsoe", "production_and_generation_units", :full; zone_pred=_ZONE_AREA,
        sort_by="area_map_code, generation_unit_code"),
    _fs("entsoe", "unavailability_of_production_and_generation_units", :overlap;
        zone_pred="asset_code IN ($_UNITS_OF_ZONES UNION SELECT production_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY(\$ZONES))",
        back=1, ahead=1, sort_by="asset_code, start_outage_utc",
        casts=Dict("start_outage_utc" => "TIMESTAMP", "end_outage_utc" => "TIMESTAMP")),
    _fs("entsoe", "unavailability_in_the_transmission_grid", :overlap; back=1, ahead=1,
        sort_by="out_area_map_code, in_area_map_code, start_outage_utc",
        casts=Dict("start_outage_utc" => "TIMESTAMP", "end_outage_utc" => "TIMESTAMP",
                   "version_publication_timestamp_utc" => "TIMESTAMP")),
    _fs("entsoe", "actual_generation_output_per_generation_unit", :per_unit;
        zone_pred="generation_unit_code IN ($_UNITS_OF_ZONES)",
        ts_col="date_time_utc", back=75, ahead=0, sort_by="generation_unit_code, date_time_utc"),
    _fs("yfinance", "ttf_f", :full; sort_by="date"),
    _fs("yfinance", "eua_co2", :full; sort_by="date"),
    _fs("epias", "mcp", :full; sort_by="date_time_utc"),
    _fs("epias", "load_forecast", :full; sort_by="date_time_utc"),
    _fs("epias", "gas_reference_price", :full; sort_by="date_time_utc"),
    _fs("epias", "actual_generation", :full; sort_by="date_time_utc, source"),
    # simulations.input_corrections is NOT an input: the forecast job writes it and the cv32
    # reader reads it back through the results_db redirect, so it is a results seed (fill_profile).
    _fs("simulations", "unit_firms", :full; zone_pred="zone = ANY(\$ZONES)"),
]

# ---------------------------------------------------------------------------
# literals and windows
# ---------------------------------------------------------------------------
_pg_str(s) = "'" * replace(String(s), "'" => "''") * "'"
_pg_zones(zones) = "ARRAY[" * join((_pg_str(z) for z in zones), ", ") * "]::text[]"
_pg_day(d::Date, tz::Bool) = tz ? "($(_pg_str(Dates.format(d, "yyyy-mm-dd")))::date::timestamp AT TIME ZONE 'UTC')" :
                                  "$(_pg_str(Dates.format(d, "yyyy-mm-dd")))::timestamp"

"Merged `[lo, hi)` day intervals: the union over `days` of `[d - back, d + ahead + 1)`."
function fill_windows(days, back::Int, ahead::Int)
    iv = sort([(d - Day(back), d + Day(ahead + 1)) for d in unique(days)])
    out = Tuple{Date,Date}[]
    for (lo, hi) in iv
        if !isempty(out) && lo <= out[end][2]
            out[end] = (out[end][1], max(out[end][2], hi))
        else
            push!(out, (lo, hi))
        end
    end
    return out
end

_time_pred(col, wins, tz) = "(" * join(("($col >= $(_pg_day(lo, tz)) AND $col < $(_pg_day(hi, tz)))"
                                        for (lo, hi) in wins), " OR ") * ")"

"""
    fill_pg_query(spec, days, zones; stale_lo=Dict()) -> (sql, windows)

The Postgres-side SELECT for one manifest entry (filters with literals, every timestamptz
column projected `AT TIME ZONE 'UTC'` like the extract builder) and the `[lo, hi)` windows it
covers (empty for full tables). `cols` is the source column list `(name, pg_type)`.
"""
function fill_pg_query(spec::FillSpec, cols, days, zones; stale_lo::Dict{String,Date}=Dict{String,Date}())
    proj = join((haskey(spec.casts, c) ? "\"$c\"::$(spec.casts[c]) AS \"$c\"" :
                 t == "timestamp with time zone" ? "\"$c\" AT TIME ZONE 'UTC' AS \"$c\"" : "\"$c\""
                 for (c, t) in cols), ", ")
    preds = String[]
    isempty(spec.zone_pred) || push!(preds, replace(spec.zone_pred, "\$ZONES" => _pg_zones(zones)))
    wins = Tuple{Date,Date}[]
    if spec.kind in (:window, :da_sentinel, :per_unit)
        wins = fill_windows(days, spec.back, spec.ahead)
        tp = _time_pred(spec.ts_col, wins, spec.ts_tz)
        if spec.kind === :per_unit && !isempty(stale_lo)
            # stale-feed zones: the rescue window anchors at the zone's last observation,
            # which can lie before the common window
            first_lo = wins[1][1]
            ext = ["(generation_unit_code IN (SELECT generation_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code = $(_pg_str(z))) AND $(spec.ts_col) >= $(_pg_day(lo, true)) AND $(spec.ts_col) < $(_pg_day(first_lo, true)))"
                   for (z, lo) in sort(collect(stale_lo)) if lo < first_lo]
            isempty(ext) || (tp = "($tp OR " * join(ext, " OR ") * ")")
        end
        push!(preds, tp)
    elseif spec.kind === :overlap
        # The outage readers (_day_outages_*, tx_outage_caps) pick every MESSAGE with any version
        # overlapping the delivery day, then take the version known at the gate, which may have
        # moved outside the day: copy ALL versions (rows) of every message (instance_code) with a
        # version overlapping one of the run's day windows ([d - back, d + ahead + 1), unioned).
        wins = fill_windows(days, spec.back, spec.ahead)
        ov = join(("(start_outage_utc::timestamp < $(_pg_day(hi, false)) AND end_outage_utc::timestamp >= $(_pg_day(lo, false)))"
                   for (lo, hi) in wins), " OR ")
        push!(preds, "instance_code IN (SELECT instance_code FROM $(spec.schema).$(spec.table) " *
                     "WHERE start_outage_utc IS NOT NULL AND end_outage_utc IS NOT NULL AND ($ov))")
    end
    where = isempty(preds) ? "" : " WHERE " * join(preds, " AND ")
    sql = "SELECT $proj FROM $(spec.schema).$(spec.table)$where"
    if spec.kind === :da_sentinel
        zp = isempty(spec.zone_pred) ? "" : " AND " * replace(spec.zone_pred, "\$ZONES" => _pg_zones(zones))
        sql *= " UNION ALL SELECT * FROM (SELECT DISTINCT ON (out_map_code, in_map_code) $proj " *
               "FROM $(spec.schema).$(spec.table) WHERE contract_type = 'Day-ahead' AND " *
               "$(spec.ts_col) < $(_pg_day(wins[1][1], spec.ts_tz))$zp " *
               "ORDER BY out_map_code, in_map_code, $(spec.ts_col)) s"
    end
    return sql, wins
end

# ---------------------------------------------------------------------------
# the fill
# ---------------------------------------------------------------------------
# A fill source is Postgres (production: `postgres_query` runs the filter SQL inside Postgres)
# or, for offline proofs, a DuckDB extract attached READ_ONLY as `src` (the same filter SQL,
# through the backend's dialect rewrite, with every source table qualified `src.`).
const _FILL_SOURCE = Ref{Symbol}(:postgres)
_qualify_src(sql) = replace(_duckdb_rewrite(sql),
    r"(?<![\w.])(entsoe|jao|yfinance|epias|simulations|weather|information_schema)\." => s"src.\1.")
_src_from(sql) = _FILL_SOURCE[] === :postgres ? "postgres_query('pg', $(_pg_str(sql)))" :
                                                 "($(_qualify_src(sql)))"
_pg_rows(con, sql) = collect(DBInterface.execute(con, "SELECT * FROM $(_src_from(sql))"))

"Source columns `(name, data_type)` of a Postgres table, via the attached catalog."
function _pg_columns(con, schema, table)
    rows = _FILL_SOURCE[] === :postgres ?
        _pg_rows(con, "SELECT column_name, data_type FROM information_schema.columns " *
                      "WHERE table_schema = $(_pg_str(schema)) AND table_name = $(_pg_str(table)) " *
                      "ORDER BY ordinal_position") :
        collect(DBInterface.execute(con, "SELECT column_name, data_type FROM information_schema.columns " *
                      "WHERE table_catalog = 'src' AND table_schema = $(_pg_str(schema)) AND table_name = $(_pg_str(table)) " *
                      "ORDER BY ordinal_position"))
    isempty(rows) && error("fill: $schema.$table not found in Postgres")
    return [(String(r.column_name), String(r.data_type)) for r in rows]
end

"""
Per-zone lower bound of the per-unit window for stale feeds. For the earliest feed bound of the
run (`bound_min`), zones with no positive output in its last FEED_STALE_DAYS get
`last_obs - RESCUE_WINDOW` (their rescue window starts there on every later day too, since the
last observation can only move forward). Same SQL semantics as `_feed_last_obs`.
"""
function _stale_feed_lower(con, zones, bound_min::DateTime)
    fmt(t) = Dates.format(t, "yyyy-mm-dd HH:MM:SS")
    units = "SELECT DISTINCT generation_unit_code, area_map_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY($(_pg_zones(zones)))"
    healthy = Set(String(r.z) for r in _pg_rows(con,
        "SELECT DISTINCT u.area_map_code AS z FROM entsoe.actual_generation_output_per_generation_unit a " *
        "JOIN ($units) u USING (generation_unit_code) " *
        "WHERE a.date_time_utc >= TIMESTAMP $(_pg_str(fmt(ceil(bound_min - FEED_STALE_DAYS, Dates.Second)))) " *
        "AND a.date_time_utc < TIMESTAMP $(_pg_str(fmt(bound_min))) AND a.actual_generation_output_mw > 0"))
    stale = [z for z in zones if !(z in healthy)]
    out = Dict{String,Date}()
    isempty(stale) && return out
    for r in _pg_rows(con,
        "SELECT u.area_map_code AS z, MAX(a.date_time_utc) AS last_obs FROM entsoe.actual_generation_output_per_generation_unit a " *
        "JOIN (SELECT DISTINCT generation_unit_code, area_map_code FROM entsoe.production_and_generation_units WHERE area_map_code = ANY($(_pg_zones(stale)))) u " *
        "USING (generation_unit_code) WHERE a.date_time_utc < TIMESTAMP $(_pg_str(fmt(bound_min))) " *
        "AND a.actual_generation_output_mw > 0 GROUP BY 1")
        ismissing(r.last_obs) && continue
        out[String(r.z)] = Date(DateTime(r.last_obs) - RESCUE_WINDOW) - Day(1)
    end
    return out
end

"""
    fill_run_duckdb(path; days, zones, conn_str, feed_bound_min=nothing, specs=FILL_SPECS) -> path

Create the run-local inputs DuckDB at `path` (must not exist) with every manifest table for
`days` × `zones`, copied from Postgres by DuckDB's postgres extension. `feed_bound_min` is the
earliest per-unit feed bound of the run (record: `minimum(days) - 7 d + 10 h`; forecast:
`issuance - 6 d`); it decides the stale-feed extension. Writes `_fill.windows` (one row per
filled interval) and `_fill.run` (days, zones, timings) for the strict read guard.
"""
function fill_run_duckdb(path::AbstractString; days, zones::Vector{String}, conn_str::AbstractString="",
                         feed_bound_min::Union{Nothing,DateTime}=nothing,
                         specs::Vector{FillSpec}=FILL_SPECS,
                         source::Symbol=:postgres, source_path::AbstractString="")
    ispath(path) && error("fill_run_duckdb: $path exists (a run DB is created fresh)")
    days = sort(unique(Date.(days)))
    isempty(days) && error("fill_run_duckdb: no days")
    t_all = time()
    db = DuckDB.DB(String(path))
    con = DBInterface.connect(db)
    try
        DBInterface.execute(con, "SET TimeZone = 'UTC'")
        # DuckDB sizes itself from the machine, not the process's cgroup: bound it explicitly
        # (EUPHEMIA_FILL_MEMORY / EUPHEMIA_FILL_THREADS; spill next to the run file).
        DBInterface.execute(con, "SET memory_limit = $(_pg_str(get(ENV, "EUPHEMIA_FILL_MEMORY", "3GB")))")
        DBInterface.execute(con, "SET threads = $(parse(Int, get(ENV, "EUPHEMIA_FILL_THREADS", "4")))")
        tmpdir = String(path) * ".tmp"
        mkpath(tmpdir)
        DBInterface.execute(con, "SET temp_directory = $(_pg_str(tmpdir))")
        DBInterface.execute(con, "SET preserve_insertion_order = false")
        source in (:postgres, :duckdb) || error("fill_run_duckdb: source must be :postgres or :duckdb")
        _FILL_SOURCE[] = source
        if source === :postgres
            attach_postgres!(con, conn_str; alias="pg", read_only=true)
        else
            isfile(source_path) || error("fill_run_duckdb: source DuckDB $source_path not found")
            DBInterface.execute(con, "ATTACH $(_pg_str(source_path)) AS src (READ_ONLY)")
        end
        DBInterface.execute(con, "CREATE SCHEMA _fill")
        DBInterface.execute(con, "CREATE TABLE _fill.windows (schema_name VARCHAR, table_name VARCHAR, kind VARCHAR, lo DATE, hi DATE, n_rows BIGINT, seconds DOUBLE)")
        bmin = feed_bound_min === nothing ? DateTime(minimum(days)) - Day(7) + Hour(10) : feed_bound_min
        t0 = time()
        stale_lo = any(s -> s.kind === :per_unit, specs) ? _stale_feed_lower(con, zones, bmin) : Dict{String,Date}()
        println("  fill: stale-feed zones $(sort(collect(keys(stale_lo)))) ($(round(time() - t0, digits=1)) s)"); flush(stdout)
        for spec in specs
            t0 = time()
            cols = try
                _pg_columns(con, spec.schema, spec.table)
            catch e
                "$(spec.schema).$(spec.table)" in FILL_OPTIONAL || rethrow()
                println("  fill $(spec.schema).$(spec.table): absent in the source, skipped (optional; reads fail the guard)"); flush(stdout)
                continue
            end
            sql, wins = fill_pg_query(spec, cols, days, zones; stale_lo=stale_lo)
            DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS $(spec.schema)")
            order = isempty(spec.sort_by) ? "" : " ORDER BY $(spec.sort_by)"
            DBInterface.execute(con, "CREATE TABLE $(spec.schema).$(spec.table) AS SELECT * FROM $(_src_from(sql))$order")
            n = collect(DBInterface.execute(con, "SELECT count(*) AS n FROM $(spec.schema).$(spec.table)"))[1].n
            dt = time() - t0
            ws = isempty(wins) ? [(Date(1900, 1, 1), Date(2999, 12, 31))] : wins
            if spec.kind === :per_unit && !isempty(stale_lo)
                ws = vcat(ws, [(lo, wins[1][1]) for lo in values(stale_lo) if lo < wins[1][1]])
            end
            for (lo, hi) in ws
                DBInterface.execute(con, "INSERT INTO _fill.windows VALUES ($(_pg_str(spec.schema)), $(_pg_str(spec.table)), $(_pg_str(String(spec.kind))), DATE $(_pg_str(string(lo))), DATE $(_pg_str(string(hi))), $n, $dt)")
            end
            println("  fill $(spec.schema).$(spec.table): $n rows, $(round(dt, digits=1)) s"); flush(stdout)
        end
        DBInterface.execute(con, "CREATE TABLE _fill.run AS SELECT $(_pg_str(join(string.(days), ","))) AS days, $(_pg_str(join(zones, ","))) AS zones, $(round(time() - t_all, digits=2)) AS seconds, now() AS filled_at")
        source === :postgres ? detach_postgres!(con) : DBInterface.execute(con, "DETACH src")
    finally
        _FILL_SOURCE[] = :postgres
        rm(String(path) * ".tmp"; force=true, recursive=true)
        DBInterface.close!(con)
        DuckDB.close(db)
    end
    return String(path)
end

# ---------------------------------------------------------------------------
# Profiles: which input tables (inputs.duckdb) and which results-side slices (results.duckdb,
# seeded for read-back) a production job needs.
# ---------------------------------------------------------------------------
# Optional inputs: tables production Postgres holds but older sources may lack. A missing
# optional table is skipped (no _fill.windows row), so any read of it fails the guard loudly.
const FILL_OPTIONAL = Set(["carbon.uka_price", "simulations.model_lines", "simulations.tsfm_overlay"])

"Extra input tables of the forecast job's score/export steps and the GB boundary book."
const FORECAST_EXTRA_SPECS = FillSpec[
    _fs("carbon", "uka_price", :full; sort_by=""),                       # fuel_costs.jl uka_price (GB boundary)
    _fs("simulations", "model_lines", :full),                            # exporters (model_lines_map)
    _fs("simulations", "tsfm_overlay", :full),                           # TSFM_OVERLAY_SQL reads from 2000-01-01
]

"""
    fill_profile(profile; start, stop, asof, zones) -> (days, zones, specs, seeds)

`:record`: delivery days `start:stop`, the clearing tables. `:daily_forecast` / `:export`:
the run's UTC days `asof-1 … asof+8` (7 leads + the stitched next-day tails), the clearing
tables (the score/export steps of the same job reuse the inputs), actual prices 400 days back
(scorer and exporters), and the extra forecast tables. `seeds` are the results-side slices
copied into results.duckdb for read-back.
"""
function fill_profile(profile::Symbol; start::Union{Nothing,Date}=nothing, stop::Union{Nothing,Date}=nothing,
                      asof::Date=Date(Dates.now(Dates.UTC)), zones::Vector{String},
                      inputs_back_days::Int=0, days_list::Union{Nothing,Vector{Date}}=nothing)
    if profile === :record
        days = days_list !== nothing ? sort(unique(days_list)) :
               (start === nothing || stop === nothing) ? error("fill profile :record needs start/stop or a day list") :
               collect(start:Day(1):stop)
        specs = FILL_SPECS
        ep = join(("(date_time_utc >= $(_pg_day(lo, true)) AND date_time_utc < $(_pg_day(hi, true)))" for (lo, hi) in fill_windows(days, 0, 0)), " OR ")
        ic = join(("(date_time_utc >= $(_pg_day(lo, false)) AND date_time_utc < $(_pg_day(hi, false)))" for (lo, hi) in fill_windows(days, 1, 2)), " OR ")
        seeds = [(table="energy_prices", where=ep), (table="input_corrections", where=ic)]
    elseif profile in (:daily_forecast, :export)
        days = collect((asof - Day(1)):Day(1):(asof + Day(8)))
        specs = FillSpec[s.table == "energy_prices" ?
                         _fs("entsoe", "energy_prices", :window; zone_pred=s.zone_pred, ts_col=s.ts_col,
                             back=400, ahead=1, sort_by=s.sort_by) : s for s in FILL_SPECS]
        append!(specs, FORECAST_EXTRA_SPECS)
        # export_prediction_inputs.jl reads INPUTS_BACK_DAYS back on these tables
        if inputs_back_days > 0
            ib = Set(["generation_forecasts_for_wind_and_solar", "aggregated_generation_per_type",
                      "actual_total_load", "day_ahead_total_load_forecast"])
            specs = FillSpec[(s.table in ib && s.kind === :window && s.back < inputs_back_days + 1) ?
                             _fs(s.schema, s.table, s.kind; zone_pred=s.zone_pred, ts_col=s.ts_col, ts_tz=s.ts_tz,
                                 back=inputs_back_days + 1, ahead=s.ahead, sort_by=s.sort_by, casts=s.casts) : s
                             for s in specs]
        end
        seeds = [(table="forecast_prices", where=""),
                 (table="forecast_scores", where=""),
                 (table="input_corrections", where="date_time_utc >= $(_pg_day(asof - Day(5), false)) AND date_time_utc < $(_pg_day(asof + Day(10), false))"),
                 (table="transmission_flows", where="date_time_utc >= $(_pg_day(asof - Day(121), true))")]
    else
        error("unknown fill profile $profile (record | daily_forecast | export)")
    end
    return (days=days, zones=zones, specs=specs, seeds=seeds)
end

"""
    seed_run_results!(con, seeds) -> Vector{(table, rows, seconds)}

Copy each results-side slice from Postgres (`pg`, already attached on `con`) into the attached
results file (`results_db.simulations.<table>`, created beforehand by the results-side ensure
functions). Columns = the results table's columns that Postgres also has (local-only columns
such as `transfer_op_id` stay NULL); timestamptz arrive as naive UTC.
"""
function seed_run_results!(con, seeds)
    out = NamedTuple[]
    for sd in seeds
        t0 = time()
        tgt = collect(DBInterface.execute(con,
            "SELECT column_name FROM information_schema.columns WHERE table_catalog = 'results_db' " *
            "AND table_schema = 'simulations' AND table_name = $(_pg_str(sd.table)) ORDER BY ordinal_position"))
        if isempty(tgt)
            # before the results-side DDL (ensure_run_results_tables!) is integrated, skip loudly
            isdefined(@__MODULE__, :ensure_run_results_tables!) &&
                error("seed: results_db.simulations.$(sd.table) does not exist (run the results ensure first)")
            println("  seed results_db.simulations.$(sd.table): no results table yet (ensure_run_results_tables! not in this build), skipped"); flush(stdout)
            continue
        end
        srccols = try
            _pg_columns(con, "simulations", sd.table)
        catch
            # offline proof mode: an extract carries no results tables
            _FILL_SOURCE[] === :duckdb || rethrow()
            println("  seed results_db.simulations.$(sd.table): absent in the offline source, skipped"); flush(stdout)
            continue
        end
        src = Dict(c => t for (c, t) in srccols)
        cols = [String(r.column_name) for r in tgt if haskey(src, String(r.column_name))]
        proj = join((src[c] == "timestamp with time zone" ? "\"$c\" AT TIME ZONE 'UTC' AS \"$c\"" : "\"$c\"" for c in cols), ", ")
        where = isempty(sd.where) ? "" : " WHERE $(sd.where)"
        sql = "SELECT $proj FROM simulations.$(sd.table)$where"
        clist = join(("\"$c\"" for c in cols), ", ")
        DBInterface.execute(con, "INSERT INTO results_db.simulations.$(sd.table) ($clist) SELECT * FROM $(_src_from(sql))")
        n = collect(DBInterface.execute(con, "SELECT count(*) AS n FROM results_db.simulations.$(sd.table)"))[1].n
        push!(out, (table=sd.table, rows=n, seconds=time() - t0))
        println("  seed results_db.simulations.$(sd.table): $n rows, $(round(time() - t0, digits=1)) s"); flush(stdout)
    end
    return out
end
