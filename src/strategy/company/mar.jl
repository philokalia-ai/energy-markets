"""MarFull(k_su, r): a minimum-acceptance-ratio block, COST-REFLECTIVE. Thermal: as `Block`, MAR = Pmin/Pmax (`r`
ignored), fixed costs spread at full acceptance (= average cost when fully accepted, below it when cut back). Hydro:
the forecast-optimal profile at the water value with MAR `r` (round 1: 0.5)."""
struct MarFull <: CompanyStrategy
    k_su::Float64
    r::Float64
    MarFull(k_su=1.0, r=NaN) = new(_k_ok(k_su), Float64(r))
end
label(::MarFull) = "mar_full"
cost_reflective(::MarFull) = true
function offers(s::MarFull, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt)
    r = a.pmin / a.pmax
    st, L, _ = best_window((c.F .- a.srmc) .* a.pmax .* t.dt, t.Ls, L -> fixc(L) / 1.0)
    p = a.srmc + fixc(L) / (1.0 * a.pmax * L * t.dt)
    fam = "BLKM:$(t.z):$(a.id)-mf:mar=$(round(r, digits=4))"
    for i in st:st+L-1; push!(o, _lo(:supply, p, a.pmax, t.z, c.day, i, c.res, fam)); end
    return _tag(s, o)
end
function offers(s::MarFull, c::CompanyCtx{Hydro})
    a = c.asset; T = length(c.F); dt = c.res / 60; o = MarketOrder[]
    q, _ = hydro_lp(a, c.F; dt=dt)
    fam = "BLKM:$(a.zone):$(a.id)-m:mar=$(s.r)"
    for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:supply, a.wv, q[i], a.zone, c.day, i, c.res, fam)); end
    return _tag(s, o)
end

"""MarMin(k_su): thermal MAR block whose price recovers the fixed costs at the MINIMUM ratio (Pmin/Pmax):
SRMC + (k_su·start-up + no-load × L)/(MAR·Pmax·L). **Not cost-reflective** (above average cost when fully accepted;
flagged in round 1). Kept only to reproduce round-1 rows; `score` refuses it unless `allow_flagged=true`."""
struct MarMin <: CompanyStrategy
    k_su::Float64
    MarMin(k_su=1.0) = new(_k_ok(k_su))
end
label(::MarMin) = "mar"
cost_reflective(::MarMin) = false
function offers(s::MarMin, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt)
    r = a.pmin / a.pmax
    st, L, _ = best_window((c.F .- a.srmc) .* a.pmax .* t.dt, t.Ls, L -> fixc(L) / r)
    p = a.srmc + fixc(L) / (r * a.pmax * L * t.dt)
    fam = "BLKM:$(t.z):$(a.id)-m:mar=$(round(r, digits=4))"
    for i in st:st+L-1; push!(o, _lo(:supply, p, a.pmax, t.z, c.day, i, c.res, fam)); end
    return _tag(s, o)
end
