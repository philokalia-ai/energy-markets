# Incrementally refresh an EXISTING DuckDB extract in place — the "living
# extract". Opens the file read-write and appends, per table, only rows NEWER
# than the extract's current max timestamp:
#
#   - entsoe.* / yfinance.*  from ENERGY_CONN_STR (same column handling /
#     naive-UTC conversion as the builder — shared code in bin/extract_common.jl)
#   - weather.city_forecast / city_forecast_vintage  from WEATHER_CONN_STR
#     (silentech DB; skipped with a warning when WEATHER_CONN_STR is unset)
#   - weather.cell_hourly  from the PUBLIC open-meteo ERA5 archive API
#     (wind_speed_100m + shortwave_radiation, batched ≤50 cells per call, cells
#     = DISTINCT zone,lat,lon already in the table; ERA5 lags ~5 days so the
#     fetch stops at today-5 — that's fine)
#
# Small registry-like tables whose rows get UPDATED in the source (unit
# registry, outages, hydro filling rate, simulations caches, weather.city) are
# re-pulled WHOLESALE instead (their append semantics would go stale).
#
# Zones and the historical window are derived FROM THE EXTRACT ITSELF (distinct
# area_map_code in the unit registry; min energy-price date), so no build
# parameters need to be remembered. A CHECKPOINT is issued at the end and
# per-table appended-row counts are printed (and optionally written as a JSON
# manifest for CI artifacts).
#
# IMPORTANT — sorted-extract degradation: the builder materializes tables
# ORDER BY (zone, date) so DuckDB row-group zonemaps prune per-zone/per-day
# scans. Appends land after the existing rows (sorted only within each appended
# slab), so daily refreshes slowly degrade that pruning — correct results,
# gradually slower scans. Run a monthly FULL rebuild
# (bin/build_duckdb_extract.jl) to restore the global sort. Also note
# weather.city_forecast REVISIONS of already-carried future hours are upserts
# in the source and are NOT re-fetched by an append; the monthly rebuild trues
# them up (weather.city_forecast_vintage carries the issue-time snapshots).
#
# Usage:
#   EXTRACT=/opt/euphemia/extracts/euphemia-live.duckdb \
#     julia --project=. bin/refresh_duckdb_extract.jl
#
# Env:
#   EXTRACT           path to the .duckdb to refresh (required)
#   HORIZON_DAYS      how far past today to look for future-dated rows
#                     (D+1 delivery data, weather forecast horizon; default 17)
#   CELL_LAG_DAYS     ERA5 archive availability lag (default 5)
#   CELL_HOURLY_CSV   optional seed CSV if weather.cell_hourly is absent
#   MANIFEST_OUT      optional path for a JSON summary (rows/appended/max ts)
#   SKIP_CELL_HOURLY  "true" to skip the open-meteo fetch (offline runs)

# The refresher must read the LIVE Postgres, never an auto-detected extract.
haskey(ENV, "EUPHEMIA_DATA_STORE") || (ENV["EUPHEMIA_DATA_STORE"] = "postgres")

using Euphemia
using DataFrames
using Dates
using DuckDB
using Printf

include(joinpath(@__DIR__, "extract_common.jl"))
include(joinpath(@__DIR__, "weather_res.jl"))   # fetch_weather / parse / retries
QUERY_FNS[:energy] = (sql, args=Any[]) -> Euphemia.sql2df_with_retry(sql, args)
QUERY_FNS[:weather] = weather_query

const EXTRACT = get(ENV, "EXTRACT", "")
const HORIZON_DAYS = parse(Int, get(ENV, "HORIZON_DAYS", "17"))
const CELL_LAG_DAYS = parse(Int, get(ENV, "CELL_LAG_DAYS", "5"))
const CELL_HOURLY_CSV = get(ENV, "CELL_HOURLY_CSV", "")
const MANIFEST_OUT = get(ENV, "MANIFEST_OUT", "")
const SKIP_CELL_HOURLY = lowercase(get(ENV, "SKIP_CELL_HOURLY", "false")) == "true"
const CHUNK_THRESHOLD = parse(Int, get(ENV, "CHUNK_THRESHOLD", "8000000"))
const OPENMETEO_ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"

