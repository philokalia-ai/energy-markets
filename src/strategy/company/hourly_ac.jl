"""HourlyAC(k_su): thermal, Pmax every period at average cost: SRMC + (k_su·start-up + no-load × L)/(Pmax·L), L = the
forecast-best run length (≥ min up). k_su ≤ 1 (share of the start-up recovered; calibrated on calibration days).
Start-up/no-load: FuelTypeParameters (startup_cost_multiplier, no_load_cost_fraction), see archetypes.md."""
struct HourlyAC <: CompanyStrategy
    k_su::Float64
    HourlyAC(k_su=1.0) = new(_k_ok(k_su))
end
label(::HourlyAC) = "hourly_ac"
function offers(s::HourlyAC, c::CompanyCtx{Thermal})
    t = _th(c); a = t.a; o = MarketOrder[]; fixc = _fixc(a, s.k_su, t.dt)
    st, L, _ = best_window((c.F .- a.srmc) .* a.pmax .* t.dt, t.Ls, fixc)
    p = a.srmc + fixc(L) / (a.pmax * L * t.dt)
    for i in 1:t.T; push!(o, _so(:supply, p, a.pmax, t.z, c.day, i, c.res)); end
    return _tag(s, o)
end
