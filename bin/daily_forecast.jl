#!/usr/bin/env julia
#
# Daily ex-ante price forecast (invoked by .github/workflows/daily-forecast.yml).
#
# Discovers not-yet-realized EUROPE/ATHENS MARKET DAYS with complete input
# data, produces the full local delivery day and writes hourly price
# predictions to simulations.forecast_prices stamped with prediction_made_utc
# and lead_days, so accuracy can later be tracked honestly per region and per
# lead time (bin/score_forecasts.jl).
#
# MARKET-DAY WINDOW: ENTSO-E publishes day-ahead data per LOCAL market day.
# The forecast delivery day is the Europe/Athens market day D =
# [athens_day_start_utc(D), athens_day_start_utc(D+1)) — 21:00 UTC (D-1) →
# 21:00 UTC (D) under EEST, 22:00 UTC under EET (DST-aware; 23/25-hour days at
# the transitions). At the D-1 evening run this window is fully published for
# all footprint zones, whereas the UTC calendar day D is missing its local
# tail. The window is produced with the existing UTC-day machinery by clearing
# TWO UTC days and stitching (ex-ante :v2 flows are the cv16 default on this
# path — never overridden here):
#   - UTC day D-1 (fully published) → keep only hours ≥ athens_day_start_utc(D)
#   - UTC day D (unpublished tail auto-dropped by the coupled-grid
#     intersection trim, PR #117) → keep hours < athens_day_start_utc(D+1)
# Cost: 2 coupled solves per market day (UTC-day clears are cached within a
# run, so N consecutive market days cost N+1 solves).
#
# HONESTY GUARANTEES:
# - A day is only predicted if it is strictly beyond the realized-data horizon
#   (MAX date of entsoe.actual_total_load). Writing a "prediction" for a
#   realized day is refused with an error (assert_unrealized).
# - HOUR-LEVEL GUARD: every written row's date_time_utc must be strictly after
#   prediction_made_utc (assert_hours_unrealized) — both solves at the evening
#   run are ex-ante, every stitched hour is in the future.
# - A zone-day is only written when the stitched window is COMPLETE (exactly
#   the expected 24 hours — 23/25 on DST-transition days); missing hours are
#   logged and the zone-day is skipped. Never publish a partial market day.
# - The eligibility gate never degrades: if ANY footprint zone is missing its
#   day-ahead load forecast (≥20 hourly rows in the window), or a zone that had
#   a wind/solar forecast on the last realized day is missing one, or the
#   window has no offered ATC rows, the day is skipped loudly (verdict + reason
#   logged per day).
#
# INPUT TRACKS (INPUT_MODE):
# - 'entsoe' (default, the REFERENCE track): ENTSO-E D-1 load + wind/solar
#   forecasts, exactly as before. Freezes in the evening — before delivery,
#   but after the 12:00 CET auction. PURE by default: the opportunistic
#   eligibility fills (LOAD_FILL/RES_FILL) are RETIRED as defaults — which
#   slices they filled depended on ETL arrival timing at run moment, so two
#   runs minutes apart could differ in provenance composition. A short zone
#   now honestly skips the day (a later scheduled attempt retries); rows are
#   stamped plain 'entsoe', never '+loadfill/+resfill' unless the fills are
#   explicitly re-enabled for an experiment.
# - 'weather' (the EX-ANTE track): ALL model inputs, uniformly — wind/solar
#   predicted from RAW open-meteo weather via bin/weather_res.jl AND load
#   predicted from the committed load models (bin/weather_load.jl) for EVERY
#   zone, so the prediction can be frozen BEFORE the auction gate with a
#   composition that never depends on which TSOs happened to publish early.
#   The ENTSO-E RES eligibility requirement is REMOVED and the LOAD gate is
#   replaced by MODEL coverage (a zone the load model cannot cover keeps the
#   day ineligible — no silent TSO mixing); the ATC gate stays as-is. Book
#   construction OVERRIDES whatever ENTSO-E RES exists to the weather-RES
#   prediction on every timeslot (renewable_modifier — same mechanism the
#   entsoe track's real RES forecast uses, so it propagates into net demand,
#   the scarcity margin and the peak-hour shape, not just the raw supply
#   curve) and fills any hour the TSO published nothing for (res_fill hook,
#   the RES twin of load_fill below) so the override always has an entry to
#   reshape; load is overridden the same way (load_modifier + load_fill) —
#   every hour of every track input is model-sourced. (Fixed 2026-08:
#   RES used to be zeroed via renewable_modifier and re-injected as a
#   separate extra_orders supply block, which bypassed net demand entirely —
#   see docs/experiments/weather-track-hook-fix.md.)
#   Rows are stamped input_mode='weather' (never suffixed — model load is the
#   track's core, not a fill); the slice identity is
#   (market_date, lead_days, input_mode) so the two tracks NEVER overwrite
#   each other. code_version is per-row PROVENANCE, not part of the slice
#   identity: the no-clobber guard and the slice delete are CV-AGNOSTIC (a
#   slice frozen under an earlier code_version is never rewritten by a later
#   one — vintages are immutable across model upgrades), while writes stamp
#   the current code_version.
#
# Env vars:
#   OPTIMIZER      'highs' (default, production since cv20) / 'gurobi'
#                  (development, academic licence) / 'auto'
#   INPUT_MODE     'entsoe' (default) / 'weather' — see INPUT TRACKS above
#   MAX_LEAD_DAYS  furthest lead to attempt, default 7
#   FORCE_RERUN    'true' to rewrite an existing (market_date, lead, mode)
#                  slice — at ANY code_version (vintages are otherwise immutable)
#   ZONES          comma-separated footprint override (FOR TESTING ONLY, e.g.
#                  a 5-zone footprint when the Gurobi license is unavailable);
#                  default = the 39-zone EU footprint
#   CLEARING_MODE  label stored on forecast rows (default 'multi_zone_eu')
#   SKIP_CLEAR     'true' = run discovery + eligibility logging only, never
#                  solve (debugging escape hatch; since cv20 the clear runs
#                  in decomposed mode, which HiGHS solves — no Gurobi needed)

using Euphemia, Dates, Statistics, LibPQ, DataFrames, DuckDB

include(joinpath(@__DIR__, "forecast_common.jl"))
include(joinpath(@__DIR__, "weather_res.jl"))    # guarded main; pure helpers + open-meteo fetch
include(joinpath(@__DIR__, "weather_load.jl"))   # guarded main; load model (features + fetch + predict)

