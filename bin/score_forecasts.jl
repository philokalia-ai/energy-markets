#!/usr/bin/env julia
#
# Score realized forecasts (invoked by .github/workflows/daily-forecast.yml
# after bin/daily_forecast.jl).
#
# For every (market_date, lead_days, code_version, input_mode) slice in
# simulations.forecast_prices whose market day now has realized actual
# day-ahead prices and no forecast_scores row yet (or RESCORE=true), computes
# per-zone MAE, bias (sim − actual) and Pearson correlation over the day's
# hours and upserts into simulations.forecast_scores. The reference
# ('entsoe') and ex-ante ('weather') tracks are scored as separate slices —
# scores are per (date, zone, lead, cv, mode).
#
# Actuals methodology: resolution-aware, exactly the iteration-4 standard from
# test/scripts/eu_eval_metrics.jl (whose `resolution_aware_actuals` is reused
# directly): dedup entsoe.energy_prices to the latest `sequence` revision per
# (zone, timestamp), then average sub-hourly (PT15M/PT30M) prices into each
# hour — a no-op for hourly zones.
#
# forecast_scores is STRICTLY for forecast_prices rows — never for the
# energy_prices backfill tables (those are scored by the eval scripts).
#
# Env vars:
#   RESCORE  'true' to recompute slices that already have scores

using Euphemia, Dates, Statistics, Printf, DataFrames, LibPQ

include(joinpath(@__DIR__, "forecast_common.jl"))
# Reuse the shared resolution-aware actuals (guarded __main__, safe to include).
include(joinpath(@__DIR__, "..", "test", "scripts", "eu_eval_metrics.jl"))

const RESCORE = lowercase(get(ENV, "RESCORE", "false")) == "true"
const RESCORE_WINDOW_DAYS = parse(Int, get(ENV, "RESCORE_WINDOW_DAYS", "7"))

"""
Slices of forecast_prices whose market day has realized actual DA prices.
market_date is the Europe/Athens market day; its window's FINAL hours fall on
UTC calendar day market_date, so EXISTS over the UTC day remains a correct
readiness trigger (DA prices for a local delivery day publish as one batch —
when any UTC-day-D row exists, the full Athens window is available).
"""
function pending_slices()
    # Self-healing window: a slice can legitimately be REWRITTEN after it was
    # scored (e.g., the -500-tail fix regenerated 2026-07-12 but its stale
    # scores survived, showing DE_LU corr -0.01 against a chart at 0.97).
    # Always rescore recent days — upsert_score! makes this idempotent and the
    # window is a handful of slices, so the cost is negligible.
    rescore_clause = RESCORE ? "" : """
        AND (fp.market_date >= CURRENT_DATE - $(RESCORE_WINDOW_DAYS)
             OR NOT EXISTS (
            SELECT 1 FROM simulations.forecast_scores s
            WHERE s.market_date = fp.market_date
              AND s.lead_days = fp.lead_days
              AND s.code_version = fp.code_version
              AND s.input_mode = fp.input_mode))
    """
    return Euphemia.sql2df_with_retry("""
        SELECT DISTINCT fp.market_date, fp.lead_days, fp.code_version, fp.input_mode
        FROM simulations.forecast_prices fp
        WHERE EXISTS (
            SELECT 1 FROM entsoe.energy_prices a
            WHERE a.contract_type = 'Day-ahead'
              AND a.area_type_code LIKE 'BZN%'
              AND a.price_currency_mwh IS NOT NULL
              AND a.date_time_utc >= (fp.market_date::timestamp AT TIME ZONE 'UTC')
              AND a.date_time_utc < ((fp.market_date + 1)::timestamp AT TIME ZONE 'UTC'))
        $rescore_clause
        ORDER BY 1, 2
    """)
end

