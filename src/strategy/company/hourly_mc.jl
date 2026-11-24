"""HourlyMC(): thermal, Pmax offered every period at SRMC (marginal cost only; the truthful hourly benchmark).
Parameters: none. SRMC: the repo's model (src/generators/fuel_costs.jl), fuel/CO2 closes ≤ D−2."""
struct HourlyMC <: CompanyStrategy end
label(::HourlyMC) = "hourly_mc"
cost_reflective(::HourlyMC) = true
function offers(s::HourlyMC, c::CompanyCtx{Thermal})
    t = _th(c); o = MarketOrder[]
    for i in 1:t.T; push!(o, _so(:supply, t.a.srmc, t.a.pmax, t.z, c.day, i, c.res)); end
    return _tag(s, o)
end
