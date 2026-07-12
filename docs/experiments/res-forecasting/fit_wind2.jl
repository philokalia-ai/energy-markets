# Multi-site wind model: top-20 distinct grid cells, per-site power-curve
# features, OLS weights. Evaluated OOS (Apr-Jun 2026) on measure AND forecast
# weather inputs, vs the ENTSO-E DA wind forecast benchmark.
using CSV, DataFrames, Dates, Statistics, Printf

SP = joinpath(@__DIR__)
parse_ts(t) = DateTime.(String.(t), dateformat"yyyy-mm-dd HH:MM:SS")
actual = CSV.read(joinpath(SP, "actual.csv"), DataFrame)
dafc   = CSV.read(joinpath(SP, "da_forecast.csv"), DataFrame)
actual.h = parse_ts(actual.h); dafc.h = parse_ts(dafc.h)
wa = rename(unstack(filter(r -> r.production_type == "Wind Onshore", actual), :h, :production_type, :mw), "Wind Onshore" => :wnd_act)
wf = rename(unstack(filter(r -> r.production_type == "Wind Onshore", dafc), :h, :production_type, :mw), "Wind Onshore" => :wnd_fc)

# power curve on 10m km/h: scale to hub ~x1.35, curve cut-in 3 m/s, rated 12, cut-out 25
function pcurve(v_kmh)
    ismissing(v_kmh) && return missing
    v = v_kmh / 3.6 * 1.35
    v < 3 && return 0.0; v >= 25 && return 0.0
    v >= 12 && return 1.0
    return ((v - 3) / 9)^3
end

function sitewide(path)
    c = CSV.read(path, DataFrame); c.h = parse_ts(c.h)
    w = unstack(c, :h, :city_id, :v)
    sort!(w, :h)
    return w
end
cm = sitewide(joinpath(SP, "cells_meas.csv"))
cf = sitewide(joinpath(SP, "cells_fcst.csv"))
sites = [n for n in names(cm) if n != "h"]
println("sites: ", length(sites))

c2(x,y) = cor(collect(Float64,x), collect(Float64,y)); mae(x,y) = mean(abs.(x .- y))

function evalwind(cells, label)
    d = innerjoin(innerjoin(wa, wf, on=:h), cells, on=:h)
    dropmissing!(d)
    sort!(d, :h)
    istest = d.h .>= DateTime(2026,4,1)
    # features: per-site pcurve + per-site raw v  (+ intercept)
    F = hcat(ones(nrow(d)),
             reduce(hcat, [pcurve.(d[!, s]) for s in sites]),
             reduce(hcat, [d[!, s] for s in sites]))
    F = Matrix{Float64}(F)
    y = collect(Float64, d.wnd_act)
    b = F[.!istest, :] \ y[.!istest]
    pr = clamp.(F[istest, :] * b, 0.0, 4500.0)
    yte = y[istest]
    @printf("%-34s rows=%5d  OOS corr=%.3f  MAE=%6.1f MW\n", label, nrow(d), c2(pr, yte), mae(pr, yte))
    @printf("%-34s                ENTSO-E bench: corr=%.3f  MAE=%6.1f MW\n", "",
        c2(d.wnd_fc[istest], yte), mae(d.wnd_fc[istest], yte))
    return d, istest, pr
end

println("=== multi-site wind, ERA5 measure inputs (weather-error-free) ===")
evalwind(cm, "20 cells, pcurve+v OLS (measure)")
println("\n=== multi-site wind, TRUE forecast inputs (real ex-ante) ===")
d2, ist2, pr2 = evalwind(cf, "20 cells, pcurve+v OLS (forecast)")

# also: target = ENTSO-E DA forecast (predict the price-relevant series)
let d = innerjoin(innerjoin(wa, wf, on=:h), cf, on=:h)
    dropmissing!(d); sort!(d, :h)
    istest = d.h .>= DateTime(2026,4,1)
    F = Matrix{Float64}(hcat(ones(nrow(d)),
        reduce(hcat, [pcurve.(d[!, s]) for s in sites]),
        reduce(hcat, [d[!, s] for s in sites])))
    y = collect(Float64, d.wnd_fc)
    b = F[.!istest, :] \ y[.!istest]
    pr = clamp.(F[istest, :] * b, 0.0, 4500.0)
    @printf("\npredict ENTSO-E wind DAfc from fcst weather: OOS corr=%.3f MAE=%.1f MW\n",
        c2(pr, y[istest]), mae(pr, y[istest]))
end
