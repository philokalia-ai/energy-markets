#!/usr/bin/env julia
#
# Real-case validation of the eligibility RES FILL (bin/weather_res.jl +
# res_models pack). The exact counterfactual of what the fill would have done:
# predict a zone's hourly wind+solar with the committed weather→RES models, then
# compare against the ENTSO-E 14.1.D day-ahead wind/solar forecast (summed over
# production types) over the SAME hours — i.e. how close the fill is to the TSO
# forecast it stands in for.
#
#   julia --project=. test/scripts/validate_res_fill.jl                       # DE_LU,AT
#   ZONES="DE_LU,AT" VAL_START=2026-07-18 VAL_END=2026-07-24 \
#     julia --project=. test/scripts/validate_res_fill.jl
#
# Weather comes from the open-meteo forecast API (past_days coverage), exactly as
# the production fill fetches it. MAPE is computed on hours where the TSO forecast
# is non-trivial (> 5% of the zone's max, so near-zero solar nights don't blow it
# up); corr and MAE use all paired hours.

using Euphemia, Dates, Statistics, Printf

include(joinpath(@__DIR__, "..", "..", "bin", "weather_res.jl"))

const V_ZONES = [String(strip(s)) for s in split(get(ENV, "ZONES", "DE_LU,AT"), ",") if !isempty(strip(s))]
const VAL_START = Date(get(ENV, "VAL_START", "2026-07-18"))
const VAL_END = Date(get(ENV, "VAL_END", "2026-07-24"))

"""
Hour → 14.1.D day-ahead total variable-RES forecast MW, resolution-aware.
Wind+solar is a POWER level (MW): per raw timestamp we SUM over production types
(instantaneous total RES), then AVERAGE those totals within each hour — so a
PT15M zone (DE_LU/AT publish 4 quarters/hour) is not 4×-inflated by a naive
hourly SUM. Matches how `predict_res` represents an hourly MW level.
"""
function tso_res_forecast(zone, t0::Date, t1::Date)
    df = Euphemia.sql2df_with_retry("""
        SELECT date_trunc('hour', ts) AS h, AVG(total) AS v
        FROM (
            SELECT (date_time_utc AT TIME ZONE 'UTC') AS ts,
                   SUM(day_ahead_generation_forecast_mw) AS total
            FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
              AND area_map_code = \$3
              AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
              AND day_ahead_generation_forecast_mw IS NOT NULL
            GROUP BY 1
        ) q
        GROUP BY 1
    """, [t0, t1, zone])
    return Dict(DateTime(r.h) => Float64(r.v) for r in eachrow(df) if !ismissing(r.v))
end

function metrics(p, a; mape_floor=0.0)
    n = length(a)
    n == 0 && return (n=0, mae=NaN, mape=NaN, corr=NaN)
    mae = mean(abs.(p .- a))
    keep = [i for i in 1:n if a[i] > mape_floor]
    mape = isempty(keep) ? NaN : 100 * mean(abs.(p[i] - a[i]) / a[i] for i in keep)
    corr = (n >= 3 && std(p) > 0 && std(a) > 0) ? cor(p, a) : NaN
    return (n=n, mae=mae, mape=mape, corr=corr)
end

function main()
    pack = load_res_models()
    println("RES-FILL VALIDATION  pack=$(default_res_models_path())  " *
            "window $VAL_START..$VAL_END  zones=$(join(V_ZONES, ","))")
    println("(model weather = open-meteo forecast API, same as production fill; " *
            "benchmark = ENTSO-E 14.1.D day-ahead wind+solar forecast)\n")
    @printf("%-7s %6s | %-30s\n", "zone", "nh", "MODEL wind+solar vs TSO 14.1.D")
    @printf("%-7s %6s | %8s %8s %6s\n", "", "", "MAE(MW)", "MAPE%", "corr")
    println("-"^54)

    hours = collect(DateTime(VAL_START):Hour(1):DateTime(VAL_END) + Hour(23))
    dates = collect(VAL_START:Day(1):VAL_END)
    for zone in V_ZONES
        zm = get(pack["zones"], zone, nothing)
        if zm === nothing
            println("$zone: not in RES pack — not fillable"); continue
        end
        cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cells"]]
        weather = fetch_weather(cells, dates)
        pred = predict_res(pack, zone, hours, weather)
        tso = tso_res_forecast(zone, VAL_START, VAL_END)
        common = sort([h for h in keys(pred) if haskey(tso, h)])
        if isempty(common)
            println("$zone: no overlapping TSO 14.1.D hours in window"); continue
        end
        pv = [pred[h] for h in common]; tv = [tso[h] for h in common]
        floor_mw = 0.05 * maximum(tv)
        m = metrics(pv, tv; mape_floor=floor_mw)
        @printf("%-7s %6d | %8.0f %8.1f %6.3f\n", zone, m.n, m.mae, m.mape, m.corr)
    end
end

main()
