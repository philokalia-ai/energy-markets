# Wind v4: 3-model NWP ensemble (GFS + ECMWF + ICON, honest lead-1 previous-runs)
# at the ELETAEN farm cells. Baselines: single-GFS farm cells 0.841/368 (actual),
# 0.923/261 (DAfc); ENTSO-E 0.911/256 (actual).
using CSV, DataFrames, Dates, Statistics, Printf, LinearAlgebra

SP = joinpath(@__DIR__)
pts(x) = eltype(x) <: DateTime ? x : DateTime.(replace.(String.(x), " " => "T"))
actual = CSV.read(joinpath(SP, "actual.csv"), DataFrame); actual.h = pts(actual.h)
dafc   = CSV.read(joinpath(SP, "da_forecast.csv"), DataFrame); dafc.h = pts(dafc.h)
wide(df, t, nm) = sort(rename(unstack(filter(r -> r.production_type == t, df), :h, :production_type, :mw), t => nm), :h)
wnd_a = wide(actual, "Wind Onshore", :wnd_act)
wnd_f = wide(dafc, "Wind Onshore", :wnd_fc)

function load(fn, vcol)
    c = CSV.read(joinpath(SP, fn), DataFrame); c.h = pts(c.h)
    sort(unstack(c[:, [:cell_id, :h, vcol]], :h, :cell_id, vcol), :h)
end
g = load("wind_farm_prev.csv", :v1)
e = load("wind_farm_ecmwf.csv", :v1)
ic = load("wind_farm_icon.csv", :v1)
cap = combine(groupby(CSV.read(joinpath(SP, "wind_farm_prev.csv"), DataFrame), :cell_id), :mw => first => :mw)
bigids = sort(cap, :mw, rev=true).cell_id[1:30]

pc(v) = ismissing(v) ? missing : (x = v / 3.6; (x < 3 || x >= 25) ? 0.0 : (x >= 12 ? 1.0 : ((x - 3) / 9)^3))
c2(x, y) = cor(collect(Float64, x), collect(Float64, y)); mae(x, y) = mean(abs.(x .- y))
ridge(X, y, lam) = (A = X' * X + lam * I(size(X, 2)); A[1, 1] -= lam; A \ (X' * y))

# ensemble-mean per cell (rename cols to align, then average available models)
ids = [n for n in names(g) if n != "h"]
ens = DataFrame(h = g.h)
d_e = Dict(string(r.h) => i for (i, r) in enumerate(eachrow(e)))
d_i = Dict(string(r.h) => i for (i, r) in enumerate(eachrow(ic)))
for id in ids
    col = Vector{Union{Missing,Float64}}(missing, nrow(g))
    ecol = id in names(e) ? e[!, id] : nothing
    icol = id in names(ic) ? ic[!, id] : nothing
    for r in 1:nrow(g)
        vals = Float64[]
        !ismissing(g[r, id]) && push!(vals, g[r, id])
        k = string(g.h[r])
        if ecol !== nothing && haskey(d_e, k) && !ismissing(ecol[d_e[k]]); push!(vals, ecol[d_e[k]]); end
        if icol !== nothing && haskey(d_i, k) && !ismissing(icol[d_i[k]]); push!(vals, icol[d_i[k]]); end
        isempty(vals) || (col[r] = mean(vals))
    end
    ens[!, id] = col
end

wtot = sum(cap.mw); caps = Dict(string(r.cell_id) => r.mw for r in eachrow(cap))
function features(w)
    M = Matrix(w[:, Not(:h)]); P = pc.(M)
    wts = [caps[i] / wtot for i in ids]
    F = DataFrame(h = w.h,
        fpc = [sum(skipmissing(P[r, :] .* wts')) for r in 1:size(M, 1)],
        fv  = [sum(skipmissing((M[r, :] ./ 3.6) .* wts')) for r in 1:size(M, 1)])
    for id0 in bigids
        col = string(id0)
        col in names(w) || continue
        F[!, "pc_$col"] = pc.(w[!, col])
        F[!, "v_$col"] = w[!, col] ./ 3.6
    end
    F
end

function fiteval(name, d, y; save=nothing)
    feats = [n for n in Symbol.(names(d)) if n ∉ (:h, :wnd_act, :wnd_fc)]
    F = Matrix{Float64}(hcat(ones(nrow(d)), Matrix(d[:, feats])))
    h = d.h
    tr = h .< DateTime(2026, 2, 1); va = (h .>= DateTime(2026, 2, 1)) .& (h .< DateTime(2026, 4, 1)); te = h .>= DateTime(2026, 4, 1)
    best, bl = Inf, 1.0
    for lam in (1.0, 10.0, 100.0)
        b = ridge(F[tr, :], y[tr], lam)
        m = mae(clamp.(F[va, :] * b, 0.0, 4500.0), y[va])
        m < best && ((best, bl) = (m, lam))
    end
    b = ridge(F[tr .| va, :], y[tr .| va], bl)
    pr = clamp.(F[te, :] * b, 0.0, 4500.0)
    @printf("  %-40s OOS corr=%.3f  MAE=%6.1f MW (λ=%g)\n", name, c2(pr, y[te]), mae(pr, y[te]), bl)
    save !== nothing && CSV.write(joinpath(SP, save), DataFrame(h=h[te], wnd_pred=pr))
end

Fd = features(ens)
d = dropmissing(innerjoin(innerjoin(wnd_a, wnd_f, on=:h), Fd, on=:h)); sort!(d, :h)
println("rows: ", nrow(d))
fiteval("3-model ensemble → actual", d, collect(Float64, d.wnd_act))
fiteval("3-model ensemble → DAfc", d, collect(Float64, d.wnd_fc); save="wnd_pred_ens.csv")
