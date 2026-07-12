# Emit hourly OOS RES predictions (Apr-Jun 2026) for the price test.
# Solar: S2 (ERA5 rad + sun elevation)  [rad stand-in: forecast table lacks radiation]
# Wind:  multi-site 20-cell pcurve+v on TRUE city_forecast inputs
# Trained strictly on Jul 2025 - Mar 2026.
using CSV, DataFrames, Dates, Statistics

SP = joinpath(@__DIR__)
parse_ts(t) = DateTime.(String.(t), dateformat"yyyy-mm-dd HH:MM:SS")
actual = CSV.read(joinpath(SP, "actual.csv"), DataFrame); actual.h = parse_ts(actual.h)
wm = CSV.read(joinpath(SP, "weather_meas.csv"), DataFrame); wm.h = parse_ts(wm.h)
wa = rename(unstack(filter(r -> r.production_type == "Wind Onshore", actual), :h, :production_type, :mw), "Wind Onshore" => :wnd_act)
sa = rename(unstack(filter(r -> r.production_type == "Solar", actual), :h, :production_type, :mw), "Solar" => :sol_act)

const LAT = 38.0 * pi/180; const LON = 23.7
function sinel(ts::DateTime)
    doy = dayofyear(ts)
    dec = 0.409 * sin(2pi * (doy + 284) / 365)
    H = (hour(ts) + LON/15 - 12) * 15 * pi/180
    max(sin(LAT)*sin(dec) + cos(LAT)*cos(dec)*cos(H), 0.0)
end

# --- solar ---
ds = dropmissing(innerjoin(sa, wm[:, [:h, :rad_avg]], on=:h))
sort!(ds, :h)
ds.sinel = sinel.(ds.h)
ist = ds.h .>= DateTime(2026,4,1)
Xs = hcat(ones(nrow(ds)), ds.rad_avg, ds.sinel)
bs = Xs[.!ist,:] \ collect(Float64, ds.sol_act[.!ist])
ds.sol_pred = max.(Xs * bs, 0.0)

# --- wind (forecast inputs) ---
function pcurve(v_kmh)
    ismissing(v_kmh) && return missing
    v = v_kmh / 3.6 * 1.35
    (v < 3 || v >= 25) && return 0.0
    v >= 12 && return 1.0
    ((v - 3) / 9)^3
end
cf = CSV.read(joinpath(SP, "cells_fcst.csv"), DataFrame); cf.h = parse_ts(cf.h)
w = unstack(cf, :h, :city_id, :v); sort!(w, :h)
sites = [n for n in names(w) if n != "h"]
dw = dropmissing(innerjoin(wa, w, on=:h)); sort!(dw, :h)
istw = dw.h .>= DateTime(2026,4,1)
Fw = Matrix{Float64}(hcat(ones(nrow(dw)),
    reduce(hcat, [pcurve.(dw[!, s]) for s in sites]),
    reduce(hcat, [dw[!, s] for s in sites])))
bw = Fw[.!istw,:] \ collect(Float64, dw.wnd_act[.!istw])
dw.wnd_pred = clamp.(Fw * bw, 0.0, 4500.0)

out = innerjoin(ds[ist, [:h, :sol_pred]], dw[istw, [:h, :wnd_pred]], on=:h)
out.res_pred = out.sol_pred .+ out.wnd_pred
sort!(out, :h)
CSV.write(joinpath(SP, "res_pred_oos.csv"), out)
println("wrote ", nrow(out), " OOS prediction hours: ",
    first(out.h), " .. ", last(out.h))