const OPTIMIZER = get(ENV, "OPTIMIZER", "highs")
const INPUT_MODE = let m = lowercase(get(ENV, "INPUT_MODE", "entsoe"))
    m in ("entsoe", "weather") ||
        error("INPUT_MODE must be 'entsoe' or 'weather' (got '$m')")
    m
end
const MAX_LEAD_DAYS = parse(Int, get(ENV, "MAX_LEAD_DAYS", "7"))
const FORCE_RERUN = lowercase(get(ENV, "FORCE_RERUN", "false")) == "true"
const SKIP_CLEAR = lowercase(get(ENV, "SKIP_CLEAR", "false")) == "true"
# Per-zone eligibility fill on the entsoe track: when a zone's ENTSO-E 6.1.B
# day-ahead load is missing/short for the window, predict its hourly load with
# the committed model (bin/weather_load.jl + bin/load_models_v1.json) so the day
# stays eligible. RETIRED as a default (July 2026): whether a slice got filled
# depended on ETL arrival timing at run moment, so the reference track's
# provenance composition was run-time-dependent. Default OFF — a short load zone
# skips the whole day (honest absence; a later scheduled attempt retries).
# LOAD_FILL=true re-enables it for experiments (rows then carry the
# '+loadfill' provenance suffix as before). The weather track does NOT use this
# flag — model load is that track's core input, always on, for every zone.
const LOAD_FILL = lowercase(get(ENV, "LOAD_FILL", "false")) == "true"
# RES twin of LOAD_FILL, same retirement: default OFF; RES_FILL=true re-enables
# ('+resfill' suffix). Inert on the weather track (all RES from weather there).
const RES_FILL = lowercase(get(ENV, "RES_FILL", "false")) == "true"
# Inter-zone throttle for the per-zone open-meteo fetches (load fill, RES fill,
# weather track). On the entsoe track a run fires up to 39 load-fill + 39 RES-fill
# fetches back-to-back against the PUBLIC open-meteo API, which then returns 429
# (Too Many Requests) mid-burst — that is exactly what refused FI/PT on 2026-07-26
# and made the day INELIGIBLE. Spacing the calls keeps the rate under the API's
# per-minute window; the 429-aware retry in weather_res/weather_load is the
# backstop. Set 0 to disable (e.g. against a self-hosted instance).
const OPENMETEO_ZONE_THROTTLE_S = parse(Float64, get(ENV, "EUPHEMIA_OPENMETEO_ZONE_THROTTLE", "0.6"))
const CLEARING_MODE = get(ENV, "CLEARING_MODE", "multi_zone_eu")
const ZONES = let z = [String(strip(s)) for s in split(get(ENV, "ZONES", ""), ",") if !isempty(strip(s))]
    isempty(z) ? FORECAST_FOOTPRINT : z
end
const CV = Euphemia.ENERGY_PRICES_CODE_VERSION

"Latest fully-realized market day (MAX UTC date of entsoe.actual_total_load)."
function latest_actual_load_date()
    df = Euphemia.sql2df_with_retry(
        "SELECT MAX((date_time_utc AT TIME ZONE 'UTC')::date) AS d FROM entsoe.actual_total_load")
    (isempty(df) || ismissing(df.d[1])) && error("entsoe.actual_total_load is empty — cannot establish the realized-data horizon")
    return Date(df.d[1])
end

