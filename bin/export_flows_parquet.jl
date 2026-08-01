#!/usr/bin/env julia
#
# Export per-market-day COUPLED CROSS-BORDER FLOWS for the Order-book view's
# TRADE WEDGE, from simulations.transmission_flows:
#
#   v1/flows/<market_date>.parquet   one row per solved border-hour:
#       date_time_utc TIMESTAMP, source_zone VARCHAR, sink_zone VARCHAR,
#       flow_mw DOUBLE
#
# The SPA (web/app.js) uses these to decompose a zone-hour's coupled net trade
# into per-neighbour import/export sources (the marker sits on the LOCAL supply
# curve at the COUPLED price; the gap to the local demand curve is cross-border
# trade decided by the 39-zone network — flow variables absent from the local
# ladder). The Cloudflare Worker re-emits them at /api/v1/flows/<date>.
#
# SCOPE / PHASING (measured): `simulations.transmission_flows` is persisted ONLY
# for record/backfill runs (the multi_zone_eu clear's save path). The daily
# ex-ante FORECAST (bin/daily_forecast.jl) runs with save_to_db=false and writes
# forecast_prices ONLY — it does NOT persist flows. Since the book view shows the
# freshest FORECAST days, the per-source wedge stays DORMANT there until a small
# follow-up persists forecast-run flows; this exporter already produces the files
# for any date that has flows (record/backfill days), so the data plane + route +
# SPA decomposition are ready. ADDITIVE v1: a new v1/flows/ subtree; nothing else
# changes. bin/web_data_push.sh syncs v1/flows/ additively (see that script).
#
# Per market day D (Europe/Athens, the product's market_day_tz for every zone),
# we export the UTC delivery-hour window [D-1 21:00, D 22:00) — 25 h, covering
# the Athens market day in BOTH DST offsets; the SPA matches each hour by its
# exact UTC timestamp (fday.hours[hourIdx]), so the extra hour is harmless.
# When several code_versions wrote a border-hour, the LATEST wins (DISTINCT ON).
#
# Env:
#   WEB_PARQUET_OUT   staging root (default <repo>/data/web); files land under
#                     $WEB_PARQUET_OUT/v1/flows/
#   FLOWS_START_DATE / FLOWS_END_DATE   explicit market-date range (YYYY-MM-DD);
#                     default = the recent MAX_DAYS window ending today.
#   Data store selected exactly like the rest of the library.

using Euphemia, Dates, DataFrames, DuckDB   # DuckDB re-exports DBInterface

const _FLOWS_MAX_DAYS = 120   # recent window when no explicit range given

"""
    export_flows_parquet(v1_dir; dates) -> Int

Write `<v1_dir>/flows/<D>.parquet` for each market date `D` in `dates` that has
solved flows. Returns the number of per-day files written. Self-contained
writer connection so it can be `include`d + called non-fatally from
bin/export_web_parquet.jl.
"""
function export_flows_parquet(v1_dir::AbstractString; dates::AbstractVector{Date})
    outdir = joinpath(v1_dir, "flows")
    mkpath(outdir)
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    written = 0
    try
        for D in dates
            lo = DateTime(D) - Hour(3)     # D-1 21:00 UTC
            hi = DateTime(D) + Hour(22)    # D 22:00 UTC
            df = Euphemia.sql2df_with_retry("""
                SELECT DISTINCT ON (date_time_utc, source_zone, sink_zone)
                       (date_time_utc AT TIME ZONE 'UTC') AS date_time_utc,
                       source_zone, sink_zone, flow_mw
                FROM simulations.transmission_flows
                WHERE date_time_utc >= \$1 AND date_time_utc < \$2
                ORDER BY date_time_utc, source_zone, sink_zone, code_version DESC
            """, [lo, hi])
            isempty(df) && continue
            # normalise to plain columns for the writer
            out = DataFrame(
                date_time_utc = DateTime.(df.date_time_utc),
                source_zone = String.(df.source_zone),
                sink_zone = String.(df.sink_zone),
                flow_mw = Float64.(df.flow_mw),
            )
            path = joinpath(outdir, "$(D).parquet")
            DuckDB.register_data_frame(con, out, "flows_df")
            try
                DBInterface.execute(con,
                    "COPY (SELECT * FROM flows_df) TO '$(replace(path, '\'' => "''"))' " *
                    "(FORMAT PARQUET, COMPRESSION ZSTD)")
            finally
                DBInterface.execute(con, "DROP VIEW IF EXISTS flows_df")
            end
            written += 1
        end
    finally
        DBInterface.close!(con)
    end
    println("wrote v1/flows/: $written per-day file(s) with solved flows " *
            "(of $(length(dates)) date(s) scanned)")
    return written
end

function _recent_dates()
    s = get(ENV, "FLOWS_START_DATE", "")
    e = get(ENV, "FLOWS_END_DATE", "")
    if !isempty(s) && !isempty(e)
        return collect(Date(s):Day(1):Date(e))
    end
    today = Dates.today()
    return collect((today - Day(_FLOWS_MAX_DAYS)):Day(1):today)
end

function main()
    out_root = get(ENV, "WEB_PARQUET_OUT", joinpath(dirname(@__DIR__), "data", "web"))
    v1_dir = joinpath(out_root, "v1")
    dates = _recent_dates()
    println("EXPORT FLOWS PARQUET  out=$v1_dir  dates=$(first(dates))..$(last(dates))")
    export_flows_parquet(v1_dir; dates=dates)
    println("EXPORT COMPLETE")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