"Sim forecast rows of one slice, keyed (zone, naive-UTC hour)."
function slice_sim(market_date::Date, lead_days::Int, cv::Int, input_mode::String)
    return Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, (date_time_utc AT TIME ZONE 'UTC') AS t,
               price_eur_mwh AS sim
        FROM simulations.forecast_prices
        WHERE market_date = \$1 AND lead_days = \$2 AND code_version = \$3
          AND input_mode = \$4
        ORDER BY 1, 2
    """, [market_date, lead_days, cv, input_mode])
end

function upsert_score!(market_date::Date, zone::String, lead_days::Int, cv::Int,
                       input_mode::String, n::Int, mae, bias, corr)
    tonull(x) = x === nothing ? missing : x
    Euphemia.withdb() do cnx
        LibPQ.execute(cnx, """
            INSERT INTO simulations.forecast_scores
            (market_date, bidding_zone, lead_days, code_version, input_mode,
             n_hours, mae, bias, corr, scored_at)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, now())
            ON CONFLICT (market_date, bidding_zone, lead_days, code_version, input_mode)
            DO UPDATE SET n_hours = EXCLUDED.n_hours, mae = EXCLUDED.mae,
                          bias = EXCLUDED.bias, corr = EXCLUDED.corr, scored_at = now()
        """, Any[market_date, zone, lead_days, cv, input_mode,
                 n, tonull(mae), tonull(bias), tonull(corr)])
    end
end

"Per input_mode × lead_days × zone aggregate over all stored scores (GR first, then AGG)."
function print_summary()
    df = Euphemia.sql2df_with_retry("""
        SELECT input_mode AS mode, lead_days, bidding_zone AS z, COUNT(*) AS n_days,
               AVG(mae) AS mae, AVG(bias) AS bias, AVG(corr) AS corr
        FROM simulations.forecast_scores
        GROUP BY 1, 2, 3
        ORDER BY 1, 2, 3
    """)
    if isempty(df)
        println("\nNo forecast scores stored yet — summary empty.")
        return
    end
    fmt(x) = (x === missing || x === nothing) ? "      -" : @sprintf("%7.2f", x)
    println("\n### Forecast accuracy summary (per input_mode × lead_days × zone, all stored scores)")
    @printf("%-8s %-6s %-12s %7s %7s %8s %7s\n", "mode", "lead", "zone", "n_days", "MAE", "bias", "corr")
    for mode in sort(unique(String.(df.mode)))
        msub = df[df.mode .== mode, :]
        for lead in sort(unique(msub.lead_days))
            sub = msub[msub.lead_days .== lead, :]
            # GR first, then the rest alphabetically
            order = vcat(findall(sub.z .== "GR"), findall(sub.z .!= "GR"))
            for i in order
                r = sub[i, :]
                @printf("%-8s %-6d %-12s %7d %s %s %s\n", mode, lead, r.z, r.n_days,
                        fmt(r.mae), fmt(r.bias), fmt(r.corr))
            end
            # aggregate row across zones for this lead
            mae_v = collect(skipmissing(sub.mae))
            bias_v = collect(skipmissing(sub.bias))
            corr_v = collect(skipmissing(sub.corr))
            @printf("%-8s %-6d %-12s %7d %s %s %s\n", mode, lead, "AGG",
                    sum(sub.n_days),
                    fmt(isempty(mae_v) ? missing : mean(mae_v)),
                    fmt(isempty(bias_v) ? missing : mean(bias_v)),
                    fmt(isempty(corr_v) ? missing : mean(corr_v)))
        end
    end
end

function main()
    println("=" ^ 70)
    println("SCORE FORECASTS  rescore=$RESCORE")
    println("=" ^ 70)

    Euphemia.ensure_forecast_tables()

    slices = pending_slices()
    if isempty(slices)
        println("No realized, unscored forecast slices — nothing to score.")
        print_summary()
        return
    end
    println("$(nrow(slices)) slice(s) to score")

    for r in eachrow(slices)
        market_date = Date(r.market_date)
        lead_days = Int(r.lead_days)
        cv = Int(r.code_version)
        input_mode = String(r.input_mode)
        println("\nScoring market_date=$market_date lead_days=$lead_days cv=$cv mode=$input_mode")

        sim = slice_sim(market_date, lead_days, cv, input_mode)
        # market_date is the Europe/Athens market day: its window starts at
        # 21:00/22:00 UTC on market_date-1, so actuals must cover BOTH UTC days.
        act = resolution_aware_actuals(market_date - Day(1), market_date)
        actmap = Dict{Tuple{String,DateTime},Float64}(
            (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

        for zone in sort(unique(String.(sim.z)))
            sub = sim[sim.z .== zone, :]
            sv = Float64[]; av = Float64[]
            for row in eachrow(sub)
                k = (zone, trunc(DateTime(row.t), Hour))
                haskey(actmap, k) || continue
                push!(sv, Float64(row.sim)); push!(av, actmap[k])
            end
            if isempty(sv)
                println("  $zone: no realized actual prices for this day — skipped")
                continue
            end
            s = score_series(sv, av)
            upsert_score!(market_date, zone, lead_days, cv, input_mode,
                          s.n, s.mae, s.bias, s.corr)
            corr_str = s.corr === nothing ? "-" : @sprintf("%.2f", s.corr)
            @printf("  %-12s n=%2d MAE=%6.1f bias=%+7.1f corr=%s\n",
                    zone, s.n, s.mae, s.bias, corr_str)
        end
    end

    print_summary()
    println("\nSCORING COMPLETE")
end

main()
