"""Linked(k_su): a linked block family. Thermal: parent = Pmin over the forecast-best window, priced
SRMC + (k_su·start-up + no-load × L)/(Pmin·L); children = (Pmax − Pmin) per period at SRMC, each accepted only with the
parent. Hydro: parent = the best half of the forecast-optimal profile at the water value, each further period a child."""
struct Linked <: CompanyStrategy
    k_su::Float64
    Linked(k_su=1.0) = new(_k_ok(k_su))
end
label(::Linked) = "linked"
function offers(s::Linked, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt); dt = t.dt; F = c.F
    val = [(F[i] - a.srmc) * a.pmin * dt + max(0.0, F[i] - a.srmc) * (a.pmax - a.pmin) * dt for i in 1:t.T]
    st, L, _ = best_window(val, t.Ls, fixc)
    pp = a.srmc + fixc(L) / (a.pmin * L * dt)
    par = "BLKL:$(t.z):$(a.id)-p"
    for i in st:st+L-1
        push!(o, _lo(:supply, pp, a.pmin, t.z, c.day, i, c.res, par))
        push!(o, _lo(:supply, a.srmc, a.pmax - a.pmin, t.z, c.day, i, c.res, "BLKL:$(t.z):$(a.id)-c$i:parent=$(a.id)-p"))
    end
    return _tag(s, o)
end
function offers(s::Linked, c::CompanyCtx{Hydro})
    a = c.asset; T = length(c.F); dt = c.res / 60; z = a.zone; o = MarketOrder[]; F = c.F
    q, _ = hydro_lp(a, F; dt=dt)
    on = sort([i for i in 1:T if q[i] > 1e-6]; by=i -> -F[i])
    npar = max(1, cld(length(on), 2))
    for (r, i) in enumerate(on)
        fam = r <= npar ? "BLKL:$z:$(a.id)-p" : "BLKL:$z:$(a.id)-c$i:parent=$(a.id)-p"
        push!(o, _lo(:supply, a.wv, q[i], z, c.day, i, c.res, fam))
    end
    return _tag(s, o)
end
