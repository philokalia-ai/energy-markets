"""HourlyOC(): hourly orders at the forecast OPPORTUNITY cost. Storage: the forecast-LP schedule as legs priced at the
LP dual μ_t (discharge μ_t/η_d, charge μ_t·η_c). Hydro: Pmax every period at water value + energy-budget dual.
PV+battery: PV at 0 €/MWh + the battery's legs. Retailer: shiftable energy bid hourly at the LP dual."""
struct HourlyOC <: CompanyStrategy end
label(::HourlyOC) = "hourly_oc"
cost_reflective(::HourlyOC) = true
function offers(s::HourlyOC, c::CompanyCtx{Storage})
    a = c.asset; T = length(c.F); dt = c.res / 60; z = a.zone; o = MarketOrder[]
    cc, d, μ = storage_lp(a, c.F; dt=dt); ec = sqrt(a.eta); ed = sqrt(a.eta)
    for i in 1:T
        d[i] > 1e-6 && push!(o, _so(:supply, μ[i] / ed, d[i], z, c.day, i, c.res))
        cc[i] > 1e-6 && push!(o, _so(:demand, μ[i] * ec, cc[i], z, c.day, i, c.res))
    end
    return _tag(s, o)
end
function offers(s::HourlyOC, c::CompanyCtx{Hydro})
    a = c.asset; T = length(c.F); dt = c.res / 60; o = MarketOrder[]
    _, μ = hydro_lp(a, c.F; dt=dt)
    for i in 1:T; push!(o, _so(:supply, a.wv + μ, a.p, a.zone, c.day, i, c.res)); end
    return _tag(s, o)
end
function offers(s::HourlyOC, c::CompanyCtx{PVBat})
    a = c.asset; pv = _pv(c); o = MarketOrder[]
    for i in eachindex(pv); pv[i] > 1e-6 && push!(o, _so(:supply, 0.0, pv[i], a.zone, c.day, i, c.res)); end
    append!(o, MarketOrder[x for (x, _) in offers(s, CompanyCtx(a.bat, c.F, c.day, c.res))])
    return _tag(s, o)
end
function offers(s::HourlyOC, c::CompanyCtx{Flex})
    o, plan, T, dt, z = _flex_base(c)
    _, μ = plan(c.F)
    for i in 1:T; push!(o, _so(:demand, μ, c.asset.pshift_max, z, c.day, i, c.res)); end
    return _tag(s, o)
end
