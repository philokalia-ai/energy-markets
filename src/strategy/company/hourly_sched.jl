"""HourlySched(): the forecast-optimal schedule as PRICE-TAKING hourly legs (supply at the harmonised floor, demand at
the cap): the unpriced benchmark that isolates the order structure from price limits. Storage, hydro, PV+battery
(PV at 0 €/MWh), retailer."""
struct HourlySched <: CompanyStrategy end
label(::HourlySched) = "hourly_sched"
function offers(s::HourlySched, c::CompanyCtx{Storage})
    a = c.asset; T = length(c.F); dt = c.res / 60; z = a.zone; o = MarketOrder[]
    cc, d, _ = storage_lp(a, c.F; dt=dt)
    for i in 1:T
        d[i] > 1e-6 && push!(o, _so(:supply, PRICE_FLOOR, d[i], z, c.day, i, c.res))
        cc[i] > 1e-6 && push!(o, _so(:demand, PRICE_CAP, cc[i], z, c.day, i, c.res))
    end
    return _tag(s, o)
end
function offers(s::HourlySched, c::CompanyCtx{Hydro})
    a = c.asset; T = length(c.F); dt = c.res / 60; o = MarketOrder[]
    q, _ = hydro_lp(a, c.F; dt=dt)
    for i in 1:T; q[i] > 1e-6 && push!(o, _so(:supply, PRICE_FLOOR, q[i], a.zone, c.day, i, c.res)); end
    return _tag(s, o)
end
function offers(s::HourlySched, c::CompanyCtx{PVBat})
    a = c.asset; pv = _pv(c); o = MarketOrder[]
    for i in eachindex(pv); pv[i] > 1e-6 && push!(o, _so(:supply, 0.0, pv[i], a.zone, c.day, i, c.res)); end
    append!(o, MarketOrder[x for (x, _) in offers(s, CompanyCtx(a.bat, c.F, c.day, c.res))])
    return _tag(s, o)
end
function offers(s::HourlySched, c::CompanyCtx{Flex})
    o, plan, T, dt, z = _flex_base(c)
    q, _ = plan(c.F)
    for i in 1:T; q[i] > 1e-6 && push!(o, _so(:demand, PRICE_CAP, q[i], z, c.day, i, c.res)); end
    return _tag(s, o)
end
