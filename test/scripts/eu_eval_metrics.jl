# EU footprint calibration — shared per-zone accuracy metrics.
#
# Compares a saved `simulations.energy_prices` clearing_mode against actual
# day-ahead prices in `entsoe.energy_prices`, per bidding zone, over a window.
#
# THE ACTUALS METHODOLOGY (resolution-aware, the iteration-4 standard):
# `entsoe.energy_prices` day-ahead rows come at mixed resolutions — PT60M for
# some zones, PT15M (quarter-hourly MTU) for a growing majority, PT30M for a
# few — and some zones carry MULTIPLE `sequence` revisions per timestamp with
# different prices (e.g. AT: seq 1 = 164.81, seq 2 = 167.29 at the same MTU).
# The simulator clears HOURLY (one price at :00). The correct comparison is the
# hourly-mean actual:
#   1. dedup to one price per (map_code, date_time_utc): highest `sequence`
#      (latest revision), tie-broken by latest `update_time_utc`;
#   2. aggregate to the hour: AVG of the (1/2/4) sub-hourly prices in each hour
#      — a no-op for PT60M zones (hourly series used as-is), the hourly mean of
#      the quarter-hours for PT15M zones.
# The legacy method (`old`) instead matched the sim's :00 point against ONLY the
# :00 quarter-hour actual (and double-counted duplicate `sequence` rows), which
# diverges for volatile 15-minute zones. `old` is kept ONLY to translate the
# pre-iteration-4 tables; every new comparison uses the resolution-aware method.
#
# Usage:
#   julia --project=. test/scripts/eu_eval_metrics.jl \
#       <clearing_mode> <code_version> <start> <end> [new|old|both] [zones|all]
# Example:
#   julia --project=. test/scripts/eu_eval_metrics.jl multi_zone_eu_cal9 10 \
#       2026-04-01 2026-04-05 both all

using Euphemia, Dates, Statistics, Printf, DataFrames

"""
    resolution_aware_actuals(sd, ed; contract="Day-ahead") -> DataFrame(z, t, act)

Hourly actual day-ahead prices keyed by zone `z` and naive-UTC hour `t`.
Deduplicates multi-`sequence` revisions (latest wins) then averages sub-hourly
prices into each hour. See file header for the full rationale.
"""
function resolution_aware_actuals(sd::Date, ed::Date; contract::String="Day-ahead")
    Euphemia.sql2df("""
        WITH dedup AS (
          SELECT DISTINCT ON (map_code, date_time_utc)
                 map_code, date_time_utc, price_currency_mwh
          FROM entsoe.energy_prices
          WHERE contract_type = \$1 AND area_type_code LIKE 'BZN%'
            AND price_currency_mwh IS NOT NULL
            AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
            AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
          ORDER BY map_code, date_time_utc,
                   (CASE WHEN sequence ~ '^\\s*\\d+\\s*\$' THEN trim(sequence)::int
                         ELSE NULL END) DESC NULLS LAST,
                   update_time_utc DESC
        )
        SELECT map_code AS z,
               date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS t,
               AVG(price_currency_mwh) AS act
        FROM dedup
        GROUP BY 1, 2
    """, [contract, sd, ed])
end

"""
    legacy_actuals(sd, ed; contract="Day-ahead") -> DataFrame(z, t, act)

The pre-iteration-4 method: every raw DA row at its own timestamp (no dedup, no
hourly aggregation). Only kept to translate old tables to the new methodology.
"""
function legacy_actuals(sd::Date, ed::Date; contract::String="Day-ahead")
    Euphemia.sql2df("""
        SELECT map_code AS z,
               (date_time_utc AT TIME ZONE 'UTC') AS t,
               price_currency_mwh AS act
        FROM entsoe.energy_prices
        WHERE contract_type = \$1 AND area_type_code LIKE 'BZN%'
          AND price_currency_mwh IS NOT NULL
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
    """, [contract, sd, ed])
end

function sim_prices(cm::String, cv::Int, sd::Date, ed::Date)
    Euphemia.sql2df("""
        SELECT bidding_zone AS z, date_time_utc AS t, price_eur_mwh AS sim
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND contract_type = 'Day-Ahead'
          AND date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  ((\$4::date + 1)::timestamp AT TIME ZONE 'UTC')
    """, [cm, cv, sd, ed])
end

