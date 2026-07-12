# Wind v3: ELETAEN farm-sited cells (124 cells, 95% of GR capacity),
# capacity-weighted fleet power-curve aggregate + per-cell terms for the top
# cells, honest lead-1/2 inputs. Compare vs v2 (correlation-picked 40 cells):
# lead-1 -> actual 0.839/365, -> DAfc 0.923/264.
using CSV, DataFrames, Dates, Statistics, Printf, LinearAlgebra

SP = joinpath(@__DIR__)
pts(x) = eltype(x) <: DateTime ? x : DateTime.(replace.(String.(x), " " => "T"))
actual = CSV.read(joinpath(SP, "actual.csv"), DataFrame); actual.h = pts(actual.h)
dafc   = CSV.read(joinpath(SP, "da_forecast.csv"), DataFrame); dafc.h = pts(dafc.h)
wide(df, t, nm) = sort(rename(unstack(filter(r -> r.production_type == t, df), :h, :production_type, :mw), t => nm), :h)
wnd_a = wide(actual, "Wind Onshore", :wnd_act)
wnd_f = wide(dafc, "Wind Onshore", :wnd_fc)

c = CSV.read(joinpath(SP, "wind_farm_prev.csv"), DataFrame)
c.h = pts(c.h)
cap = combine(groupby(c, :cell_id), :mw => first => :mw)
wtot = sum(cap.mw)
NBIG = 30   # per-cell terms for the biggest cells
bigids = sort(cap, :mw, rev=true).cell_id[1:NBIG]

pc(v) = ismissing(v) ? missing : (x = v / 3.6; (x < 3 || x >= 25) ? 0.0 : (x >= 12 ? 1.0 : ((x - 3) / 9)^3))

c2(x, y) = cor(collect(Float64, x), collect(Float64, y)); mae(x, y) = mean(abs.(x .- y))
ridge(X, y, lam) = (A = X' * X + lam * I(size(X, 2)); A[1, 1] -= lam; A \ (X' * y))

function build(vcol)
    w = sort(unstack(c[:, [:cell_id, :h, vcol]], :h, :cell_id, vcol), :h)
    ids = [parse(Int, n) for n in names(w) if n != "h"]
    caps = Dict(r.cell_id => r.mw for r in eachrow(cap))
    M = Matrix(w[:, Not(:h)])
    # capacity-weighted fleet aggregates
    P = pc.(M)
    wts = [caps[i] / wtot for i in ids]
    fleet_pc = [sum(skipmissing(P[r, :] .* wts')) for r in 1:size(M, 1)]
    fleet_v  = [sum(skipmissing((M[r, :] ./ 3.6) .* wts')) for r in 1:size(M, 1)]
    F = DataFrame(h = w.h, fpc = fleet_pc, fv = fleet_v)
    for id in bigids
        col = string(id)
        col in names(w) || continue
        F[!, "pc_$id"] = pc.(w[!, col])
        F[!, "v_$id"] = w[!, col] ./ 3.6
    end
    F
end

function fiteval(name, d, feats, y; cap_=4500.0)
    F = Matrix{Float64}(hcat(ones(nrow(d)), Matrix(d[:, feats])))
    h = d.h
    tr = h .< DateTime(2026, 2, 1); va = (h .>= DateTime(2026, 2, 1)) .& (h .< DateTime(2026, 4, 1)); te = h .>= DateTime(2026, 4, 1)
    best, bl = Inf, 1.0
    for lam in (1.0, 10.0, 100.0, 1000.0)
        b = ridge(F[tr, :], y[tr], lam)
        m = mae(clamp.(F[va, :] * b, 0.0, cap_), y[va])
        m < best && ((best, bl) = (m, lam))
    end
    b = ridge(F[tr .| va, :], y[tr .| va], bl)
    pr = clamp.(F[te, :] * b, 0.0, cap_)
    @printf("  %-42s OOS corr=%.3f  MAE=%6.1f MW (λ=%g)\n", name, c2(pr, y[te]), mae(pr, y[te]), bl)
    return d.h[te], pr
end

for (vcol, tag) in [(:v1, "lead-1"), (:v2, "lead-2")]
    Fd = build(vcol)
    d = dropmissing(innerjoin(innerjoin(wnd_a, wnd_f, on=:h), Fd, on=:h)); sort!(d, :h)
    feats_small = [:fpc, :fv]
    feats_full = [n for n in Symbol.(names(d)) if n ∉ (:h, :wnd_act, :wnd_fc)]
    fiteval("$tag fleet-aggregate only → actual", d, feats_small, collect(Float64, d.wnd_act))
    fiteval("$tag fleet + top-$NBIG cells → actual", d, feats_full, collect(Float64, d.wnd_act))
    fiteval("$tag fleet + top-$NBIG cells → DAfc", d, feats_full, collect(Float64, d.wnd_fc))
    if vcol == :v1
        hte, pr = fiteval("$tag FINAL → DAfc (save)", d, feats_full, collect(Float64, d.wnd_fc))
        CSV.write(joinpath(SP, "wnd_pred_farm.csv"), DataFrame(h=hte, wnd_pred=pr))
    end
end