# --------------------------------------------------------------------------
# Extract-derived parameters
# --------------------------------------------------------------------------
function extract_zones(con)
    df = DataFrame(DBInterface.execute(con,
        "SELECT DISTINCT area_map_code AS z FROM entsoe.production_and_generation_units ORDER BY 1"))
    zones = String[String(z) for z in df.z if z !== missing]
    isempty(zones) && error("Could not derive zones from the extract's unit registry")
    return zones
end

# Historical window start for the wholesale-replaced tables: the earliest day
# the extract carries (energy prices start at the aux lookback), so replaces
# always yield a SUPERSET of what was there.
function extract_start_date(con)
    df = DataFrame(DBInterface.execute(con,
        "SELECT min(date_time_utc) AS m FROM entsoe.energy_prices"))
    m = df.m[1]
    return m === missing ? Dates.today() - Day(400) : Date(DateTime(m))
end

# --------------------------------------------------------------------------
# weather.cell_hourly refresh from the open-meteo ERA5 archive
# --------------------------------------------------------------------------
function refresh_cell_hourly!(con; today::Date=Dates.today())
    if !duckdb_table_exists(con, "weather", "cell_hourly")
        if !isempty(CELL_HOURLY_CSV)
            n = seed_cell_hourly!(con, CELL_HOURLY_CSV; zones=extract_zones(con))
            println("  weather.cell_hourly seeded from CSV: $n rows")
            return n
        end
        @warn "weather.cell_hourly absent and no CELL_HOURLY_CSV given — skipping " *
              "(seed it via the builder's CELL_HOURLY_CSV)"
        return 0
    end
    catalogue = DataFrame(DBInterface.execute(con,
        "SELECT DISTINCT zone, lat, lon FROM weather.cell_hourly ORDER BY zone, lat, lon"))
    wm_df = DataFrame(DBInterface.execute(con, "SELECT max(h) AS m FROM weather.cell_hourly"))
    wm = wm_df.m[1] === missing ? nothing : DateTime(wm_df.m[1])
    win = cell_fetch_window(wm, today; lag_days=CELL_LAG_DAYS)
    if win === nothing
        println("  weather.cell_hourly up to date (max h = $wm; ERA5 lag $(CELL_LAG_DAYS)d)")
        return 0
    end
    (d0, d1) = win
    uniq = unique([(Float64(r.lat), Float64(r.lon)) for r in eachrow(catalogue)])
    println("  weather.cell_hourly: fetching $(length(uniq)) cells, $d0..$d1 " *
            "($(cld(length(uniq), OPENMETEO_BATCH)) archive calls)")
    weather = fetch_weather(uniq, [d0, d1];
                            base_url=OPENMETEO_ARCHIVE_URL, models="era5")
    rows = NamedTuple[]
    for r in eachrow(catalogue)
        cw = get(weather, (Float64(r.lat), Float64(r.lon)), nothing)
        cw === nothing && continue
        for (t, (v, g)) in cw
            (wm !== nothing && t <= wm) && continue
            push!(rows, (zone=String(r.zone), lat=Float64(r.lat), lon=Float64(r.lon),
                         h=t, v100=v, ghi=g, source="era5"))
        end
    end
    isempty(rows) && return 0
    df = sort!(DataFrame(rows), [:zone, :lat, :lon, :h])
    DuckDB.register_data_frame(con, df, "_stage_cells")
    DBInterface.execute(con, "INSERT INTO weather.cell_hourly SELECT * FROM _stage_cells")
    DuckDB.unregister_data_frame(con, "_stage_cells")
    return nrow(df)
end

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
json_str(s) = '"' * replace(String(s), "\\" => "\\\\", "\"" => "\\\"") * '"'