"""
    metrics(cm, cv, sd, ed; method=:new, zones=nothing) -> Vector of NamedTuple

Per-zone (n, corr, mae, bias, simμ, actμ). Joins sim to actuals on (zone, hour).
"""
function metrics(cm::String, cv::Int, sd::Date, ed::Date;
                 method::Symbol=:new, zones=nothing)
    sim = sim_prices(cm, cv, sd, ed)
    act = method === :old ? legacy_actuals(sd, ed) : resolution_aware_actuals(sd, ed)
    # Build actual lookup keyed on (zone, DateTime). `t` is naive-UTC.
    actmap = Dict{Tuple{String,DateTime},Float64}()
    for r in eachrow(act)
        actmap[(String(r.z), DateTime(r.t))] = Float64(r.act)
    end
    allz = zones === nothing ? sort(unique(String.(sim.z))) : sort(collect(zones))
    out = NamedTuple[]
    for z in allz
        sub = sim[sim.z .== z, :]
        sv = Float64[]; av = Float64[]
        for r in eachrow(sub)
            k = (z, DateTime(r.t))
            haskey(actmap, k) || continue
            push!(sv, Float64(r.sim)); push!(av, actmap[k])
        end
        length(sv) < 3 && continue
        c = (std(sv) > 0 && std(av) > 0) ? cor(sv, av) : NaN
        push!(out, (z=z, n=length(sv), corr=c, mae=mean(abs.(sv .- av)),
                    bias=mean(sv .- av), simμ=mean(sv), actμ=mean(av)))
    end
    return out
end

function print_table(res; title="")
    isempty(title) || println("### $title")
    @printf("%-12s %4s %6s %7s %8s %7s %7s\n","zone","n","corr","MAE","bias","simμ","actμ")
    for r in res
        @printf("%-12s %4d %6.2f %7.1f %+8.1f %7.1f %7.1f\n",
                r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
    end
    if !isempty(res)
        @printf("AGG  zones=%d  meanMAE=%.1f  meanBias=%+.1f  medMAE=%.1f  meanCorr=%.2f\n",
                length(res), mean(r.mae for r in res), mean(r.bias for r in res),
                median(r.mae for r in res), mean(r.corr for r in res))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    cm = get(ARGS, 1, "multi_zone_eu_cal9")
    cv = parse(Int, get(ARGS, 2, "10"))
    sd = Date(get(ARGS, 3, "2026-04-01"))
    ed = Date(get(ARGS, 4, "2026-04-05"))
    mode = Symbol(get(ARGS, 5, "new"))
    zarg = get(ARGS, 6, "all")
    zones = zarg == "all" ? nothing : split(zarg, ",")
    println("EVAL clearing_mode=$cm cv=$cv $sd..$ed method=$mode")
    if mode === :both
        rn = metrics(cm, cv, sd, ed; method=:new, zones=zones)
        ro = metrics(cm, cv, sd, ed; method=:old, zones=zones)
        om = Dict(r.z => r for r in ro)
        println("### new (resolution-aware) vs old (legacy :00 match)")
        @printf("%-12s | %6s %7s %8s | %6s %7s %8s\n",
                "zone","corrN","maeN","biasN","corrO","maeO","biasO")
        for r in rn
            o = get(om, r.z, nothing)
            if o === nothing
                @printf("%-12s | %6.2f %7.1f %+8.1f | %6s %7s %8s\n",
                        r.z, r.corr, r.mae, r.bias, "-","-","-")
            else
                @printf("%-12s | %6.2f %7.1f %+8.1f | %6.2f %7.1f %+8.1f\n",
                        r.z, r.corr, r.mae, r.bias, o.corr, o.mae, o.bias)
            end
        end
        @printf("AGG new: meanMAE=%.1f meanBias=%+.1f medMAE=%.1f meanCorr=%.2f\n",
                mean(r.mae for r in rn), mean(r.bias for r in rn),
                median(r.mae for r in rn), mean(r.corr for r in rn))
        @printf("AGG old: meanMAE=%.1f meanBias=%+.1f medMAE=%.1f meanCorr=%.2f\n",
                mean(r.mae for r in ro), mean(r.bias for r in ro),
                median(r.mae for r in ro), mean(r.corr for r in ro))
    else
        print_table(metrics(cm, cv, sd, ed; method=mode, zones=zones))
    end
end
