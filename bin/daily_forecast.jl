#!/usr/bin/env julia
#
# Daily ex-ante price forecast (invoked by .github/workflows/daily-forecast.yml).
#
# Discovers not-yet-realized market days with complete input data, runs the
# standard 39-zone EU merit-order clearing for each (ex-ante :v2 flows are the
# cv16 default on this path — never overridden here), and writes hourly price
# predictions to simulations.forecast_prices stamped with prediction_made_utc
# and lead_days, so accuracy can later be tracked honestly per region and per
# lead time (bin/score_forecasts.jl).
#
# HONESTY GUARANTEES:
# - A day is only predicted if it is strictly beyond the realized-data horizon
#   (MAX date of entsoe.actual_total_load). Writing a "prediction" for a
#   realized day is refused with an error (assert_unrealized).
# - The eligibility gate never degrades: if ANY footprint zone is missing its
#   day-ahead load forecast (≥20 hourly rows), or a zone that had a wind/solar
#   forecast on the last realized day is missing one, or the day has no offered
#   ATC rows, the day is skipped loudly (verdict + reason logged per day).
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

"Zone → number of distinct forecast hours in day_ahead_total_load_forecast for `day`."
function load_forecast_hours(day::Date, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS z,
               COUNT(DISTINCT date_trunc('hour', date_time_utc)) AS nh
        FROM entsoe.day_ahead_total_load_forecast
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = ANY(\$2)
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
        GROUP BY 1
    """, [day, zones])
    return Dict{String,Int}(String(r.z) => Int(r.nh) for r in eachrow(df))
end

"Set of zones with a non-null day-ahead wind/solar forecast for `day`."
function res_forecast_zones(day::Date, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT area_map_code AS z
        FROM entsoe.generation_forecasts_for_wind_and_solar
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = ANY(\$2)
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
          AND day_ahead_generation_forecast_mw IS NOT NULL
    """, [day, zones])
    return Set{String}(String.(df.z))
end

"Count of offered implicit-ATC rows touching the footprint for `day`."
function atc_row_count(day::Date, zones::Vector{String})
    df = Euphemia.sql2df_with_retry("""
        SELECT COUNT(*) AS n
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND (out_map_code = ANY(\$2) OR in_map_code = ANY(\$2))
    """, [day, zones])
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
one transaction. `zone_hourly` is zone → (hour::DateTime → price). The realized
guard is re-checked immediately before the write (the horizon may have advanced
during a long solve).
"""
function write_forecast!(market_date::Date, lead_days::Int, prediction_made::DateTime,
                         zone_hourly::Dict{String,Dict{DateTime,Float64}})
    latest_actual = latest_actual_load_date()
    assert_unrealized(market_date, latest_actual)   # HARD GUARD

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

function main()
    println("=" ^ 70)
    println("DAILY EX-ANTE FORECAST  zones=$(length(ZONES))  optimizer=$OPTIMIZER")
    println("  code_version=$CV  clearing_mode=$CLEARING_MODE  max_lead_days=$MAX_LEAD_DAYS")
    println("  force_rerun=$FORCE_RERUN  skip_clear=$SKIP_CLEAR")
    ZONES != FORECAST_FOOTPRINT &&
        println("  ⚠️ ZONES override active ($(join(ZONES, ","))) — testing footprint, not the 39-zone product")
    println("=" ^ 70)

    Euphemia.ensure_forecast_tables()

    today_utc = Date(now(UTC))
    latest_actual = latest_actual_load_date()
    first_candidate = latest_actual + Day(1)
    last_candidate = today_utc + Day(MAX_LEAD_DAYS)
    println("Realized-data horizon (actual_total_load): $latest_actual")
    println("Candidate market days: $first_candidate .. $last_candidate (today UTC = $today_utc)")

    if first_candidate > last_candidate
        println("No candidate days (horizon beyond max lead) — nothing to do.")
        return
    end

    # RES coverage baseline: zones that had a wind/solar forecast on the most
    # recent fully-realized day must also have one on any predicted day.
    res_required = res_forecast_zones(latest_actual, ZONES)
    println("RES baseline ($latest_actual): $(length(res_required))/$(length(ZONES)) zones with wind/solar forecast")

    n_predicted = 0
    for day in first_candidate:Day(1):last_candidate
        lead = forecast_lead_days(day, today_utc)
        println("\n" * "-" ^ 70)
        println("DAY $day (lead_days=$lead)")

        load_hours = load_forecast_hours(day, ZONES)
        res_present = res_forecast_zones(day, ZONES)
        atc_rows = atc_row_count(day, ZONES)
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

        prediction_made = now(UTC)
        t0 = time()
        result = try
            Euphemia.run_multi_zone_market_clearing(day;
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
            println("  ❌ DAY $day clearing FAILED: $e")
            continue
        end
        elapsed = round(time() - t0, digits=1)

        ok = result.status == :optimal ||
             (result.status == :time_limit && !isempty(result.market_prices))
        if !ok
            println("  ❌ DAY $day clearing status=$(result.status) — no prediction written")
            continue
        end

        zone_hourly = Dict{String,Dict{DateTime,Float64}}(
            zone => hourly_prices(result.market_prices[zone])
            for zone in keys(result.market_prices))
        n = write_forecast!(day, lead, prediction_made, zone_hourly)
        n_predicted += n
        println("  ✅ DAY $day cleared in $(elapsed)s (status=$(result.status)) — " *
                "wrote $n forecast rows (lead_days=$lead, cv=$CV)")
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