"Zone → number of distinct forecast hours in day_ahead_total_load_forecast in [t0, t1)."
function load_forecast_hours(t0::DateTime, t1::DateTime, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS z,
               COUNT(DISTINCT date_trunc('hour', date_time_utc)) AS nh
        FROM entsoe.day_ahead_total_load_forecast
        WHERE date_time_utc >= (\$1::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = ANY(\$3)
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
        GROUP BY 1
    """, [t0, t1, zones])
    return Dict{String,Int}(String(r.z) => Int(r.nh) for r in eachrow(df))
end

"""
Set of zones whose day-ahead wind/solar forecast COVERS the window (≥20 of its
hours with non-null values, same bar as the load gate). Mere EXISTS is not
enough: on 2026-07-12 an early run saw a few DE_LU rows, passed the gate, and
froze a 07-13 forecast with most of Germany's solar missing — the model priced
a midday peak where reality had the solar valley (corr −0.50). Partial
publications must read as "not yet published".
"""
function res_forecast_zones(t0::DateTime, t1::DateTime, zones::Vector{String};
                            min_hours::Int=20)
    df = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS z,
               COUNT(DISTINCT date_trunc('hour', date_time_utc)) AS nh
        FROM entsoe.generation_forecasts_for_wind_and_solar
        WHERE date_time_utc >= (\$1::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = ANY(\$3)
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
          AND day_ahead_generation_forecast_mw IS NOT NULL
        GROUP BY 1
    """, [t0, t1, zones])
    return Set{String}(String(r.z) for r in eachrow(df) if Int(r.nh) >= min_hours)
end

"Count of offered implicit-ATC rows touching the footprint in [t0, t1).
Counts Day-ahead rows only (falling back to any row when no Day-ahead exists in
the window, e.g. a fully-FBMC future): with the cv26 Day-ahead preference, a
window where only Intraday rows have landed would otherwise pass the gate and
freeze a slice cleared on fallback capacity hours before the DA rows arrive."
function atc_row_count(t0::DateTime, t1::DateTime, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT COUNT(*) FILTER (WHERE contract_type = 'Day-ahead') AS n_da,
               COUNT(*) AS n
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE date_time_utc >= (\$1::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::timestamp AT TIME ZONE 'UTC')
          AND (out_map_code = ANY(\$3) OR in_map_code = ANY(\$3))
    """, [t0, t1, zones])
    n_da = Int(df.n_da[1])
    return n_da > 0 ? n_da : Int(df.n[1])
end

"""
Zones already present in the (market_date, lead_days, input_mode) slice — at
ANY code_version (cv-agnostic no-clobber: a slice frozen under an earlier
code_version must never be rewritten by a later one).
"""
function existing_forecast_zones(market_date::Date, lead_days::Int,
                                 input_mode::String=INPUT_MODE)
    df = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT bidding_zone AS z FROM simulations.forecast_prices
        WHERE market_date = \$1 AND lead_days = \$2 AND input_mode = \$3
    """, [market_date, lead_days, input_mode])
    return Set{String}(String.(df.z))
end

"""
Write the books captured for ONE market day to v1/books/<market_date>.parquet
(zstd) and push.

An Athens market day is produced by clearing two UTC days (D-1 and D), so only
those two keys belong in the file. The accumulator is never emptied between
market days (UTC day D's book is reused from cache by market day D+1, so the
sink does not re-fire for it), which is why the filter lives here: flushing the
whole accumulator wrote every previously-cleared UTC day into each per-day
parquet, stamped with the WRONG market_date and growing quadratically over a
run.
"""
function flush_books!(books::Dict, market_date::Date)
    rows = NamedTuple[]
    wanted = (market_date - Day(1), market_date)
    for ((zone, day), tagged) in books
        day in wanted || continue
        for (o, tag) in tagged
            push!(rows, (market_date=market_date, zone=zone, ts=o.date_time,
                         side=String(o.type), price=o.price, mw=o.quantity,
                         owner=tag,
                         code_version=Euphemia.ENERGY_PRICES_CODE_VERSION))
        end
    end
    isempty(rows) && return nothing
    outdir = joinpath(dirname(@__DIR__), "data", "web", "v1", "books")
    mkpath(outdir)
    out = joinpath(outdir, "$(market_date).parquet")
    df = DataFrame(rows)
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    DuckDB.register_data_frame(con, df, "books")
    DBInterface.execute(con,
        "COPY (SELECT * FROM books ORDER BY zone, ts, side, price) TO '$(out)' " *
        "(FORMAT parquet, COMPRESSION zstd)")
    DBInterface.close!(con)
    println("📚 books: wrote $(nrow(df)) orders -> $(out) ($(round(filesize(out)/1024, digits=0)) KB)")
    endpoint = get(ENV, "EXTRACT_S3_ENDPOINT", "")
    bucket = get(ENV, "EXTRACT_S3_BUCKET", "")
    if !isempty(endpoint) && !isempty(bucket)
        try
            run(`aws s3 cp --endpoint-url $(endpoint) $(out) s3://$(bucket)/books/$(market_date).parquet`)
            println("📚 books: pushed to s3://…/books/$(market_date).parquet")
        catch e
            @warn "books push failed (parquet kept locally)" error = sprint(showerror, e)
        end
    end
    empty!(books)
    return nothing
end

"""
Delete-then-insert exactly the (market_date, lead_days, input_mode) slice in
one transaction — the reference ('entsoe') and ex-ante ('weather') tracks
never overwrite each other. The DELETE is CV-AGNOSTIC (it clears the slice at
any code_version, so a rewrite can never leave a cross-version duplicate
pair); the INSERT stamps the current code_version as provenance.
`zone_hourly` is zone → (hour::DateTime → price), already
stitched and completeness-checked per zone (every zone here has exactly the
expected market-day hours). The realized guard is re-checked immediately
before the write (the horizon may have advanced during a long solve), and the
HOUR-LEVEL guard refuses any row at or before `prediction_made`.
"""
function write_forecast!(market_date::Date, lead_days::Int, prediction_made::DateTime,
                         zone_hourly::Dict{String,Dict{DateTime,Float64}},
                         input_mode::String=INPUT_MODE)
    latest_actual = latest_actual_load_date()
    assert_unrealized(market_date, latest_actual)   # HARD GUARD (day level)
    for (_, hourly) in zone_hourly                  # HARD GUARD (hour level)
        assert_hours_unrealized(keys(hourly), prediction_made)
    end

    # Explicit UTC offsets so timestamptz values are unambiguous regardless of
    # the session timezone.
    tstz(dt::DateTime) = Dates.format(dt, "yyyy-mm-dd HH:MM:SS") * "+00"

    n_inserted = 0
    Euphemia.withdb() do cnx
        LibPQ.execute(cnx, "BEGIN")
        try
            LibPQ.execute(cnx, """
                DELETE FROM simulations.forecast_prices
                WHERE market_date = \$1 AND lead_days = \$2 AND input_mode = \$3
            """, [market_date, lead_days, input_mode])
            for (zone, hourly) in zone_hourly
                for (h, price) in sort!(collect(hourly); by=first)
                    LibPQ.execute(cnx, """
                        INSERT INTO simulations.forecast_prices
                        (market_date, date_time_utc, bidding_zone, price_eur_mwh,
                         prediction_made_utc, lead_days, clearing_mode, code_version,
                         input_mode)
                        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9)
                    """, Any[market_date, tstz(h), zone, price,
                             tstz(prediction_made), lead_days, CLEARING_MODE, CV,
                             input_mode])
                    n_inserted += 1
                end
            end
            LibPQ.execute(cnx, "COMMIT")
        catch e
            LibPQ.execute(cnx, "ROLLBACK")
            rethrow(e)
        end
    end
    return n_inserted
end

"""
Per-zone hourly weather-RES predictions (MW) covering UTC days
`first_utc_day`..`last_utc_day` (the ex-ante track's wind+solar inputs).
Fetches are grouped by admissible vintage (`vintage_groups` over the candidate
market days): on the normal D-1 morning run that is ONE span fetch per zone
exactly as before; a late/catch-up run splits so each market day's inputs come
from the run issued on ITS D-1 (previous-runs API), never a fresher one.
Zones without a model in the pack predict 0 for all hours (warned).
"""
function build_weather_predictions(first_utc_day::Date, last_utc_day::Date,
                                   candidates::AbstractSet{Date};
                                   asof::Date=Date(now(UTC)))
    pack = load_res_models()
    groups = vintage_groups(first_utc_day, last_utc_day, candidates; asof)
    preds = Dict{String,Dict{DateTime,Float64}}()
    for zone in ZONES
        zm = get(pack["zones"], zone, nothing)
        if zm === nothing
            println("  ⚠️ $zone: no RES model in pack — weather RES predicted 0")
            preds[zone] = Dict{DateTime,Float64}()
            continue
        end
        cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cells"]]
        zp = Dict{DateTime,Float64}()
        for (gdates, lag) in groups
            OPENMETEO_ZONE_THROTTLE_S > 0 && sleep(OPENMETEO_ZONE_THROTTLE_S)  # spread calls → avoid 429
            weather = fetch_weather(cells, gdates; vintage_lag=lag)
            ghours = collect(DateTime(first(gdates)):Hour(1):DateTime(last(gdates)) + Hour(23))
            merge!(zp, predict_res(pack, zone, ghours, weather))
        end
        nspan = 24 * (Dates.value(last_utc_day - first_utc_day) + 1)
        0 < length(zp) < nspan &&
            println("  ⚠️ $zone: weather RES covers $(length(zp))/$(nspan) span hours " *
                    "(previous-runs nulls / weather gaps) — short market days go ineligible")
        preds[zone] = zp
    end
    return preds
end

"""
Per-zone `ZoneScenario` dict for the weather track: OVERRIDE whatever ENTSO-E
RES exists to the weather-RES prediction for its hour (`renewable_modifier` —
sub-hourly slots use the hour's predicted MW as the LEVEL, no division). This
is the SAME hook the entsoe track's real RES forecast flows through implicitly
(it is simply never modified there), so the weather prediction now propagates
everywhere RES is supposed to: the merit-order RES supply order (Stage 6 of
book_build.jl, tagged "RES" — no separate "EXTRA" provenance any more), net
demand, the scarcity margin and the peak-hour shape term (Stage 3). Previously
RES was ZEROED via `renewable_modifier -> 0` and re-injected as a separate
`extra_orders` price-taker supply block — that bypassed net demand/scarcity/
peak-shape entirely, so a zone's day-shape was computed off gross LOAD alone,
blind to its own predicted solar/wind. Fixed 2026-08 — see
docs/experiments/weather-track-hook-fix.md for the diagnosis and the
zone-day A/B (PL was the worst-hit: forecast sd collapsed to ~0.1 €/MWh).

`renewable_modifier` only RESHAPES existing `renewable_by_time` entries (it
cannot add an hour that has no key at all), so `res_fill` — the RES twin of
`load_fill` below, built the same way over the SAME `preds` dict — guarantees
every UTC hour has an entry for the modifier to override, even where ENTSO-E
published nothing for that zone/hour. This mirrors the LOAD side exactly:
`load_preds` (zone → hour → MW) OVERRIDES every load timeslot via
`load_modifier` (sub-hourly slots use the hour's MW as the LEVEL) with
`load_fill` covering hours the TSO did not publish. Together every hour of
every zone is model-sourced RES + load, so the vintage's composition never
depends on which TSOs happened to publish before the run. Eligibility
(model_covered_for_day / res_covered_for_day) guarantees full coverage on
eligible days; the `mw` fallback in both modifiers is therefore unreachable
there and kept only as a safe identity.
"""
function weather_scenario(preds::Dict{String,Dict{DateTime,Float64}},
                          load_preds::Dict{String,Dict{DateTime,Float64}})
    scenario = Dict{String,Euphemia.ZoneScenario}()
    load_fill_fn = make_load_fill_fn(load_preds)
    res_fill_fn = make_res_fill_fn(preds)
    for zone in ZONES
        zone_pred = get(preds, zone, Dict{DateTime,Float64}())
        zone_load = get(load_preds, zone, Dict{DateTime,Float64}())
        rmod = (ts, mw) -> begin
            dt = DateTime(ts, dateformat"yyyymmdd-HHMM")
            get(zone_pred, trunc(dt, Hour), mw)
        end
        lmod = (ts, mw) -> begin
            dt = DateTime(ts, dateformat"yyyymmdd-HHMM")
            get(zone_load, trunc(dt, Hour), mw)
        end
        # RES and load are both fully weather/model-sourced (override + fill),
        # so the entsoe-track eligibility-gap fill semantics (merge, never
        # replace a published TSO hour) never matter here — the modifier
        # overrides every hour regardless of provenance.
        scenario[zone] = Euphemia.ZoneScenario(load_modifier=lmod,
                                               renewable_modifier=rmod,
                                               load_fill=load_fill_fn,
                                               res_fill=res_fill_fn)
    end
    return scenario
end

"""
Zones whose model-load prediction (`load_preds`) covers EVERY expected hour of
`day`'s Athens market window — the weather track's load-eligibility set (the
TSO-load gate is replaced by model coverage there).
"""
function model_covered_for_day(day::Date,
                               load_preds::Dict{String,Dict{DateTime,Float64}})
    expected = expected_market_day_hours(day)
    return Set(z for (z, zp) in load_preds if all(h -> haskey(zp, h), expected))
end

"""
Zones whose weather-RES prediction covers EVERY expected hour of `day`'s Athens
market window — the RES twin of `model_covered_for_day`.

Without this gate the weather track applied the "partial publications must read
as not-yet-published" rule (see `res_forecast_zones`) to the TSO's RES but NOT
to its own: `weather_scenario` zeroes the ENTSO-E renewable forecast and injects
`get(zone_pred, hour, 0.0)`, so an hour the model could not predict — a zone
absent from the RES pack, an open-meteo gap, a short fetch — silently clears
with ZERO wind+solar. That is the 2026-07-12 failure mode (a day frozen with
most of Germany's solar missing, corr −0.50) reintroduced from the model side,
and forecast vintages are immutable, so it can never be corrected afterwards.
"""
function res_covered_for_day(day::Date,
                             res_preds::Dict{String,Dict{DateTime,Float64}})
    expected = expected_market_day_hours(day)
    return Set(z for (z, zp) in res_preds if all(h -> haskey(zp, h), expected))
end

# ---------------------------------------------------------------------------
# Per-zone eligibility LOAD FILL (bin/weather_load.jl).
#
# When a zone's ENTSO-E day-ahead load is missing/short for a candidate market
# day, predict its hourly load from the committed model so the day stays
# eligible. The prediction covers the whole candidate UTC span; the
# `load_fill` book hook (src/merit_order/book_build.jl) MERGES it into each
# zone's load, filling ONLY the hours the TSO did not publish — a present TSO
# hour is never overridden. Zones with a full TSO forecast are never predicted,
# so their books are byte-identical to a no-fill run.
# ---------------------------------------------------------------------------

"""
Predict hourly load (MW) for each `zones_to_fill` zone over UTC days
`first_utc`..`last_utc`, using the load-model `pack` and open-meteo forecast
weather (each vintage group's fetch reaches 2 days further back for the
trailing-48h feature, at the group's own lag — vintage-coherent inputs).
Fetches group by admissible vintage over the candidate market days (see
`vintage_groups`; one span fetch on the normal run). Returns
`zone => (hour::DateTime → MW)`; a zone is omitted if it has no pack entry or no
weather could be fetched (the caller then keeps that zone's day INELIGIBLE —
never a silent flat/persistence fallback).
"""
function build_load_fills(pack, zones_to_fill::Vector{String},
                          first_utc::Date, last_utc::Date,
                          candidates::AbstractSet{Date};
                          asof::Date=Date(now(UTC)))
    fill_pred = Dict{String,Dict{DateTime,Float64}}()
    isempty(zones_to_fill) && return fill_pred
    groups = vintage_groups(first_utc, last_utc, candidates; asof)
    for zone in zones_to_fill
        zm = get(pack["zones"], zone, nothing)
        if zm === nothing
            println("  ⚠️ load-fill: $zone has no model in the pack — cannot fill (day stays ineligible)")
            continue
        end
        cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cities"]]
        pred = Dict{DateTime,Float64}()
        ok = true
        for (gdates, lag) in groups
            OPENMETEO_ZONE_THROTTLE_S > 0 && sleep(OPENMETEO_ZONE_THROTTLE_S)  # spread calls → avoid 429
            weather = try
                fetch_load_weather(cells, collect((first(gdates) - Day(2)):Day(1):last(gdates));
                                   vintage_lag=lag)
            catch e
                e isa InterruptException && rethrow()
                println("  ⚠️ load-fill: $zone weather fetch failed ($(sprint(showerror, e))) — cannot fill")
                ok = false
                break
            end
            ghours = collect(DateTime(first(gdates)):Hour(1):DateTime(last(gdates)) + Hour(23))
            merge!(pred, predict_load(pack, zone, ghours, weather))
        end
        ok || continue
        if isempty(pred)
            println("  ⚠️ load-fill: $zone produced no hours (weather gaps) — cannot fill")
            continue
        end
        nspan = 24 * (Dates.value(last_utc - first_utc) + 1)
        length(pred) < nspan &&
            println("  ⚠️ load-fill: $zone covers $(length(pred))/$(nspan) span hours " *
                    "(weather gaps) — short market days stay ineligible")
        fill_pred[zone] = pred
        println("  🩹 load-fill: $zone model load ready ($(length(pred))h over " *
                "$(first_utc)..$(last_utc))")
    end
    return fill_pred
end

"""
Book hook `load_fill(zone, utc_day) -> Union{Nothing,Dict{String,Float64}}` over a
precomputed `fill_pred` (zone → hour → MW). Returns the UTC day's timeslot→MW
slice for a predicted zone, or `nothing` (no fill) for any other zone/day. Stable
and order-independent, so the shared UTC-day clear cache is never contaminated.
"""
function make_load_fill_fn(fill_pred::Dict{String,Dict{DateTime,Float64}})
    isempty(fill_pred) && return nothing
    return (zone, day) -> begin
        zp = get(fill_pred, String(zone), nothing)
        zp === nothing && return nothing
        slots = Dict{String,Float64}()
        for t in DateTime(day):Hour(1):(DateTime(day) + Hour(23))
            mw = get(zp, t, nothing)
            mw === nothing && continue
            slots[Dates.format(t, "yyyymmdd-HHMM")] = mw
        end
        isempty(slots) ? nothing : slots
    end
end

"""
Zones short (< `min_hours` TSO load hours) on this market day's window that the
fill CAN cover (`fill_pred` has the zone and it spans every expected window
hour). These are exactly the zones exempted in the eligibility gate and merged
in the clear; a short zone the model cannot cover is NOT returned (day stays
ineligible).
"""
function fillable_for_day(day::Date, load_hours::Dict{String,Int},
                          fill_pred::Dict{String,Dict{DateTime,Float64}};
                          min_hours::Int=20)
    expected = expected_market_day_hours(day)
    out = Set{String}()
    for zone in ZONES
        get(load_hours, zone, 0) < min_hours || continue
        zp = get(fill_pred, zone, nothing)
        zp === nothing && continue
        all(h -> haskey(zp, h), expected) && push!(out, zone)
    end
    return out
end

# ---------------------------------------------------------------------------
# Per-zone RES eligibility fill (bin/weather_res.jl) — the twin of load fill.
#
# When a zone's ENTSO-E 14.1.D wind/solar forecast is missing/short, predict its
# hourly wind+solar MW from the committed weather→RES pack. The `res_fill` book
# hook MERGES it into the zone's renewable forecast, filling ONLY the hours the
# TSO did not publish (present TSO RES never overridden). A zone absent from the
# RES pack cannot be filled (day stays ineligible); a pack zone lacking a
# wind/solar sub-model predicts that component as 0 (physically negligible — fine
# per the pack design). Inert on the weather track (no RES gate there).
# ---------------------------------------------------------------------------

"""
Predict hourly wind+solar (MW) for each `zones_to_fill` zone over UTC days
`first_utc`..`last_utc` from the weather→RES `pack` (bin/weather_res.jl). Returns
`zone => (hour::DateTime → MW)`; a zone is omitted if it has no pack entry or no
weather could be fetched (the caller then keeps that zone's day INELIGIBLE — no
silent fallback). Mirrors `build_load_fills`.
"""
function build_res_fills(pack, zones_to_fill::Vector{String},
                         first_utc::Date, last_utc::Date,
                         candidates::AbstractSet{Date};
                         asof::Date=Date(now(UTC)))
    res_pred = Dict{String,Dict{DateTime,Float64}}()
    isempty(zones_to_fill) && return res_pred
    groups = vintage_groups(first_utc, last_utc, candidates; asof)
    for zone in zones_to_fill
        zm = get(pack["zones"], zone, nothing)
        if zm === nothing
            println("  ⚠️ res-fill: $zone has no model in the RES pack — cannot fill (day stays ineligible)")
            continue
        end
        cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cells"]]
        pred = Dict{DateTime,Float64}()
        ok = true
        for (gdates, lag) in groups
            OPENMETEO_ZONE_THROTTLE_S > 0 && sleep(OPENMETEO_ZONE_THROTTLE_S)  # spread calls → avoid 429
            weather = try
                fetch_weather(cells, gdates; vintage_lag=lag)
            catch e
                e isa InterruptException && rethrow()
                println("  ⚠️ res-fill: $zone weather fetch failed ($(sprint(showerror, e))) — cannot fill")
                ok = false
                break
            end
            ghours = collect(DateTime(first(gdates)):Hour(1):DateTime(last(gdates)) + Hour(23))
            merge!(pred, predict_res(pack, zone, ghours, weather))
        end
        ok || continue
        if isempty(pred)
            println("  ⚠️ res-fill: $zone produced no hours (weather gaps) — cannot fill")
            continue
        end
        nspan = 24 * (Dates.value(last_utc - first_utc) + 1)
        length(pred) < nspan &&
            println("  ⚠️ res-fill: $zone covers $(length(pred))/$(nspan) span hours " *
                    "(weather gaps) — short market days stay ineligible")
        res_pred[zone] = pred
        println("  🩹 res-fill: $zone model wind+solar ready ($(length(pred))h over " *
                "$(first_utc)..$(last_utc))")
    end
    return res_pred
end

"Book hook `res_fill(zone, utc_day)` over a precomputed `res_pred`. Twin of `make_load_fill_fn`."
make_res_fill_fn(res_pred::Dict{String,Dict{DateTime,Float64}}) = make_load_fill_fn(res_pred)

"""
Zones REQUIRED to have a wind/solar forecast (had one on the last realized day)
but MISSING it this market day, that the RES model CAN cover (`res_pred` has the
zone spanning every expected window hour). Exactly the zones exempted in the RES
eligibility gate and merged in the clear; a zone the model cannot cover is NOT
returned (day stays ineligible). Twin of `fillable_for_day`.
"""
function res_fillable_for_day(day::Date, res_required::AbstractSet{String},
                              res_present::AbstractSet{String},
                              res_pred::Dict{String,Dict{DateTime,Float64}})
    expected = expected_market_day_hours(day)
    out = Set{String}()
    for zone in setdiff(res_required, res_present)
        zp = get(res_pred, zone, nothing)
        zp === nothing && continue
        all(h -> haskey(zp, h), expected) && push!(out, zone)
    end
    return out
end

"""
Clear one UTC calendar day with the standard 39-zone machinery and collapse to
zone → (hour → price). Returns `nothing` on failure. Results are memoized in
`cache` so consecutive market days share their overlapping UTC-day solve.
In weather mode, `scenario` carries the per-zone RES replacement (ENTSO-E RES
zeroed, weather-RES injected as price-taker supply).
"""
function clear_utc_day!(cache::Dict{Date,Union{Nothing,Dict{String,Dict{DateTime,Float64}}}},
                        utc_day::Date;
                        scenario::Union{Nothing,Dict{String,Euphemia.ZoneScenario}}=nothing)
    haskey(cache, utc_day) && return cache[utc_day]
    println("  clearing UTC day $utc_day ...")
    # #182 limitation: the try/catch below catches ordinary errors but NOT a
    # HiGHS SIGSEGV, which kills this process outright (a same-process segfault
    # is uncatchable). The daily forecast clears only two UTC days per run, so
    # recovery is a re-invocation (the workflow's second daily attempt). The
    # survivable crash-retry lives in the pipelined backfill, not here.
    t0 = time()
    result = try
        Euphemia.run_multi_zone_market_clearing(utc_day;
            zones=ZONES,
            order_method=:merit_order,
            optimizer=OPTIMIZER,
            silent=true,
            save_to_db=false,        # forecast_prices is the ONLY output
            clearing_mode=CLEARING_MODE,
            enrich_network=true,
            passes=2,
            scenario=scenario)
    catch e
        e isa InterruptException && rethrow()
        println("  ❌ UTC day $utc_day clearing FAILED: $e")
        cache[utc_day] = nothing
        return nothing
    end
    elapsed = round(time() - t0, digits=1)
    ok = result.status == :optimal ||
         (result.status == :time_limit && !isempty(result.market_prices))
    if !ok
        println("  ❌ UTC day $utc_day clearing status=$(result.status)")
        cache[utc_day] = nothing
        return nothing
    end
    hourly = Dict{String,Dict{DateTime,Float64}}(
        zone => hourly_prices(result.market_prices[zone])
        for zone in keys(result.market_prices))
    println("  UTC day $utc_day cleared in $(elapsed)s (status=$(result.status), " *
            "$(length(hourly)) zones)")
    cache[utc_day] = hourly
    return hourly
end

function main()
    println("=" ^ 70)
    println("DAILY EX-ANTE FORECAST  zones=$(length(ZONES))  optimizer=$OPTIMIZER")
    println("  code_version=$CV  clearing_mode=$CLEARING_MODE  max_lead_days=$MAX_LEAD_DAYS")
    println("  input_mode=$INPUT_MODE " *
            (INPUT_MODE == "weather" ?
             "(EX-ANTE track: RES from raw weather + UNIFORM model load, all zones)" :
             "(reference track: pure ENTSO-E D-1 load + wind/solar forecasts)"))
    println("  force_rerun=$FORCE_RERUN  skip_clear=$SKIP_CLEAR  load_fill=$LOAD_FILL  res_fill=$RES_FILL")
    println("  delivery day = Europe/Athens market day (two UTC-day solves, stitched)")
    ZONES != FORECAST_FOOTPRINT &&
        println("  ⚠️ ZONES override active ($(join(ZONES, ","))) — testing footprint, not the 39-zone product")
    println("=" ^ 70)

    Euphemia.ensure_forecast_tables()

    # --- Order-book export (measured: ~150k tagged orders / 307 KB zstd
    # parquet per 39-zone two-pass day; ~112 MB/yr). The sink captures every
    # zone-day's FULL tagged book (the strategist view: per-unit ladders, RES,
    # IMPORT, DEMAND, BACKSTOP tags) right before merging; two-pass rebuilds
    # overwrite per (zone, day) so the final book wins. Books are written per
    # MARKET DAY to data/web/v1/books/<date>.parquet after the day's forecast
    # freezes, and pushed to the public data bucket when the S3 env is
    # present (same env contract as bin/extract_store.sh). Failures warn,
    # never break forecasting.
    _BOOKS = Dict{Tuple{String,Date},Vector{Tuple{Euphemia.SimpleOrder,String}}}()
    _BOOKS_LOCK = ReentrantLock()
    Euphemia.MeritOrderBook.BOOK_SINK[] = function (zone, day, tagged, res)
        lock(_BOOKS_LOCK) do
            _BOOKS[(zone, day)] = copy(tagged)
        end
    end

    now_utc = now(UTC)
    today_athens = athens_date(now_utc)
    latest_actual = latest_actual_load_date()
    first_candidate = latest_actual + Day(1)
    last_candidate = today_athens + Day(MAX_LEAD_DAYS)
    println("Realized-data horizon (actual_total_load): $latest_actual")
    println("Candidate Athens market days: $first_candidate .. $last_candidate " *
            "(today Athens = $today_athens, now UTC = $now_utc)")

    if first_candidate > last_candidate
        println("No candidate days (horizon beyond max lead) — nothing to do.")
        return
    end

    # RES coverage baseline: zones that had a wind/solar forecast on the most
    # recent fully-realized day's market window must also have one on any
    # predicted day's window. WEATHER MODE: the ENTSO-E RES requirement is
    # REMOVED (weather is always available; RES comes from bin/weather_res.jl)
    # — the LOAD and ATC gates stay exactly as-is.
    if INPUT_MODE == "weather"
        res_required = Set{String}()
        println("RES baseline: not required (input_mode=weather — RES predicted from raw weather)")
    else
        b0, b1 = athens_market_day_window(latest_actual)
        res_required = res_forecast_zones(b0, b1, ZONES)
        println("RES baseline (Athens day $latest_actual): $(length(res_required))/$(length(ZONES)) zones with wind/solar forecast")
    end

    # Per-day TSO load-hours and RES-present sets, computed once and reused by the
    # fill pre-passes and the market-day loop (one query each per candidate day
    # either way).
    day_load_hours = Dict{Date,Dict{String,Int}}()
    day_res_present = Dict{Date,Set{String}}()
    for day in first_candidate:Day(1):last_candidate
        w0, w1 = athens_market_day_window(day)
        day_load_hours[day] = load_forecast_hours(w0, w1, ZONES)
        day_res_present[day] = res_forecast_zones(w0, w1, ZONES)
    end

    # One asof for every vintage decision in this run (review #230 finding 4:
    # per-builder Date(now(UTC)) defaults can straddle midnight UTC and hand
    # the builders different vintages for the same market day).
    vintage_asof = Date(now(UTC))

    # ── Model-load pre-pass ─────────────────────────────────────────────────
    # WEATHER track: model load is the track's CORE input — predicted ONCE for
    # ALL zones over the whole UTC span (uniform composition, independent of
    # which TSOs published early). A zone the model cannot cover keeps its day
    # ineligible (no silent TSO mixing).
    # ENTSOE track: the retired opportunistic fill — only when LOAD_FILL=true,
    # and only for TSO-short zones (rows then carry the '+loadfill' suffix).
    fill_pred = Dict{String,Dict{DateTime,Float64}}()
    if INPUT_MODE == "weather"
        load_pack = load_load_models()
        load_pack === nothing &&
            error("weather track needs the load model pack at " *
                  "$(default_load_models_path()) (run bin/fit_load_models.jl) — " *
                  "load is uniformly model-sourced on this track")
        println("WEATHER LOAD: predicting model load for all $(length(ZONES)) zones ...")
        t0 = time()
        fill_pred = build_load_fills(load_pack, sort(copy(ZONES)),
                                     first_candidate - Day(1), last_candidate,
                                     Set(first_candidate:Day(1):last_candidate);
                                     asof=vintage_asof)
        println("WEATHER LOAD: model load ready for $(length(fill_pred))/$(length(ZONES)) " *
                "zone(s) in $(round(time() - t0, digits=1))s")
    elseif LOAD_FILL
        load_pack = load_load_models()
        if load_pack === nothing
            println("⚠️ LOAD_FILL on but no load pack at $(default_load_models_path()) — " *
                    "run bin/fit_load_models.jl; falling back to no-fill eligibility this run")
        else
            short_union = String[]
            for (_, lh) in day_load_hours, z in ZONES
                (get(lh, z, 0) < 20 && !(z in short_union)) && push!(short_union, z)
            end
            if isempty(short_union)
                println("LOAD FILL: no short zones across candidate days — nothing to fill")
            else
                println("LOAD FILL: $(length(short_union)) short zone(s) across candidate days " *
                        "($(join(sort(short_union), ","))) — predicting model load ...")
                t0 = time()
                fill_pred = build_load_fills(load_pack, sort(short_union),
                                             first_candidate - Day(1), last_candidate,
                                             Set(first_candidate:Day(1):last_candidate);
                                             asof=vintage_asof)
                println("LOAD FILL: model load ready for $(length(fill_pred))/$(length(short_union)) " *
                        "zone(s) in $(round(time() - t0, digits=1))s")
            end
        end
    else
        println("LOAD FILL: disabled (LOAD_FILL=false) — a short load zone skips the whole day")
    end
    load_fill_fn = make_load_fill_fn(fill_pred)

    # ── Eligibility RES FILL pre-pass (twin of LOAD FILL) ───────────────────
    # Zones REQUIRED to have wind/solar (had it on the last realized day) but
    # MISSING it on ANY candidate day are predicted ONCE from the weather→RES
    # pack. Only relevant on the entsoe reference track: the weather track has no
    # RES gate (res_required is empty) and already sources all RES from weather.
    res_pred = Dict{String,Dict{DateTime,Float64}}()
    if RES_FILL && !isempty(res_required)
        res_pack = load_res_models()
        res_short = String[]
        for day in first_candidate:Day(1):last_candidate, z in res_required
            (!(z in day_res_present[day]) && !(z in res_short)) && push!(res_short, z)
        end
        if isempty(res_short)
            println("RES FILL: no RES-missing required zones across candidate days — nothing to fill")
        else
            println("RES FILL: $(length(res_short)) RES-missing zone(s) across candidate days " *
                    "($(join(sort(res_short), ","))) — predicting weather wind+solar ...")
            t0 = time()
            res_pred = build_res_fills(res_pack, sort(res_short),
                                       first_candidate - Day(1), last_candidate,
                                       Set(first_candidate:Day(1):last_candidate);
                                       asof=vintage_asof)
            println("RES FILL: model RES ready for $(length(res_pred))/$(length(res_short)) " *
                    "zone(s) in $(round(time() - t0, digits=1))s")
        end
    elseif !RES_FILL
        println("RES FILL: disabled (RES_FILL=false) — a RES-missing required zone skips the whole day")
    end
    res_fill_fn = make_res_fill_fn(res_pred)

    # Weather track: fetch weather + predict per-zone RES ONCE for the whole
    # candidate window (both UTC days of each Athens market day), then thread
    # it into every clear as a per-zone scenario together with the uniform
    # model load (override + fill — see weather_scenario).
    scenario = nothing
    res_pred_weather = Dict{String,Dict{DateTime,Float64}}()
    if INPUT_MODE == "weather" && !SKIP_CLEAR
        println("Fetching open-meteo weather + predicting RES for UTC days " *
                "$(first_candidate - Day(1)) .. $last_candidate ...")
        t0 = time()
        preds = build_weather_predictions(first_candidate - Day(1), last_candidate,
                                          Set(first_candidate:Day(1):last_candidate);
                                          asof=vintage_asof)
        res_pred_weather = preds
        scenario = weather_scenario(preds, fill_pred)
        println("Weather RES ready for $(length(preds)) zones in $(round(time() - t0, digits=1))s")
    elseif (load_fill_fn !== nothing || res_fill_fn !== nothing) && !SKIP_CLEAR
        scenario = Dict{String,Euphemia.ZoneScenario}(
            zone => Euphemia.ZoneScenario(load_fill=load_fill_fn, res_fill=res_fill_fn)
            for zone in ZONES)
    end

    # UTC-day clear cache: market days D and D+1 share the UTC-day-D solve.
    clear_cache = Dict{Date,Union{Nothing,Dict{String,Dict{DateTime,Float64}}}}()

    n_predicted = 0
    for day in first_candidate:Day(1):last_candidate
        lead = forecast_lead_days(day, today_athens)
        w0, w1 = athens_market_day_window(day)
        expected = expected_market_day_hours(day)
        println("\n" * "-" ^ 70)
        println("ATHENS MARKET DAY $day (lead_days=$lead, window $w0 → $w1 UTC, " *
                "$(length(expected))h)")

        load_hours = day_load_hours[day]
        res_present = day_res_present[day]
        atc_rows = atc_row_count(w0, w1, ZONES)
        if INPUT_MODE == "weather"
            # Load eligibility = MODEL coverage (uniform model load replaces the
            # TSO-load gate); mode is always plain 'weather' — model inputs are
            # the track, not a fill, so no provenance suffix ever.
            covered = model_covered_for_day(day, fill_pred)
            uncovered = sort([z for z in ZONES if !(z in covered)])
            # RES coverage is gated exactly like load: a zone-hour the weather
            # model cannot predict would otherwise clear at ZERO wind+solar
            # (see res_covered_for_day). SKIP_CLEAR runs never build preds, so
            # the RES gate only applies when a clear will actually happen.
            res_covered = SKIP_CLEAR ? Set(ZONES) : res_covered_for_day(day, res_pred_weather)
            res_uncovered = sort([z for z in ZONES if !(z in res_covered)])
            if !isempty(uncovered)
                eligible = false
                reason = "weather-track model load cannot cover $(length(uncovered)) " *
                         "zone(s): $(join(uncovered, ","))"
            elseif !isempty(res_uncovered)
                eligible = false
                reason = "weather-track RES prediction cannot cover $(length(res_uncovered)) " *
                         "zone(s): $(join(res_uncovered, ",")) — refusing to clear them at zero wind+solar"
            else
                eligible, reason = eligibility_verdict(ZONES, load_hours, res_required,
                                                       res_present, atc_rows;
                                                       load_fill_zones=Set(ZONES))
            end
            day_mode = INPUT_MODE
        else
            fillable = fillable_for_day(day, load_hours, fill_pred)
            res_fillable = res_fillable_for_day(day, res_required, res_present, res_pred)
            eligible, reason = eligibility_verdict(ZONES, load_hours, res_required,
                                                   res_present, atc_rows;
                                                   load_fill_zones=fillable,
                                                   res_fill_zones=res_fillable)
            # Filled days (only when the retired fills are explicitly re-enabled)
            # are their OWN provenance slice/track: input_mode composes a
            # "+loadfill"/"+resfill" suffix so bin/score_forecasts.jl keeps them
            # separate from the pure-ENTSO-E track record (no pollution) and the
            # no-clobber slice identity never mixes a filled vintage with an
            # unfilled one. Order fixed (loadfill before resfill) — stable mode.
            suffixes = String[]
            isempty(fillable) || push!(suffixes, "loadfill")
            isempty(res_fillable) || push!(suffixes, "resfill")
            day_mode = isempty(suffixes) ? INPUT_MODE : INPUT_MODE * "+" * join(suffixes, "+")
            eligible && !isempty(fillable) &&
                println("  🩹 load-filled zone(s): $(join(sort(collect(fillable)), ","))")
            eligible && !isempty(res_fillable) &&
                println("  🩹 RES-filled zone(s): $(join(sort(collect(res_fillable)), ","))")
            (eligible && !isempty(suffixes)) && println("  (input_mode=$day_mode)")
        end
        println("  VERDICT: $(eligible ? "ELIGIBLE ✅" : "INELIGIBLE ⛔") — $reason")
        eligible || continue

        if !FORCE_RERUN
            present = existing_forecast_zones(day, lead, day_mode)
            if issubset(Set(ZONES), present)
                println("  already predicted: all $(length(ZONES)) zones present for " *
                        "(market_date=$day, lead_days=$lead, mode=$day_mode) at some " *
                        "code_version — skipping (FORCE_RERUN=true to rewrite)")
                continue
            elseif !isempty(present)
                println("  partial slice exists ($(length(present)) zone(s)) — " *
                        "re-predicting the full footprint (delete-then-insert of the slice)")
            end
        end

        if SKIP_CLEAR
            println("  SKIP_CLEAR=true — eligibility verified, the 39-zone clear " *
                    "is not attempted. No prediction written.")
            continue
        end

        # Two UTC-day clears cover the Athens window (see header comment).
        prediction_made = now(UTC)
        prev_hourly = clear_utc_day!(clear_cache, day - Day(1); scenario=scenario)
        prev_hourly === nothing && (println("  ❌ DAY $day: UTC day $(day - Day(1)) " *
                                            "clear unavailable — no prediction written"); continue)
        curr_hourly = clear_utc_day!(clear_cache, day; scenario=scenario)
        curr_hourly === nothing && (println("  ❌ DAY $day: UTC day $day " *
                                            "clear unavailable — no prediction written"); continue)

        # Stitch per zone; only COMPLETE market days are written.
        zone_hourly = Dict{String,Dict{DateTime,Float64}}()
        empty_hourly = Dict{DateTime,Float64}()
        for zone in union(keys(prev_hourly), keys(curr_hourly))
            st = stitch_market_day(day, get(prev_hourly, zone, empty_hourly),
                                   get(curr_hourly, zone, empty_hourly))
            if isempty(st.missing_hours)
                zone_hourly[zone] = st.stitched
            else
                println("  ⚠️ $zone: market day INCOMPLETE — " *
                        "$(length(st.missing_hours))/$(length(st.expected)) hour(s) missing " *
                        "($(join(Dates.format.(st.missing_hours, "yyyy-mm-ddTHH:MM") .* "Z", ", "))) " *
                        "— zone-day NOT written")
            end
        end
        if isempty(zone_hourly)
            println("  ❌ DAY $day: no zone produced a complete market day — nothing written")
            continue
        end

        n = write_forecast!(day, lead, prediction_made, zone_hourly, day_mode)
        n_predicted += n
        # Books captured during this market day's clears — freeze them next
        # to the vintage (only after the forecast wrote, so a refused write
        # never exports books for an unpublished day).
        try
            lock(_BOOKS_LOCK) do
                flush_books!(_BOOKS, day)
            end
        catch e
            @warn "book export failed (forecast unaffected)" day error = sprint(showerror, e)
        end
        println("  ✅ DAY $day — wrote $n forecast rows across $(length(zone_hourly)) " *
                "zone(s) ($(length(expected))h each; lead_days=$lead, cv=$CV, mode=$day_mode)")
        for z in ("GR", "DE_LU", "FR", "IT-NORTH", "NO2")
            haskey(zone_hourly, z) || continue
            p = collect(values(zone_hourly[z]))
            println("     $z mean=$(round(mean(p), digits=1)) min=$(round(minimum(p), digits=1)) " *
                    "max=$(round(maximum(p), digits=1)) €/MWh")
        end
    end

    println("\n" * "=" ^ 70)
    println("DAILY FORECAST COMPLETE — $n_predicted forecast rows written")
    println("=" ^ 70)
end

main()
