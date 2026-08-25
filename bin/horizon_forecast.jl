#!/usr/bin/env julia
#
# 7-day horizon forecast — leads 2..MAX_LEAD_DAYS (invoked after
# bin/daily_forecast.jl in the ceres predict job).
#
# The model's decisive inputs (ENTSO-E D-1 load and wind/solar forecasts) exist
# only for tomorrow, so genuine model re-forecasts stop at lead 1. To publish a
# full 7-day horizon TODAY, leads 2..7 use WEEKLY PERSISTENCE OF OUR OWN MODEL:
#
#   forecast(T, lead n) := our stored lead-1 forecast for P = T - 7 days,
#                          hours shifted +7 days.
#
# Rationale: P is the freshest same-weekday market day with complete inputs, so
# weekday structure (weekend/weekday load shape) is preserved; the relabel is
# trivially ex-ante (P's forecast was frozen at P-1 = T-8); and it costs zero
# solves. It is a persistence BASELINE by construction — when the weather->RES
# layer lands (docs/res-forecasting-investigation.md), each lead becomes a true
# re-forecast on fresh weather and the per-lead scoreboard will show the
# improvement against exactly this baseline.
#
# HONESTY GUARANTEES (same as daily_forecast.jl):
# - assert_unrealized / assert_hours_unrealized guards on every write.
# - No-clobber: an existing (market_date, lead) slice — at ANY code_version —
#   is never overwritten (FORCE_RERUN=true to rewrite). In particular a slice
#   written by a genuine model run is never replaced by a persistence relabel,
#   and a slice frozen under an earlier code_version is never rewritten by a
#   later one (vintages are immutable across model upgrades). Source-slice
#   reads (the T−7/T−14 lead-1 proxies) are likewise cv-agnostic, with
#   earliest-frozen-wins on cross-version duplicates; writes stamp the
#   current code_version as provenance.
# - Complete-or-skip per zone: a zone is written only when P has exactly the
#   hour count T expects; DST-transition mismatches (P and T in different
#   DST regimes, 4 weeks/year) skip the zone-day loudly.
# - prediction_made_utc = now(): the row records when WE said it, and the
#   underlying information (P's inputs) is from T-8 — strictly older.
#
# Env vars:
#   MAX_LEAD_DAYS  furthest lead to fill, default 7
#   FORCE_RERUN    'true' to rewrite existing slices (default false)
#   CLEARING_MODE  source/label clearing mode (default 'multi_zone_eu')

using Euphemia, Dates, LibPQ

include(joinpath(@__DIR__, "forecast_common.jl"))

const MAX_LEAD_DAYS = parse(Int, get(ENV, "MAX_LEAD_DAYS", "7"))
const FORCE_RERUN = lowercase(get(ENV, "FORCE_RERUN", "false")) == "true"
const CLEARING_MODE = get(ENV, "CLEARING_MODE", "multi_zone_eu")
const CV = Euphemia.ENERGY_PRICES_CODE_VERSION

# cv34 (owner decision 2026-08-25): the leads 2..N written here are WEEKLY
# PERSISTENCE copies of the T-7 lead-1 entsoe clear, not model clears. They
# used to be stamped input_mode='entsoe' — indistinguishable from a real
# clear, stamped with the running cv although the copied prices came from
# whatever cv produced the source slice — so the per-lead board compared the
# weather track's genuine lead-n clear against a relabelled lead-1. They now
# carry input_mode='entsoe_persist' (the site's "As announced" track matches
# the "entsoe*" prefix, so they still render there, labelled). One-off relabel
# of the rows written before cv34:
#   UPDATE simulations.forecast_prices SET input_mode = 'entsoe_persist'
#    WHERE input_mode = 'entsoe' AND lead_days >= 2;
#   UPDATE simulations.forecast_scores SET input_mode = 'entsoe_persist'
#    WHERE input_mode = 'entsoe' AND lead_days >= 2;
const PERSIST_MODE = "entsoe_persist"

function latest_actual_load_date()
    df = Euphemia.sql2df_with_retry(
        "SELECT MAX((date_time_utc AT TIME ZONE 'UTC')::date) AS d FROM entsoe.actual_total_load")
    (isempty(df) || ismissing(df.d[1])) && error("entsoe.actual_total_load is empty")
    return Date(df.d[1])
end

