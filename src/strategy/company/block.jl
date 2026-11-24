"""Block(k_su): one all-or-nothing profile block. Thermal: flat Pmax on the forecast-best window (≥ min up) at
SRMC + (k_su·start-up + no-load × L)/(Pmax·L), k_su ≤ 1. Storage / PV+battery: the forecast schedule as one signed loop
(BLKL root; slices at 0 €/MWh: accepted iff the day's spread ≥ 0). Hydro: the forecast-optimal profile at the water
value. Retailer: one buy profile of the shiftable energy at WTP."""
struct Block <: CompanyStrategy
    k_su::Float64
    Block(k_su=1.0) = new(_k_ok(k_su))
end
label(::Block) = "block"
cost_reflective(::Block) = true
function offers(s::Block, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt)
    st, L, _ = best_window((c.F .- a.srmc) .* a.pmax .* t.dt, t.Ls, L -> fixc(L) / 1.0)
    p = a.srmc + fixc(L) / (1.0 * a.pmax * L * t.dt)
    for i in st:st+L-1; push!(o, _lo(:supply, p, a.pmax, t.z, c.day, i, c.res, "BLK:$(t.z):$(a.id)-b")); end
    return _tag(s, o)
end
function offers(s::Block, c::CompanyCtx{Storage})
    a = c.asset; dt = c.res / 60; o = MarketOrder[]
    cc, d, _ = storage_lp(a, c.F; dt=dt)
    _loop!(o, cc, d, a.zone, c.day, c.res, "BLKL:$(a.zone):$(a.id)-b")   # signed: a loop needs BLKL, not BLK
    return _tag(s, o)
end
function offers(s::Block, c::CompanyCtx{Hydro})
    a = c.asset; T = length(c.F); dt = c.res / 60; o = MarketOrder[]
    q, _ = hydro_lp(a, c.F; dt=dt)
    for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:supply, a.wv, q[i], a.zone, c.day, i, c.res, "BLK:$(a.zone):$(a.id)-b")); end
    return _tag(s, o)
end
offers(s::Block, c::CompanyCtx{PVBat}) = _tag(s, _pvbat_loops(c, [c.F], k -> "BLKL:$(c.zone):PVBAT-b"))
offers(s::Block, c::CompanyCtx{Flex}) = _tag(s, _flex_profiles(c, [c.F], k -> "BLKL:$(c.zone):FLEX-b"))

# PV+battery: one combined signed family per alternative forecast G (PV + the battery's schedule on G)
function _pvbat_loops(c::CompanyCtx{PVBat}, alts, fam)
    a = c.asset; T = length(c.F); dt = c.res / 60; z = a.zone; pv = _pv(c); o = MarketOrder[]
    seen = Set{Vector{Float64}}()
    for (k, G) in enumerate(alts)
        cc, d, _ = storage_lp(a.bat, G; dt=dt)
        net = pv .+ d .- cc
        key = round.(net, digits=3); key in seen && continue; push!(seen, key)
        for i in 1:T
            net[i] > 1e-6 && push!(o, _lo(:supply, 0.0, net[i], z, c.day, i, c.res, fam(k)))
            net[i] < -1e-6 && push!(o, _lo(:demand, 0.0, -net[i], z, c.day, i, c.res, fam(k)))
        end
    end
    return o
end
# retailer: firm/curtailable base + one buy profile at WTP per alternative forecast G
function _flex_profiles(c::CompanyCtx{Flex}, alts, fam)
    o, plan, T, dt, z = _flex_base(c)
    seen = Set{Vector{Float64}}()
    for (k, G) in enumerate(alts)
        q, _ = plan(G)
        key = round.(q, digits=3); key in seen && continue; push!(seen, key)
        for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:demand, c.asset.wtp, q[i], z, c.day, i, c.res, fam(k))); end
    end
    return o
end
