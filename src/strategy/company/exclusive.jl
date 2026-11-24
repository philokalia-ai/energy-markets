"""Exclusive(k_su, nx): an exclusive group (at most one member accepted). Thermal: nx flat blocks, the forecast-best
window for nx lengths spread from min up to 24 h, each priced as `Block`. Storage / PV+battery / retailer: ≤ nx
schedules from deterministic forecast transforms (as is, ±1 h shift, 3-h and 7-h smoothing). Hydro: the same energy
spread over 50–100 % of Pmax."""
struct Exclusive <: CompanyStrategy
    k_su::Float64
    nx::Int
    Exclusive(k_su=1.0, nx=5) = new(_k_ok(k_su), Int(nx))
end
label(::Exclusive) = "exclusive"
function offers(s::Exclusive, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt)
    Lset = unique(round.(Int, range(first(t.Ls), t.T; length=s.nx)))
    for (k, L) in enumerate(Lset)
        st, _, _ = best_window((c.F .- a.srmc) .* a.pmax .* t.dt, L:L, fixc)
        p = a.srmc + fixc(L) / (a.pmax * L * t.dt)
        fam = "BLKX:$(t.z):$(a.id)-x$k:group=$(a.id)"
        for i in st:st+L-1; push!(o, _lo(:supply, p, a.pmax, t.z, c.day, i, c.res, fam)); end
    end
    return _tag(s, o)
end
function offers(s::Exclusive, c::CompanyCtx{Storage})
    a = c.asset; dt = c.res / 60; o = MarketOrder[]
    seen = Set{Vector{Float64}}()
    for (k, G) in enumerate(_alts(c.F, dt)[1:s.nx])
        cc, d, _ = storage_lp(a, G; dt=dt)
        key = round.(d .- cc, digits=3); key in seen && continue; push!(seen, key)
        _loop!(o, cc, d, a.zone, c.day, c.res, "BLKX:$(a.zone):$(a.id)-x$k:group=$(a.id)")
    end
    return _tag(s, o)
end
function offers(s::Exclusive, c::CompanyCtx{Hydro})
    a = c.asset; T = length(c.F); dt = c.res / 60; o = MarketOrder[]
    for (k, frac) in enumerate(range(0.5, 1.0; length=s.nx))     # spread: energy at frac·… of Pmax
        nper = clamp(round(Int, a.e / (a.p * frac * dt)), 1, T)
        pcap = a.e / (nper * dt)
        q, _ = hydro_lp(a, c.F; dt=dt, pcap=min(a.p, pcap))
        fam = "BLKX:$(a.zone):$(a.id)-x$k:group=$(a.id)"
        for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:supply, a.wv, q[i], a.zone, c.day, i, c.res, fam)); end
    end
    return _tag(s, o)
end
offers(s::Exclusive, c::CompanyCtx{PVBat}) =
    _tag(s, _pvbat_loops(c, _alts(c.F, c.res / 60)[1:s.nx], k -> "BLKX:$(c.zone):PVBAT-x$k:group=PVBAT"))
offers(s::Exclusive, c::CompanyCtx{Flex}) =
    _tag(s, _flex_profiles(c, _alts(c.F, c.res / 60)[1:s.nx], k -> "BLKX:$(c.zone):FLEX-x$k:group=FLEX"))
