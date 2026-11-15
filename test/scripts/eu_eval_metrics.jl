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
#   EVAL_Q15=true julia --project=. test/scripts/eu_eval_metrics.jl <cm> <cv> <start> <end>
#       (opt-in native 15-minute columns, see `metrics(...; q15=true)`)

using Euphemia, Dates, Statistics, Printf, DataFrames
# Pure q15 helpers (`q15_forecast`, `score_q15`) live in bin/forecast_common.jl;
# the bin/ scripts include it before this file, standalone use loads it here.
isdefined(@__MODULE__, :score_q15) ||
    include(joinpath(@__DIR__, "..", "..", "bin", "forecast_common.jl"))

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
Non-SDAC day-ahead `sequence`s to drop from the NATIVE 15-MIN target, per zone.
AT and DE_LU carry two day-ahead auctions in `entsoe.energy_prices`. Sequence 2
is the early EXAA auction, not SDAC. In the read-only 2026-11-15 extract,
Oct 15-Nov 13, latest row per zone/time/sequence/resolution: AT sequence 1
equals CZ in 279/2,880 quarters, sequence 2 in 0/2,876; DE_LU sequence 1 equals
NL in 339/2,880, sequence 2 in 1/2,880. Monthly 2022-12..2026-11, sequence 1
matches its coupled neighbour in roughly 2-48 % of MTUs, sequence 2 in at most
about 0.2 %. Sequence 2's update stamp is about 11:10 local time (an ingestion
stamp, not an authenticated exchange publication time), ahead of the SDAC batch.
The #424 review confirmed this independently. DK1/DK2 sequence 2 rows are
float-noise copies of the same SDAC price. The hourly score's
`resolution_aware_actuals` (highest sequence) is deliberately left unchanged.
Flip an entry to "1" to target the other auction.
"""
const Q15_NON_SDAC_SEQUENCE = Dict("AT" => "2", "DE_LU" => "2")

"""
    native_q15_actuals(sd, ed; contract="Day-ahead") -> DataFrame(z, t, act, res)

Day-ahead actuals at their NATIVE resolution for the 15-minute score: SDAC only
(`Q15_NON_SDAC_SEQUENCE` dropped), latest revision (`update_time_utc`) per
(zone, interval start, resolution code), UTC interval starts over the UTC days
sd..ed. `res` is the ENTSO-E resolution code (PT15M / PT30M / PT60M); only PT15M
rows are scored (`score_q15`), so PT60M/PT30M zones stay out of the 15-min mask.
"""
function native_q15_actuals(sd::Date, ed::Date; contract::String="Day-ahead")
    excl = join(["(map_code = '$z' AND trim(COALESCE(sequence, '')) = '$q')"
                 for (z, q) in sort(collect(Q15_NON_SDAC_SEQUENCE))], " OR ")
    Euphemia.sql2df("""
        SELECT DISTINCT ON (map_code, date_time_utc, resolution_code)
               map_code AS z, (date_time_utc AT TIME ZONE 'UTC') AS t,
               price_currency_mwh AS act, trim(resolution_code) AS res
        FROM entsoe.energy_prices
        WHERE contract_type = \$1 AND area_type_code LIKE 'BZN%'
          AND price_currency_mwh IS NOT NULL
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
          $(isempty(excl) ? "" : "AND NOT ($excl)")
        ORDER BY map_code, date_time_utc, resolution_code, update_time_utc DESC
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
    metrics(cm, cv, sd, ed; method=:new, zones=nothing, q15=false) -> Vector of NamedTuple

Per-zone (n, corr, mae, bias, simμ, actμ). Joins sim to actuals on (zone, hour).
`q15=true` (opt-in; CLI: EVAL_Q15=true) adds the native 15-minute view pooled
over the window: the sim replicated x4 (or used as is when the clear is natively
quarter-hourly) against native PT15M SDAC actuals (`native_q15_actuals`,
`score_q15` from bin/forecast_common.jl) — n_q15, mae_q15, bias_q15, corr_q15,
shape_floor_q15, q15_res ("PT60M" = replicated hourly, "PT15M" = native). A zone
without native PT15M actuals gets nothing for these fields. The hourly fields
are computed exactly as before.
"""
function metrics(cm::String, cv::Int, sd::Date, ed::Date;
                 method::Symbol=:new, zones=nothing, q15::Bool=false)
    sim = sim_prices(cm, cv, sd, ed)
    a15 = q15 ? native_q15_actuals(sd, ed) : nothing
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
        r = (z=z, n=length(sv), corr=c, mae=mean(abs.(sv .- av)),
             bias=mean(sv .- av), simμ=mean(sv), actμ=mean(av))
        if q15
            fq, res = q15_forecast(DateTime.(sub.t), Float64.(sub.sim))
            za = a15[String.(a15.z) .== z, :]
            q = score_q15(fq, za.t, za.act, za.res)
            r = merge(r, (n_q15=q.n_q15, mae_q15=q.mae_q15, bias_q15=q.bias_q15,
                          corr_q15=q.corr_q15, shape_floor_q15=q.shape_floor_q15, q15_res=res))
        end
        push!(out, r)
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
    any(r -> haskey(r, :mae_q15), res) && print_q15_table(res)
end

"The opt-in native 15-minute columns (EVAL_Q15=true); zones without native PT15M actuals print '-'."
function print_q15_table(res)
    f(x, d=1) = x === nothing ? "-" : @sprintf("%.*f", d, x)
    println("### native 15-min (PT15M SDAC actuals; forecast replicated x4 unless q15_res=PT15M)")
    @printf("%-12s %5s %7s %8s %6s %7s %6s\n", "zone", "n_q15", "MAE15", "bias15", "corr15", "shape", "res")
    for r in res
        @printf("%-12s %5d %7s %8s %6s %7s %6s\n", r.z, r.n_q15, f(r.mae_q15), f(r.bias_q15),
                f(r.corr_q15, 2), f(r.shape_floor_q15), r.q15_res)
    end
    ok = [r for r in res if r.mae_q15 !== nothing]
    isempty(ok) || @printf("AGG15 zones=%d (native PT15M only)  meanMAE15=%.1f  meanShape=%.1f  (hourly meanMAE on the same zones %.1f)\n",
                           length(ok), mean(r.mae_q15 for r in ok),
                           mean(something(r.shape_floor_q15, NaN) for r in ok), mean(r.mae for r in ok))
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
        print_table(metrics(cm, cv, sd, ed; method=mode, zones=zones,
                            q15=lowercase(get(ENV, "EVAL_Q15", "false")) == "true"))
    end
end