"""
lead-1 model rows for market day P: zone -> (hour -> price).

CV-AGNOSTIC with earliest-frozen-wins: the persistence source is whatever
lead-1 slice was frozen FIRST for P, regardless of the code_version that wrote
it (the product's record spans code versions; a cv bump must not stall the
ladder for 7 days waiting for new-cv lead-1s to accumulate). Where a
cross-version duplicate exists, the slice with the smallest slice-level
MIN(prediction_made_utc) is used (lowest code_version as tiebreaker).
"""
function source_rows(P::Date)
    df = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, (date_time_utc AT TIME ZONE 'UTC') AS t, price_eur_mwh AS p
        FROM simulations.forecast_prices
        WHERE market_date = \$1 AND lead_days = 1 AND clearing_mode = \$2
          AND input_mode = 'entsoe'
          AND code_version = (
              SELECT code_version FROM simulations.forecast_prices
              WHERE market_date = \$1 AND lead_days = 1 AND clearing_mode = \$2
                AND input_mode = 'entsoe'
              GROUP BY code_version
              ORDER BY MIN(prediction_made_utc), code_version
              LIMIT 1)
    """, [P, CLEARING_MODE])
    out = Dict{String,Dict{DateTime,Float64}}()
    for r in eachrow(df)
        push!(get!(out, String(r.z), Dict{DateTime,Float64}()), DateTime(r.t) => Float64(r.p))
    end
    return out
end

"Rows already present in the (T, lead) slice — at ANY code_version (cv-agnostic no-clobber)."
function slice_row_count(T::Date, lead::Int)
    df = Euphemia.sql2df_with_retry("""
        SELECT COUNT(*) AS n FROM simulations.forecast_prices
        WHERE market_date = \$1 AND lead_days = \$2 AND input_mode = 'entsoe_persist'
    """, [T, lead])
    return Int(df.n[1])
end

"""
Delete-then-insert the (T, lead) slice — same pattern as daily_forecast. The
DELETE is CV-AGNOSTIC (clears the slice at any code_version so a rewrite can
never leave a cross-version duplicate); the INSERT stamps the current cv.
"""
function write_slice!(T::Date, lead::Int, made::DateTime,
                      zone_hourly::Dict{String,Dict{DateTime,Float64}})
    latest = latest_actual_load_date()
    assert_unrealized(T, latest)
    for (_, hourly) in zone_hourly
        assert_hours_unrealized(keys(hourly), made)
    end
    tstz(dt::DateTime) = Dates.format(dt, "yyyy-mm-dd HH:MM:SS") * "+00"
    n = 0
    Euphemia.withdb() do cnx
        LibPQ.execute(cnx, "BEGIN")
        try
            LibPQ.execute(cnx, """
                DELETE FROM simulations.forecast_prices
                WHERE market_date = \$1 AND lead_days = \$2 AND input_mode = 'entsoe_persist'
            """, [T, lead])
            for (zone, hourly) in zone_hourly
                for (h, price) in sort!(collect(hourly); by=first)
                    LibPQ.execute(cnx, """
                        INSERT INTO simulations.forecast_prices
                        (market_date, date_time_utc, bidding_zone, price_eur_mwh,
                         prediction_made_utc, lead_days, clearing_mode, code_version, input_mode)
                        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, 'entsoe_persist')
                    """, Any[T, tstz(h), zone, price, tstz(made), lead, CLEARING_MODE, CV])
                    n += 1
                end
            end
            LibPQ.execute(cnx, "COMMIT")
        catch e
            LibPQ.execute(cnx, "ROLLBACK")
            rethrow(e)
        end
    end
    return n
end

function main()
    println("=" ^ 70)
    println("HORIZON FORECAST (weekly-persistence leads 2..$MAX_LEAD_DAYS)  cv=$CV")
    println("=" ^ 70)
    made = now(UTC)
    base = athens_date(made)   # today's Athens market day; T = base + n

    total = 0
    for n in 2:MAX_LEAD_DAYS
        T = base + Day(n)
        P = T - Day(7)
        hoursT = expected_market_day_hours(T)
        hoursP = expected_market_day_hours(P)
        expT = length(hoursT)

        if slice_row_count(T, n) > 0 && !FORCE_RERUN
            println("lead $n → $T: slice exists, skipping (no-clobber)")
            continue
        end
        if expT != length(hoursP) || hoursT != hoursP .+ Day(7)
            println("lead $n → $T: DST window mismatch vs $P ($(length(hoursP)) h → $expT h), skipping")
            continue
        end

        src = source_rows(P)
        # Fallback proxy: same weekday two weeks back. Needed when T-7's slice
        # is absent or incomplete (e.g. the legacy 21-hour 2026-07-12 day,
        # which would otherwise leave a permanent hole at its T+7).
        used_P = P
        complete(s) = any(length(h) == expT for h in values(s))
        if isempty(src) || !complete(src)
            P2 = T - Day(14)
            hoursP2 = expected_market_day_hours(P2)
            if length(hoursP2) == expT && hoursT == hoursP2 .+ Day(14)
                src2 = source_rows(P2)
                if !isempty(src2) && complete(src2)
                    src = Dict(z => Dict(h + Day(7) => p for (h, p) in hh) for (z, hh) in src2)
                    used_P = P2
                    println("lead $n → $T: proxy $P incomplete — using fallback $P2")
                end
            end
        end
        if isempty(src)
            println("lead $n → $T: no lead-1 model rows for proxy $P (or fallback), skipping")
            continue
        end

        shifted = Dict{String,Dict{DateTime,Float64}}()
        skipped = String[]
        for (zone, hourly) in src
            if length(hourly) != expT
                push!(skipped, "$zone($(length(hourly))h)")
                continue
            end
            shifted[zone] = Dict(h + Day(7) => p for (h, p) in hourly)
        end
        isempty(skipped) || println("  incomplete zones skipped: " * join(sort(skipped), ", "))
        if isempty(shifted)
            println("lead $n → $T: no complete zone-days in proxy $P, skipping")
            continue
        end

        nrows = write_slice!(T, n, made, shifted)
        total += nrows
        println("lead $n → $T: wrote $nrows rows ($(length(shifted)) zones, proxy $P)")
    end
    println("HORIZON COMPLETE — $total rows written")
end

main()