function main()
    t0 = time()
    isempty(EXTRACT) && (println("ERROR: set EXTRACT=/path/to/extract.duckdb"); return 1)
    isfile(EXTRACT) || (println("ERROR: extract not found: $EXTRACT"); return 1)

    today = Dates.today()
    db = DuckDB.DB(EXTRACT)   # read-write
    con = DBInterface.connect(db)

    zones = extract_zones(con)
    start_date = extract_start_date(con)
    have_weather = haskey(ENV, "WEATHER_CONN_STR")
    println("Refreshing extract: ", EXTRACT)
    println("  zones      : ", length(zones), "  (", join(zones, ","), ")")
    println("  window     : ", start_date, " .. ", today, " (+$(HORIZON_DAYS)d horizon)")
    println("  weather DB : ", have_weather ? "yes" : "NO (WEATHER_CONN_STR unset — weather.* skipped)")
    println()

    specs = entsoe_table_specs(zones; start_date=start_date, end_date=today + Day(7))
    append!(specs, yfinance_table_specs())
    append!(specs, simulations_table_specs(zones))
    have_weather && append!(specs, weather_table_specs(today=today))

    summary = NamedTuple[]
    for spec in specs
        fqtn = "$(spec.schema).$(spec.table)"
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS $(spec.schema)")
        exists = duckdb_table_exists(con, spec.schema, spec.table)
        appended = 0
        action = ""
        if spec.refresh == :append && exists
            appended = append_incremental!(con, spec; today=today, horizon_days=HORIZON_DAYS)
            action = "append"
        elseif spec.refresh == :append   # bootstrap a table this extract never had
            appended = build_table!(con, spec; chunk_threshold=CHUNK_THRESHOLD)
            action = "bootstrap"
        else                              # :replace — mutable registry-like table
            before = exists ? duckdb_rowcount(con, spec) : 0
            n = build_table!(con, spec; chunk_threshold=CHUNK_THRESHOLD, replace=true)
            appended = n - before
            action = "replace"
        end
        rows = duckdb_rowcount(con, spec)
        maxts = isempty(spec.ts_col) ? nothing : duckdb_max_ts(con, spec)
        @printf("  %-55s %-9s %+9d rows  (total %10d%s)\n", fqtn, action, appended, rows,
                maxts === nothing ? "" : ", max $(maxts)")
        flush(stdout)
        push!(summary, (name=fqtn, action=action, appended=appended, rows=rows,
                        max_ts=maxts === nothing ? nothing : string(maxts)))
    end

    # weather.cell_hourly from the public open-meteo ERA5 archive
    if SKIP_CELL_HOURLY
        println("  weather.cell_hourly: skipped (SKIP_CELL_HOURLY=true)")
    else
        n = refresh_cell_hourly!(con; today=today)
        if duckdb_table_exists(con, "weather", "cell_hourly")
            df = DataFrame(DBInterface.execute(con,
                "SELECT count(*) AS c, max(h) AS m FROM weather.cell_hourly"))
            @printf("  %-55s %-9s %+9d rows  (total %10d, max %s)\n",
                    "weather.cell_hourly", "append", n, Int(df.c[1]), df.m[1])
            push!(summary, (name="weather.cell_hourly", action="append", appended=n,
                            rows=Int(df.c[1]), max_ts=string(df.m[1])))
        end
    end

    DBInterface.execute(con, "CHECKPOINT")
    DBInterface.close!(con)
    close(db)
    close_weather_connection!()

    total_appended = sum(t.appended for t in summary)
    println()
    @printf("Refresh done in %.0f s: %+d rows across %d tables.\n",
            time() - t0, total_appended, length(summary))
    println("NOTE: appends degrade the sorted extract's zonemap pruning over time —")
    println("      schedule a monthly full rebuild (bin/build_duckdb_extract.jl).")

    if !isempty(MANIFEST_OUT)
        io = IOBuffer()
        println(io, "{")
        println(io, "  \"extract\": ", json_str(EXTRACT), ",")
        println(io, "  \"refreshed_at_utc\": ", json_str(string(now(UTC))), ",")
        println(io, "  \"tables\": [")
        for (i, t) in enumerate(summary)
            comma = i == length(summary) ? "" : ","
            mts = t.max_ts === nothing ? "null" : json_str(t.max_ts)
            println(io, "    {\"name\": ", json_str(t.name),
                    ", \"action\": ", json_str(t.action),
                    ", \"appended\": ", t.appended,
                    ", \"rows\": ", t.rows,
                    ", \"max_ts\": ", mts, "}", comma)
        end
        println(io, "  ]")
        println(io, "}")
        write(MANIFEST_OUT, take!(io))
        println("Wrote manifest to ", MANIFEST_OUT)
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
