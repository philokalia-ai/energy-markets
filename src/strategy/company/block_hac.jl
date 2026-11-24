"""BlockHAC(k_su): thermal `Block` on the forecast-best window + Pmax offered hourly at the SAME average-cost price in
every other period, so no available hour is left unoffered (the large-bidder remedy, round-1 REPORT §3)."""
struct BlockHAC <: CompanyStrategy
    k_su::Float64
    BlockHAC(k_su=1.0) = new(_k_ok(k_su))
end
label(::BlockHAC) = "block_hac"
function offers(s::BlockHAC, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt)
    st, L, _ = best_window((c.F .- a.srmc) .* a.pmax .* t.dt, t.Ls, fixc)
    p = a.srmc + fixc(L) / (a.pmax * L * t.dt)
    for i in st:st+L-1; push!(o, _lo(:supply, p, a.pmax, t.z, c.day, i, c.res, "BLK:$(t.z):$(a.id)-b")); end
    for i in 1:t.T
        st <= i <= st + L - 1 && continue
        push!(o, _so(:supply, p, a.pmax, t.z, c.day, i, c.res))
    end
    return _tag(s, o)
end
