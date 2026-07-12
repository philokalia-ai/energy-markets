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
# Env vars:
#   OPTIMIZER      'gurobi' (default) / 'highs' / 'auto'
#   MAX_LEAD_DAYS  furthest lead to attempt, default 7
#   FORCE_RERUN    'true' to rewrite an existing (market_date, lead, cv) slice
#   ZONES          comma-separated footprint override (FOR TESTING ONLY, e.g.
#                  a 5-zone footprint when the Gurobi license is unavailable);
#                  default = the 39-zone EU footprint
#   CLEARING_MODE  label stored on forecast rows (default 'multi_zone_eu')
#   SKIP_CLEAR     'true' = run discovery + eligibility logging only, never
#                  solve (used by CI when Gurobi credentials are absent — the
#                  39-zone clear does not converge with HiGHS)

using Euphemia, Dates, Statistics, LibPQ

include(joinpath(@__DIR__, "forecast_common.jl"))

const OPTIMIZER = get(ENV, "OPTIMIZER", "gurobi")
const MAX_LEAD_DAYS = parse(Int, get(ENV, "MAX_LEAD_DAYS", "7"))
const FORCE_RERUN = lowercase(get(ENV, "FORCE_RERUN", "false")) == "true"
const SKIP_CLEAR = lowercase(get(ENV, "SKIP_CLEAR", "false")) == "true"
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

"Set of zones with a non-null day-ahead wind/solar forecast in [t0, t1)."
function res_forecast_zones(t0::DateTime, t1::DateTime, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT area_map_code AS z
        FROM entsoe.generation_forecasts_for_wind_and_solar
        WHERE date_time_utc >= (\$1::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = ANY(\$3)
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
          AND day_ahead_generation_forecast_mw IS NOT NULL
    """, [t0, t1, zones])
    return Set{String}(String.(df.z))
end

"Count of offered implicit-ATC rows touching the footprint in [t0, t1)."
function atc_row_count(t0::DateTime, t1::DateTime, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT COUNT(*) AS n
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE date_time_utc >= (\$1::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::timestamp AT TIME ZONE 'UTC')
          AND (out_map_code = ANY(\$3) OR in_map_code = ANY(\$3))
    """, [t0, t1, zones])
    return Int(df.n[1])
end

"Zones already present in the (market_date, lead_days, code_version) slice."
function existing_forecast_zones(market_date::Date, lead_days::Int)
    df = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT bidding_zone AS z FROM simulations.forecast_prices
        WHERE market_date = \$1 AND lead_days = \$2 AND code_version = \$3
    """, [market_date, lead_days, CV])
    return Set{String}(String.(df.z))
end

"""
Delete-then-insert exactly the (market_date, lead_days, code_version) slice in
one transaction. `zone_hourly` is zone → (hour::DateTime → price), already
stitched and completeness-checked per zone (every zone here has exactly the
expected market-day hours). The realized guard is re-checked immediately
before the write (the horizon may have advanced during a long solve), and the
HOUR-LEVEL guard refuses any row at or before `prediction_made`.
"""
function write_forecast!(market_date::Date, lead_days::Int, prediction_made::DateTime,
                         zone_hourly::Dict{String,Dict{DateTime,Float64}})
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
                WHERE market_date = \$1 AND lead_days = \$2 AND code_version = \$3
            """, [market_date, lead_days, CV])
            for (zone, hourly) in zone_hourly
                for (h, price) in sort!(collect(hourly); by=first)
                    LibPQ.execute(cnx, """
                        INSERT INTO simulations.forecast_prices
                        (market_date, date_time_utc, bidding_zone, price_eur_mwh,
                         prediction_made_utc, lead_days, clearing_mode, code_version)
                        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
                    """, Any[market_date, tstz(h), zone, price,
                             tstz(prediction_made), lead_days, CLEARING_MODE, CV])
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
Clear one UTC calendar day with the standard 39-zone machinery and collapse to
zone → (hour → price). Returns `nothing` on failure. Results are memoized in
`cache` so consecutive market days share their overlapping UTC-day solve.
"""
function clear_utc_day!(cache::Dict{Date,Union{Nothing,Dict{String,Dict{DateTime,Float64}}}},
                        utc_day::Date)
    haskey(cache, utc_day) && return cache[utc_day]
    println("  clearing UTC day $utc_day ...")
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
            passes=2)
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
    println("  force_rerun=$FORCE_RERUN  skip_clear=$SKIP_CLEAR")
    println("  delivery day = Europe/Athens market day (two UTC-day solves, stitched)")
    ZONES != FORECAST_FOOTPRINT &&
        println("  ⚠️ ZONES override active ($(join(ZONES, ","))) — testing footprint, not the 39-zone product")
    println("=" ^ 70)

    Euphemia.ensure_forecast_tables()

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
    # predicted day's window.
    b0, b1 = athens_market_day_window(latest_actual)
    res_required = res_forecast_zones(b0, b1, ZONES)
    println("RES baseline (Athens day $latest_actual): $(length(res_required))/$(length(ZONES)) zones with wind/solar forecast")

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

        load_hours = load_forecast_hours(w0, w1, ZONES)
        res_present = res_forecast_zones(w0, w1, ZONES)
        atc_rows = atc_row_count(w0, w1, ZONES)
        eligible, reason = eligibility_verdict(ZONES, load_hours, res_required,
                                               res_present, atc_rows)
        println("  VERDICT: $(eligible ? "ELIGIBLE ✅" : "INELIGIBLE ⛔") — $reason")
        eligible || continue

        if !FORCE_RERUN
            present = existing_forecast_zones(day, lead)
            if issubset(Set(ZONES), present)
                println("  already predicted: all $(length(ZONES)) zones present for " *
                        "(market_date=$day, lead_days=$lead, cv=$CV) — skipping " *
                        "(FORCE_RERUN=true to rewrite)")
                continue
            elseif !isempty(present)
                println("  partial slice exists ($(length(present)) zone(s)) — " *
                        "re-predicting the full footprint (delete-then-insert of the slice)")
            end
        end

        if SKIP_CLEAR
            println("  SKIP_CLEAR=true — eligibility verified, but the 39-zone clear " *
                    "is not attempted (no Gurobi credentials; HiGHS does not converge " *
                    "on the coupled 39-zone MIP). No prediction written.")
            continue
        end

        # Two UTC-day clears cover the Athens window (see header comment).
        prediction_made = now(UTC)
        prev_hourly = clear_utc_day!(clear_cache, day - Day(1))
        prev_hourly === nothing && (println("  ❌ DAY $day: UTC day $(day - Day(1)) " *
                                            "clear unavailable — no prediction written"); continue)
        curr_hourly = clear_utc_day!(clear_cache, day)
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

        n = write_forecast!(day, lead, prediction_made, zone_hourly)
        n_predicted += n
        println("  ✅ DAY $day — wrote $n forecast rows across $(length(zone_hourly)) " *
                "zone(s) ($(length(expected))h each; lead_days=$lead, cv=$CV)")
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
