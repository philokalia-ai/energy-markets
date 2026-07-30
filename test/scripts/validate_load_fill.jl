#!/usr/bin/env julia
#
# Real-case validation of the eligibility LOAD FILL (bin/weather_load.jl +
# bin/load_models_v1.json). This is the exact counterfactual of what the fill
# would have done: predict the zones that went missing on the daily run with the
# committed model, then compare against (a) the realized actual load
# (entsoe.actual_total_load, ground truth) and (b) the TSO day-ahead forecast
# (entsoe.day_ahead_total_load_forecast) over the SAME hours.
#
# Both series are OUT OF SAMPLE: the pack trains through TRAIN_END (2026-06-30),
# so a July window is held out.
#
#   julia --project=. test/scripts/validate_load_fill.jl                       # LT,SI,CH, 2026-07-01..2026-07-24
#   ZONES="LT,SI,CH" VAL_START=2026-07-01 VAL_END=2026-07-24 \
#     julia --project=. test/scripts/validate_load_fill.jl
#
# Weather at predict time comes from the open-meteo forecast API (past_days
# coverage), exactly as the production fill would fetch it — no ERA5/actuals.

using Euphemia, Dates, Statistics, Printf

include(joinpath(@__DIR__, "..", "..", "bin", "weather_load.jl"))

const V_ZONES = let z = [String(strip(s)) for s in split(get(ENV, "ZONES", "LT,SI,CH"), ",") if !isempty(strip(s))]
    z
end
const VAL_START = Date(get(ENV, "VAL_START", "2026-07-01"))
const VAL_END = Date(get(ENV, "VAL_END", "2026-07-24"))

"Hour → actual load MW (deduped hourly)."
function actual_load(zone, t0::Date, t1::Date)
    df = Euphemia.sql2df_with_retry("""
        SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
               AVG(total_load_mw) AS v
        FROM entsoe.actual_total_load
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = \$3 AND total_load_mw IS NOT NULL
          AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
        GROUP BY 1
    """, [t0, t1, zone])
    return Dict(DateTime(r.h) => Float64(r.v) for r in eachrow(df) if !ismissing(r.v))
end

"Hour → TSO day-ahead forecast MW (deduped hourly)."
function tso_forecast(zone, t0::Date, t1::Date)
    df = Euphemia.sql2df_with_retry("""
        SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
               AVG(total_load_mw) AS v
        FROM entsoe.day_ahead_total_load_forecast
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = \$3 AND total_load_mw IS NOT NULL
          AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
        GROUP BY 1
    """, [t0, t1, zone])
    return Dict(DateTime(r.h) => Float64(r.v) for r in eachrow(df) if !ismissing(r.v))
end

metrics(p, a) = (n = length(a);
    n == 0 ? (n=0, mae=NaN, mape=NaN, corr=NaN) :
    (n=n, mae=mean(abs.(p .- a)), mape=100 * mean(abs.(p .- a) ./ a),
     corr=(n >= 3 && std(p) > 0 && std(a) > 0) ? cor(p, a) : NaN))

function main()
    pack = load_load_models()
    pack === nothing && error("no load pack — run bin/fit_load_models.jl")
    println("LOAD-FILL VALIDATION  pack train=$(get(pack,"train_window","?"))  " *
            "window $VAL_START..$VAL_END  zones=$(join(V_ZONES, ","))")
    println("(model weather = open-meteo forecast API, same as production fill; " *
            "series are out of sample vs the pack train window)\n")

    @printf("%-6s %6s | %-22s | %-22s | %-14s\n", "zone", "nh",
            "MODEL vs actual", "TSO vs actual", "MODEL vs TSO")
    @printf("%-6s %6s | %6s %6s %5s | %6s %6s %5s | %6s %5s\n", "", "",
            "MAE", "MAPE%", "corr", "MAE", "MAPE%", "corr", "MAE", "corr")
    println("-"^80)

    hours = collect(DateTime(VAL_START):Hour(1):DateTime(VAL_END) + Hour(23))
    fetch_dates = collect((VAL_START - Day(2)):Day(1):VAL_END)
    for zone in V_ZONES
        zm = get(pack["zones"], zone, nothing)
        zm === nothing && (println("$zone: not in pack"); continue)
        cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cities"]]
        # Past validation window: admissible D-1 vintage (previous_day1) —
        # not the plain forecast API's fresher recent-run data.
        weather = fetch_load_weather(cells, fetch_dates; vintage_lag=1)
        pred = predict_load(pack, zone, hours, weather)
        act = actual_load(zone, VAL_START, VAL_END)
        tso = tso_forecast(zone, VAL_START, VAL_END)

        common = sort([h for h in keys(pred) if haskey(act, h)])
        pv = [pred[h] for h in common]; av = [act[h] for h in common]
        m_ma = metrics(pv, av)
        # TSO vs actual on the SAME hours the TSO published
        tcom = sort([h for h in common if haskey(tso, h)])
        t_ma = length(tcom) == 0 ? (n=0, mae=NaN, mape=NaN, corr=NaN) :
               metrics([tso[h] for h in tcom], [act[h] for h in tcom])
        # model vs TSO (the fill's direct counterfactual against what it replaces)
        mt = length(tcom) == 0 ? (n=0, mae=NaN, corr=NaN) :
             metrics([pred[h] for h in tcom], [tso[h] for h in tcom])

        @printf("%-6s %6d | %6.0f %6.2f %5.3f | %6.0f %6.2f %5.3f | %6.0f %5.3f\n",
                zone, m_ma.n, m_ma.mae, m_ma.mape, m_ma.corr,
                t_ma.mae, t_ma.mape, t_ma.corr, mt.mae, mt.corr)
    end
end

main()
