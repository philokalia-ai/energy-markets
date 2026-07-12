# RES models v2: 100 m wind + GHI, honest lead-1/2 GFS vintages (previous-runs
# API), 40 wind cells / 20 solar cells, ridge. Benchmarks vs ENTSO-E DA forecast.
using CSV, DataFrames, Dates, Statistics, Printf, LinearAlgebra

SP = joinpath(@__DIR__)
pts(x) = eltype(x) <: DateTime ? x : DateTime.(replace.(String.(x), " " => "T"))

actual = CSV.read(joinpath(SP, "actual.csv"), DataFrame); actual.h = pts(actual.h)
dafc   = CSV.read(joinpath(SP, "da_forecast.csv"), DataFrame); dafc.h = pts(dafc.h)
wide(df, t) = sort(rename(unstack(filter(r -> r.production_type == t, df), :h, :production_type, :mw), t => :y), :h)
wnd_a = rename(wide(actual, "Wind Onshore"), :y => :wnd_act)
sol_a = rename(wide(actual, "Solar"), :y => :sol_act)
wnd_f = rename(wide(dafc, "Wind Onshore"), :y => :wnd_fc)
sol_f = rename(wide(dafc, "Solar"), :y => :sol_fc)

function sitewide(path, col)
    c = CSV.read(joinpath(SP, path), DataFrame); c.h = pts(c.h)
    sort(unstack(c[:, [:city_id, :h, col]], :h, :city_id, col), :h)
end

pc(v) = ismissing(v) ? missing : (x = v / 3.6; (x < 3 || x >= 25) ? 0.0 : (x >= 12 ? 1.0 : ((x - 3) / 9)^3))

c2(x, y) = cor(collect(Float64, x), collect(Float64, y))
mae(x, y) = mean(abs.(x .- y))

function ridge(X, y, lam)
    n, p = size(X)
    A = X' * X + lam * I(p); A[1, 1] -= lam   # don't penalize intercept
    A \ (X' * y)
end

# choose lambda on the tail of the train window
function fiteval(name, F, y, h; cap=Inf)
    tr = h .< DateTime(2026, 2, 1); va = (h .>= DateTime(2026, 2, 1)) .& (h .< DateTime(2026, 4, 1))
    te = h .>= DateTime(2026, 4, 1)
    best, bl = Inf, 0.0
    for lam in (1.0, 10.0, 100.0, 1000.0)
        b = ridge(F[tr, :], y[tr], lam)
        m = mae(clamp.(F[va, :] * b, 0.0, cap), y[va])
        m < best && ((best, bl) = (m, lam))
    end
    b = ridge(F[tr .| va, :], y[tr .| va], bl)
    pr = clamp.(F[te, :] * b, 0.0, cap)
    @printf("  %-44s OOS corr=%.3f  MAE=%6.1f MW  (λ=%g)\n", name, c2(pr, y[te]), mae(pr, y[te]), bl)
    return h[te], pr
end

# ================= WIND =================
println("=== WIND v2 (40 cells, 100 m) — ENTSO-E bench Apr–Jun: corr=0.911 MAE=256 ===")
for (path, col, tag) in [("wind_arch100.csv", :wind_speed_100m, "ERA5 100m (ceiling)"),
                         ("wind_prev100.csv", :wind_speed_100m_previous_day1, "GFS lead-1 (honest)"),
                         ("wind_prev100.csv", :wind_speed_100m_previous_day2, "GFS lead-2 (honest)")]
    w = sitewide(path, col)
    sites = [n for n in names(w) if n != "h"]
    d = dropmissing(innerjoin(innerjoin(wnd_a, wnd_f, on=:h), w, on=:h)); sort!(d, :h)
    F = Matrix{Float64}(hcat(ones(nrow(d)),
        reduce(hcat, [pc.(d[!, s]) for s in sites]),
        reduce(hcat, [d[!, s] ./ 3.6 for s in sites])))
    fiteval("$tag → actual", F, collect(Float64, d.wnd_act), d.h; cap=4500.0)
    fiteval("$tag → ENTSO-E DAfc", F, collect(Float64, d.wnd_fc), d.h; cap=4500.0)
end

# ================= SOLAR =================
println("\n=== SOLAR v2 (20 cells, GHI) — ENTSO-E bench Apr–Jun: corr=0.948 MAE=715 ===")
const LAT = 38.0 * pi / 180; const LON = 23.7
sinel(ts) = (doy = dayofyear(ts); dec = 0.409 * sin(2pi * (doy + 284) / 365);
    H = (hour(ts) + LON / 15 - 12) * 15 * pi / 180;
    max(sin(LAT) * sin(dec) + cos(LAT) * cos(dec) * cos(H), 0.0))
sol_pred_store = Dict{DateTime,Float64}()
for (path, col, tag) in [("solar_arch.csv", :shortwave_radiation, "ERA5 GHI (ceiling)"),
                         ("solar_prev.csv", :shortwave_radiation_previous_day1, "GFS lead-1 (honest)"),
                         ("solar_prev.csv", :shortwave_radiation_previous_day2, "GFS lead-2 (honest)")]
    w = sitewide(path, col)
    sites = [n for n in names(w) if n != "h"]
    d = dropmissing(innerjoin(innerjoin(sol_a, sol_f, on=:h), w, on=:h)); sort!(d, :h)
    g = [mean(skipmissing(r)) for r in eachrow(Matrix(d[:, sites]))]
    se = sinel.(d.h)
    F = hcat(ones(nrow(d)), g, se, g .* se, sqrt.(max.(g, 0.0)))
    fiteval("$tag → actual", F, collect(Float64, d.sol_act), d.h)
    hte, pr = fiteval("$tag → ENTSO-E DAfc", F, collect(Float64, d.sol_fc), d.h)
    if occursin("lead-1", tag)
        for (t, v) in zip(hte, pr); sol_pred_store[t] = v; end
    end
end

# ============ combined RES prediction for the price test (lead-1, DAfc target) ============
let w = sitewide("wind_prev100.csv", :wind_speed_100m_previous_day1)
    sites = [n for n in names(w) if n != "h"]
    d = dropmissing(innerjoin(innerjoin(wnd_a, wnd_f, on=:h), w, on=:h)); sort!(d, :h)
    F = Matrix{Float64}(hcat(ones(nrow(d)),
        reduce(hcat, [pc.(d[!, s]) for s in sites]),
        reduce(hcat, [d[!, s] ./ 3.6 for s in sites])))
    hte, wpr = fiteval("FINAL wind lead-1 → DAfc (for price test)", F, collect(Float64, d.wnd_fc), d.h; cap=4500.0)
    out = DataFrame(h=hte, wnd_pred=wpr)
    out.sol_pred = [get(sol_pred_store, t, missing) for t in out.h]
    dropmissing!(out)
    out.res_pred = out.sol_pred .+ out.wnd_pred
    CSV.write(joinpath(SP, "res_pred_v2.csv"), out)
    println("\nwrote res_pred_v2.csv: ", nrow(out), " hours")
end
