# Price-level test: GR :merit_order with our weather-based RES prediction
# (renewable_modifier) vs the production ENTSO-E-forecast baseline.
# 12 OOS days across Apr-Jun 2026. Predictions are strictly out-of-sample.
using Euphemia, CSV, DataFrames, Dates, Statistics, Printf

SP = joinpath(@__DIR__)
pred = CSV.read(joinpath(SP, "res_pred_oos.csv"), DataFrame)
eltype(pred.h) <: DateTime || (pred.h = DateTime.(String.(pred.h), dateformat"yyyy-mm-ddTHH:MM:SS"))
PRED = Dict(Dates.format(r.h, "yyyymmdd-HHMM") => r.res_pred for r in eachrow(pred))
hourkey(ts::String) = ts[1:9] * ts[10:11] * "00"
resmod = (ts, mw) -> get(PRED, hourkey(ts), mw)

DAYS = [Date(2026,4,3), Date(2026,4,10), Date(2026,4,17), Date(2026,4,24),
        Date(2026,5,1), Date(2026,5,8), Date(2026,5,15), Date(2026,5,22),
        Date(2026,6,5), Date(2026,6,12), Date(2026,6,19), Date(2026,6,26)]

function actual_prices(day)
    df = Euphemia.sql2df("""
        WITH d AS (SELECT DISTINCT ON (date_time_utc) date_time_utc, price_currency_mwh p
          FROM entsoe.energy_prices
          WHERE map_code='GR' AND contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
            AND (date_time_utc AT TIME ZONE 'UTC')::date = \$1
          ORDER BY date_time_utc,(CASE WHEN sequence ~ '^\\s*\\d+\\s*\$' THEN trim(sequence)::int ELSE NULL END) DESC NULLS LAST)
        SELECT to_char(date_trunc('hour', date_time_utc AT TIME ZONE 'UTC'), 'YYYYMMDD-HH24MI') k, AVG(p) p
        FROM d GROUP BY 1 ORDER BY 1""", [string(day)])
    Dict(String(r.k) => Float64(r.p) for r in eachrow(df))
end

hourly(prices) = begin  # average sim slots into hours
    acc = Dict{String,Vector{Float64}}()
    for (ts, p) in prices
        push!(get!(acc, hourkey(ts), Float64[]), p)
    end
    Dict(k => mean(v) for (k, v) in acc)
end

allb, allw, alla = Float64[], Float64[], Float64[]
c2(x,y) = (std(x)==0||std(y)==0) ? NaN : cor(x,y)
println("day          base_corr base_MAE  wthr_corr wthr_MAE")
for day in DAYS
    base = hourly(generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=false))
    wthr = hourly(generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=false,
                                          renewable_modifier=resmod))
    act = actual_prices(day)
    ks = sort(collect(intersect(keys(base), keys(wthr), keys(act))))
    isempty(ks) && (println("$day  NO OVERLAP"); continue)
    b = [base[k] for k in ks]; w = [wthr[k] for k in ks]; a = [act[k] for k in ks]
    append!(allb, b); append!(allw, w); append!(alla, a)
    @printf("%s     %.3f   %6.1f     %.3f   %6.1f\n", day,
        c2(b,a), mean(abs.(b.-a)), c2(w,a), mean(abs.(w.-a)))
end
println("-"^58)
@printf("POOLED (%d h)  base: corr=%.3f MAE=%.1f   weather-RES: corr=%.3f MAE=%.1f\n",
    length(alla), c2(allb,alla), mean(abs.(allb.-alla)), c2(allw,alla), mean(abs.(allw.-alla)))
