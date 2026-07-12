# Weather -> RES prediction skill study (GR, 2025-07-01..2026-06-30).
# Q: can silentech weather predict solar/wind well enough to replace the
# late-arriving ENTSO-E DA forecasts?  Benchmark = ENTSO-E DA forecast accuracy.
using CSV, DataFrames, Dates, Statistics, Printf

SP = joinpath(@__DIR__)
actual = CSV.read(joinpath(SP, "actual.csv"), DataFrame)
dafc   = CSV.read(joinpath(SP, "da_forecast.csv"), DataFrame)
wm     = CSV.read(joinpath(SP, "weather_meas.csv"), DataFrame)
wf     = CSV.read(joinpath(SP, "weather_fcst.csv"), DataFrame)

wide(df, val) = unstack(df, :h, :production_type, val)
a = rename(wide(actual, :mw), "Solar" => :sol_act, "Wind Onshore" => :wnd_act)
f = rename(wide(dafc, :mw), "Solar" => :sol_fc, "Wind Onshore" => :wnd_fc)
rename!(wm, :h => :h); rename!(wf, Dict(:wind_avg=>:fwind_avg, :wind_p75=>:fwind_p75, :wind_p90=>:fwind_p90, :temp_avg=>:ftemp_avg))

for t in (a, f, wm, wf)
    t.h = DateTime.(String.(t.h), dateformat"yyyy-mm-dd HH:MM:SS")
end
d = innerjoin(a, f, on=:h)
d = innerjoin(d, wm, on=:h)
d = leftjoin(d, wf, on=:h)
sort!(d, :h)
dropmissing!(d, [:sol_act, :wnd_act, :sol_fc, :wnd_fc, :rad_avg, :wind_avg])
println("joined rows: ", nrow(d))

# --- solar elevation at GR centroid (physical sunrise/sunset feature) ---
const LAT = 38.0 * pi/180; const LON = 23.7
function sinel(ts::DateTime)
    doy = dayofyear(ts)
    dec = 0.409 * sin(2pi * (doy + 284) / 365)
    solt = hour(ts) + minute(ts)/60 + LON/15          # approx solar time
    H = (solt - 12) * 15 * pi/180
    s = sin(LAT)*sin(dec) + cos(LAT)*cos(dec)*cos(H)
    return max(s, 0.0)
end
d.sinel = sinel.(d.h)
d.trend = [Dates.value(Date(ts) - Date(2025,7,1)) / 365.0 for ts in d.h]

c2(x,y) = cor(collect(Float64, x), collect(Float64, y))
mae(x,y) = mean(abs.(x .- y))
ols(X, y) = X \ y

# time-based split: train Jul..Mar, test Apr..Jun (also swapped, reported)
istest = d.h .>= DateTime(2026,4,1)
function evalmodel(name, X, y, target)
    Xtr, ytr = X[.!istest, :], y[.!istest]
    Xte, yte = X[istest, :], y[istest]
    b = ols(Xtr, ytr)
    pr = max.(Xte * b, 0.0)
    @printf("  %-38s  OOS corr=%.3f  MAE=%6.1f MW\n", name, c2(pr, yte), mae(pr, yte))
    return pr
end

println("\n=== BENCHMARK: ENTSO-E DA forecast vs actual (test window Apr-Jun 2026) ===")
te = d[istest, :]
@printf("  solar: corr=%.3f MAE=%.1f MW   wind: corr=%.3f MAE=%.1f MW\n",
    c2(te.sol_fc, te.sol_act), mae(te.sol_fc, te.sol_act),
    c2(te.wnd_fc, te.wnd_act), mae(te.wnd_fc, te.wnd_act))
@printf("  full year — solar corr=%.3f MAE=%.1f | wind corr=%.3f MAE=%.1f\n",
    c2(d.sol_fc, d.sol_act), mae(d.sol_fc, d.sol_act),
    c2(d.wnd_fc, d.wnd_act), mae(d.wnd_fc, d.wnd_act))

println("\n=== SOLAR (inputs: ERA5 measure radiation — weather-error-free ceiling) ===")
n = nrow(d); one_ = ones(n)
evalmodel("S1: rad only",                hcat(one_, d.rad_avg), d.sol_act, :sol)
evalmodel("S2: rad + sinel",             hcat(one_, d.rad_avg, d.sinel), d.sol_act, :sol)
evalmodel("S3: rad + sinel + rad*trend", hcat(one_, d.rad_avg, d.sinel, d.rad_avg .* d.trend), d.sol_act, :sol)
evalmodel("S4: S3 + rad_p90 + rad*sinel",hcat(one_, d.rad_avg, d.sinel, d.rad_avg .* d.trend, d.rad_p90, d.rad_avg .* d.sinel), d.sol_act, :sol)
println("  -- same, target = ENTSO-E DA forecast (the price-relevant series):")
evalmodel("S3f: rad+sinel+rad*trend -> DAfc", hcat(one_, d.rad_avg, d.sinel, d.rad_avg .* d.trend), d.sol_fc, :sol)

println("\n=== WIND (inputs: ERA5 measure wind — ceiling) ===")
v, p75, p90 = d.wind_avg, d.wind_p75, d.wind_p90
evalmodel("W1: v_avg",                   hcat(one_, v), d.wnd_act, :wnd)
evalmodel("W2: v,v2,v3 (avg)",           hcat(one_, v, v.^2, v.^3), d.wnd_act, :wnd)
evalmodel("W3: + p75,p90 cubics",        hcat(one_, v, v.^2, v.^3, p75, p75.^3, p90, p90.^3), d.wnd_act, :wnd)
println("  -- target = ENTSO-E DA wind forecast:")
evalmodel("W3f: -> DAfc",                hcat(one_, v, v.^2, v.^3, p75, p75.^3, p90, p90.^3), d.wnd_fc, :wnd)

println("\n=== WIND with TRUE FORECAST inputs (city_forecast, real ex-ante) ===")
df2 = dropmissing(d, [:fwind_avg, :fwind_p75, :fwind_p90])
ist2 = df2.h .>= DateTime(2026,4,1)
println("  rows with forecast weather: ", nrow(df2), " (test: ", sum(ist2), ")")
fv, fp75, fp90 = df2.fwind_avg, df2.fwind_p75, df2.fwind_p90
one2 = ones(nrow(df2))
let X = hcat(one2, fv, fv.^2, fv.^3, fp75, fp75.^3, fp90, fp90.^3), y = df2.wnd_act
    b = ols(X[.!ist2,:], y[.!ist2]); pr = max.(X[ist2,:]*b, 0.0)
    @printf("  W3 on fcst weather:  OOS corr=%.3f  MAE=%6.1f MW\n", c2(pr, y[ist2]), mae(pr, y[ist2]))
    @printf("  (ENTSO-E wind fc on same rows: corr=%.3f MAE=%.1f)\n",
        c2(df2.wnd_fc[ist2], y[ist2]), mae(df2.wnd_fc[ist2], y[ist2]))
end
# how close is forecast weather to measured weather? (weather forecast skill)
let m = dropmissing(d, [:fwind_avg])
    @printf("\n  corr(fcst wind_avg, ERA5 wind_avg) = %.3f   (weather-forecast fidelity)\n",
        c2(m.fwind_avg, m.wind_avg))
end

# capacity context
println()
@printf("solar actual: max=%.0f mean=%.0f | wind actual: max=%.0f mean=%.0f MW\n",
    maximum(d.sol_act), mean(d.sol_act), maximum(d.wnd_act), mean(d.wnd_act))
