# src/strategy/formats.jl — st-blocks: asset archetypes, order constructors per bid format, and the
# price-taker evaluator (EUPHEMIA acceptance rules applied at given prices + physical settlement).
#
# Standalone module, NOT included from src/Euphemia.jl (zero effect on production). Load with
#     using Euphemia
#     include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
#
# Every bid is a Vector{MarketOrder}: SimpleOrders (hourly / quarter-hourly curves) and LinkedHourlyOrder
# families whose id names the block semantics (the same ids the complex-order master understands):
#   BLK:<zone>:<name>                 all-or-nothing profile block (existing master semantics)
#   BLKM:<zone>:<name>:mar=<r>        minimum acceptance ratio: accepted ratio ∈ {0} ∪ [r, 1]
#   BLKL:<zone>:<name>[:parent=<p>]   linked family: accepted only if the block named <p> (same zone) is;
#                                     a parent may be loss-making if its accepted descendants cover it
#   BLKX:<zone>:<name>:group=<g>      exclusive group <g>: at most one member accepted
# Members carry their own price and side (:supply injects, :demand withdraws), so a family can be a
# loop (charge + discharge accepted together): its surplus is Σ_j s_j (P_t − p_j) q_j, s = +1 supply, −1 demand.
# `family_budget_mwh` is unused (NaN) for blocks.
#
# Inputs a constructor may read (as-of rule, strategy/DESIGN.md): forecast prices of D (base.prices), fuel
# closes ≤ D-2, D-1 RES/load forecasts. Realised prices of D only enter `evaluate`.
module StrategyFormats

using Dates
using JuMP, HiGHS
using Euphemia
import Euphemia.MarketOrders: MarketOrder, SimpleOrder, LinkedHourlyOrder

export Thermal, Storage, Hydro, PVBat, Flex, archetype, srmc_gas, srmc_coal,
    Prices, bids, evaluate, family_kind, parse_family, FORMATS

# ---------------------------------------------------------------------------------------------- archetypes
"""Thermal unit. Costs: SRMC €/MWh_el (repo SRMC model), start-up € per start, no-load € per hour on."""
struct Thermal
    id::String; zone::String; pmax::Float64; pmin::Float64
    min_up::Int; min_down::Int; srmc::Float64; startup::Float64; noload::Float64
end
"""Energy storage (battery / PSP). Round-trip η split evenly between charge and discharge."""
struct Storage
    id::String; zone::String; p::Float64; e::Float64; eta::Float64
end
"""Reservoir hydro: daily energy budget `e` MWh; `wv` = water value €/MWh (the opportunity cost of water)."""
struct Hydro
    id::String; zone::String; p::Float64; e::Float64; wv::Float64
end
"""Solar + battery: `pv` = hourly MW forecast profile (D-1 solar forecast shape × MWp)."""
struct PVBat
    id::String; zone::String; pv::Vector{Float64}; bat::Storage
end
"""Retailer: hourly load `load` MW; `shift` share shiftable within the day (energy kept),
`curt` share curtailable above `wtp` €/MWh; the rest must be served (bid at the cap)."""
struct Flex
    id::String; zone::String; load::Vector{Float64}; shift::Float64; curt::Float64; wtp::Float64
    pshift_max::Float64   # max shiftable MW in any hour
end

# repo SRMC model (src/generators/fuel_costs.jl): gas = TTF/(η·NCV/GCV) + EF_th/η·EUA + VOM, shipped
# cv45 GAS_HHV basis; coal/lignite = FUEL_SRMC_BASE + FUEL_EMISSION_FACTOR_EL × EUA.
srmc_gas(ttf, eua) = Euphemia._gas_fuel_cost(ttf, Euphemia.GAS_PLANT_EFFICIENCY, true) +
                     Euphemia.GAS_EMISSION_FACTOR / Euphemia.GAS_PLANT_EFFICIENCY * eua + Euphemia.GAS_VOM_COST
srmc_coal(fuel::String, eua) = Euphemia.FUEL_SRMC_BASE[fuel] + Euphemia.FUEL_EMISSION_FACTOR_EL[fuel] * eua

"""Start-up cost € = FuelTypeParameters.startup_cost_multiplier × SRMC × Pmax (one full-load hour of fuel+CO2
cost per start, the repo's own formula: docs/experiments/proto_mini_uc.jl:49)."""
startup_cost(fuel::String, srmc, pmax) = get_fuel_type_parameters(Symbol(fuel)).startup_cost_multiplier * srmc * pmax

"""No-load cost € per hour on = FuelTypeParameters.no_load_cost_fraction × SRMC × Pmin (the fleet data's 'no-load
cost as a fraction of marginal cost', applied to the minimum stable output; gas 0.15, hard coal 0.20, lignite 0.25)."""
noload_cost(fuel::String, srmc, pmin) = get_fuel_type_parameters(Symbol(fuel)).no_load_cost_fraction * srmc * pmin

function _thermal(id, zone, fuel, pmax, srmc)
    fp = get_fuel_type_parameters(Symbol(fuel))
    pmin = fp.min_load_factor * pmax
    Thermal(id, zone, pmax, pmin, fp.min_uptime, fp.min_downtime, srmc,
            startup_cost(fuel, srmc, pmax), noload_cost(fuel, srmc, pmin))
end

"""
    archetype(id, zone; ttf, eua, solar_fc=nothing, load_fc=nothing, wv=nothing) -> asset

The DESIGN.md §2 archetypes. Costs from the repo (fleet SRMC model, FuelTypeParameters); never fitted.
"""
function archetype(id::String, zone::String; ttf=nothing, eua=nothing, solar_fc=nothing, load_fc=nothing,
                   wv=nothing, solar_peak=nothing)
    if id == "CCGT"
        return _thermal("CCGT", zone, "Fossil Gas", 400.0, srmc_gas(ttf, eua))
    elseif id == "COAL"
        fuel = zone == "GR" ? "Fossil Brown coal/Lignite" : "Fossil Hard coal"
        return _thermal("COAL", zone, fuel, 500.0, srmc_coal(fuel, eua))
    elseif id == "HYDRO"
        return Hydro("HYDRO", zone, 300.0, 3600.0, wv)
    elseif id == "BESS"
        return Storage("BESS", zone, 100.0, 200.0, 0.88)
    elseif id == "PSP"
        return Storage("PSP", zone, 300.0, 2400.0, 0.75)
    elseif id == "PVBAT"
        # 200 MWp: the zone's D-1 solar forecast scaled by its max over the prior 365 days (capacity proxy)
        s = Float64.(solar_fc); pk = solar_peak === nothing ? maximum(s) : max(solar_peak, maximum(s))
        return PVBat("PVBAT", zone, pk > 0 ? 200.0 .* s ./ pk : zeros(length(s)), Storage("BAT", zone, 100.0, 200.0, 0.88))
    elseif id == "FLEX"
        l = Float64.(load_fc)
        L = 300.0 .* l ./ maximum(l)
        return Flex("FLEX", zone, L, 0.20, 0.10, 300.0, 0.40 * 300.0)
    end
    error("unknown archetype $id")
end

# ------------------------------------------------------------------------------------------ order helpers
const PRICE_CAP = 4000.0     # SDAC harmonised max clearing price (HMMCP, since 2022), demand that must be served
const PRICE_FLOOR = -500.0   # SDAC harmonised min clearing price

_t(day::Date, i::Int, res::Int) = DateTime(day) + Minute((i - 1) * res)
_so(side, p, q, zone, day, i, res) = SimpleOrder(side, p, q, Symbol(zone), _t(day, i, res), res)
_lo(side, p, q, zone, day, i, res, fam) = LinkedHourlyOrder(side, p, q, Symbol(zone), _t(day, i, res), res, fam, NaN)

"""Family kind: :BLK, :BLKM, :BLKL, :BLKX, or :other (storage budget families, fallbacks)."""
function family_kind(f::AbstractString)
    for (pfx, k) in (("BLK:", :BLK), ("BLKM:", :BLKM), ("BLKL:", :BLKL), ("BLKX:", :BLKX))
        startswith(f, pfx) && return k
    end
    return :other
end

"""Parse `KIND:zone:name[:k=v]*` → (kind, zone, name, Dict k=>v)."""
function parse_family(f::AbstractString)
    parts = split(f, ':')
    kv = Dict{String,String}()
    for p in parts[4:end]
        k, v = split(p, '='; limit=2); kv[k] = v
    end
    return (kind=family_kind(f), zone=String(parts[2]), name=String(parts[3]), attrs=kv)
end

# ------------------------------------------------------------------------------- forecast-side optimisers
# No `threads` override: HiGHS keeps one process-wide scheduler and a model asking for a different thread count than
# the one it started with fails (no solution) — the same rule as src/mpcc/complex_orders.jl.
_lp() = (m = Model(HiGHS.Optimizer); set_silent(m); m)

"""Storage arbitrage LP on forecast prices F (MW per period, `dt` hours per period), SoC empty at both ends.
Returns (charge, discharge, μ) with μ_t = marginal value of stored energy (€/MWh_stored) after period t."""
function storage_lp(s::Storage, F::Vector{Float64}; dt=1.0)
    T = length(F); ec = sqrt(s.eta); ed = sqrt(s.eta)
    m = _lp()
    @variable(m, 0 <= c[1:T] <= s.p); @variable(m, 0 <= d[1:T] <= s.p); @variable(m, 0 <= soc[1:T] <= s.e)
    @constraint(m, bal[t=1:T], soc[t] == (t == 1 ? 0.0 : soc[t-1]) + dt * (ec * c[t] - d[t] / ed))
    @constraint(m, soc[T] == 0.0)
    @objective(m, Max, sum(F[t] * dt * (d[t] - c[t]) for t in 1:T))
    optimize!(m)
    μ = [-dual(bal[t]) for t in 1:T]   # ∂obj/∂(stored energy at t)
    return value.(c), value.(d), μ
end

"""Hydro dispatch LP on forecast F: max Σ (F_t − wv) q_t s.t. Σ q_t dt ≤ e, 0 ≤ q ≤ p. Returns (q, μ_energy)."""
function hydro_lp(h::Hydro, F::Vector{Float64}; dt=1.0, e=h.e, pcap=h.p)
    T = length(F); m = _lp()
    @variable(m, 0 <= q[1:T] <= pcap)
    @constraint(m, en, sum(q) * dt <= e)
    @objective(m, Max, sum((F[t] - h.wv) * dt * q[t] for t in 1:T))
    optimize!(m)
    return value.(q), dual(en) < 0 ? -dual(en) : dual(en)
end

"""Best contiguous window of length L ≥ Lmin maximising Σ_t∈W v_t − fixed(L); returns (s, L, value)."""
function best_window(v::Vector{Float64}, Ls, fixed::Function)
    T = length(v); best = (1, first(Ls), -Inf)
    for L in Ls, s in 1:(T-L+1)
        val = sum(@view v[s:s+L-1]) - fixed(L)
        val > best[3] && (best = (s, L, val))
    end
    return best
end

# ---------------------------------------------------------------------------------------------- formats
"""Bid formats per archetype class (FORMATS[class] = list of format ids)."""
const FORMATS = Dict(
    :thermal => ["hourly_mc", "hourly_ac", "block", "linked", "exclusive", "mar", "mar_full"],
    :storage => ["hourly_oc", "hourly_sched", "block", "exclusive"],
    :hydro => ["hourly_oc", "hourly_sched", "block", "linked", "exclusive", "mar"],
    :pvbat => ["hourly_oc", "hourly_sched", "block", "exclusive"],
    :flex => ["hourly_oc", "hourly_sched", "block", "exclusive"],
)

"""
    bids(asset, format, F, day; res=60, k_su=1.0, nx=5) -> Vector{MarketOrder}

Build the company's orders for `day` from the FORECAST prices `F` of the asset's zone (one per period,
period length `res` minutes). `k_su` scales the start-up cost recovered in a block's price (calibrated
on the calibration days). Never pass realised prices of `day` as F.
"""
function bids(a::Thermal, fmt::String, F::Vector{Float64}, day::Date; res=60, k_su=1.0, nx=5)
    # Cost-reflective pricing rule (ex ante, fleet data): a block's price = SRMC + (k_su·start-up + no-load × run
    # hours) / block energy, k_su ≤ 1, so no price exceeds the unit's average cost incl. start-up and no-load over the
    # block. `mar` prices that cost at the MINIMUM acceptance ratio (above average cost when fully accepted — flagged
    # in the report); `mar_full` prices it at full acceptance (= average cost when fully accepted, below cost when
    # cut back towards the MAR).
    k_su <= 1.0 + 1e-9 || error("k_su = $k_su > 1 would price above cost incl. start-up")
    T = length(F); dt = res / 60; z = a.zone; o = MarketOrder[]
    hrs(h) = max(1, round(Int, h / dt))                       # hours → periods
    Ls = hrs(a.min_up):T
    fixc(L) = k_su * a.startup + a.noload * L * dt            # € per run of L periods
    if fmt == "hourly_mc"         # truthful marginal: Pmax at SRMC every period
        for i in 1:T; push!(o, _so(:supply, a.srmc, a.pmax, z, day, i, res)); end
    elseif fmt == "hourly_ac"     # hourly at average cost: SRMC + (start-up + no-load) over the forecast run length
        s, L, _ = best_window((F .- a.srmc) .* a.pmax .* dt, Ls, fixc)
        p = a.srmc + fixc(L) / (a.pmax * L * dt)
        for i in 1:T; push!(o, _so(:supply, p, a.pmax, z, day, i, res)); end
    elseif fmt in ("block", "mar", "mar_full")
        r = fmt == "block" ? 1.0 : a.pmin / a.pmax
        rp = fmt == "mar" ? r : 1.0                           # ratio at which the price recovers the fixed costs
        s, L, _ = best_window((F .- a.srmc) .* a.pmax .* dt, Ls, L -> fixc(L) / rp)
        p = a.srmc + fixc(L) / (rp * a.pmax * L * dt)
        fam = fmt == "block" ? "BLK:$z:$(a.id)-b" : "BLKM:$z:$(a.id)-$(fmt == "mar" ? "m" : "mf"):mar=$(round(r, digits=4))"
        for i in s:s+L-1; push!(o, _lo(:supply, p, a.pmax, z, day, i, res, fam)); end
    elseif fmt == "linked"
        # parent = Pmin over the window, priced with start-up + no-load; children = (Pmax−Pmin) per period at SRMC
        val = [(F[i] - a.srmc) * a.pmin * dt + max(0.0, F[i] - a.srmc) * (a.pmax - a.pmin) * dt for i in 1:T]
        s, L, _ = best_window(val, Ls, fixc)
        pp = a.srmc + fixc(L) / (a.pmin * L * dt)
        par = "BLKL:$z:$(a.id)-p"
        for i in s:s+L-1
            push!(o, _lo(:supply, pp, a.pmin, z, day, i, res, par))
            push!(o, _lo(:supply, a.srmc, a.pmax - a.pmin, z, day, i, res, "BLKL:$z:$(a.id)-c$i:parent=$(a.id)-p"))
        end
    elseif fmt == "exclusive"
        # nx alternative flat blocks: the forecast-best window for nx spread lengths (min_up … T)
        Lset = unique(round.(Int, range(first(Ls), T; length=nx)))
        for (k, L) in enumerate(Lset)
            s, _, _ = best_window((F .- a.srmc) .* a.pmax .* dt, L:L, fixc)
            p = a.srmc + fixc(L) / (a.pmax * L * dt)
            fam = "BLKX:$z:$(a.id)-x$k:group=$(a.id)"
            for i in s:s+L-1; push!(o, _lo(:supply, p, a.pmax, z, day, i, res, fam)); end
        end
    else
        error("thermal format $fmt")
    end
    return o
end

# storage: loop schedules as mixed-sign families (discharge = supply, charge = demand), all slices priced 0:
# family surplus = Σ P_t·(d_t − c_t)·dt = the schedule's arbitrage value at the prices.
function _loop!(o, sched_c, sched_d, z, day, res, fam)
    for i in eachindex(sched_c)
        sched_d[i] > 1e-6 && push!(o, _lo(:supply, 0.0, sched_d[i], z, day, i, res, fam))
        sched_c[i] > 1e-6 && push!(o, _lo(:demand, 0.0, sched_c[i], z, day, i, res, fam))
    end
end

_shift(F, k) = [F[clamp(i - k, 1, length(F))] for i in eachindex(F)]
_smooth(F, w) = [sum(F[max(1, i - w):min(end, i + w)]) / (min(length(F), i + w) - max(1, i - w) + 1) for i in eachindex(F)]

"""Alternative forecast scenarios used to build exclusive-group members (deterministic transforms of F)."""
_alts(F, dt) = [F, _shift(F, round(Int, 1 / dt)), _shift(F, -round(Int, 1 / dt)), _smooth(F, round(Int, 1 / dt)),
                _smooth(F, round(Int, 3 / dt))]

function bids(a::Storage, fmt::String, F::Vector{Float64}, day::Date; res=60, nx=5, kw...)
    T = length(F); dt = res / 60; z = a.zone; o = MarketOrder[]
    if fmt == "hourly_oc"
        # the forecast-optimal schedule as independent hourly orders, each price-limited at the forecast
        # opportunity cost of stored energy (LP dual μ_t): discharge legs sell at μ_t/η_d, charge legs buy at μ_t·η_c.
        # Legs clear independently, so the sold schedule can break the state-of-charge limits (the hourly risk).
        c, d, μ = storage_lp(a, F; dt=dt); ec = sqrt(a.eta); ed = sqrt(a.eta)
        for i in 1:T
            d[i] > 1e-6 && push!(o, _so(:supply, μ[i] / ed, d[i], z, day, i, res))
            c[i] > 1e-6 && push!(o, _so(:demand, μ[i] * ec, c[i], z, day, i, res))
        end
    elseif fmt == "hourly_sched"   # the forecast-optimal schedule as price-taking hourly legs (no price limits)
        c, d, _ = storage_lp(a, F; dt=dt)
        for i in 1:T
            d[i] > 1e-6 && push!(o, _so(:supply, PRICE_FLOOR, d[i], z, day, i, res))
            c[i] > 1e-6 && push!(o, _so(:demand, PRICE_CAP, c[i], z, day, i, res))
        end
    elseif fmt == "block"
        c, d, _ = storage_lp(a, F; dt=dt)
        _loop!(o, c, d, z, day, res, "BLK:$z:$(a.id)-b")
    elseif fmt == "exclusive"
        seen = Set{Vector{Float64}}()
        for (k, G) in enumerate(_alts(F, dt)[1:nx])
            c, d, _ = storage_lp(a, G; dt=dt)
            key = round.(d .- c, digits=3); key in seen && continue; push!(seen, key)
            _loop!(o, c, d, z, day, res, "BLKX:$z:$(a.id)-x$k:group=$(a.id)")
        end
    else
        error("storage format $fmt")
    end
    return o
end

function bids(a::Hydro, fmt::String, F::Vector{Float64}, day::Date; res=60, nx=5, mar=0.5, kw...)
    T = length(F); dt = res / 60; z = a.zone; o = MarketOrder[]
    if fmt == "hourly_oc"    # Pmax every period at water value + energy-budget dual
        _, μ = hydro_lp(a, F; dt=dt)
        for i in 1:T; push!(o, _so(:supply, a.wv + μ, a.p, z, day, i, res)); end
    elseif fmt == "hourly_sched"   # the forecast-optimal profile, price-taking
        q, _ = hydro_lp(a, F; dt=dt)
        for i in 1:T; q[i] > 1e-6 && push!(o, _so(:supply, PRICE_FLOOR, q[i], z, day, i, res)); end
    elseif fmt in ("block", "mar")
        q, _ = hydro_lp(a, F; dt=dt)
        fam = fmt == "mar" ? "BLKM:$z:$(a.id)-m:mar=$mar" : "BLK:$z:$(a.id)-b"
        for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:supply, a.wv, q[i], z, day, i, res, fam)); end
    elseif fmt == "linked"   # parent = the best half of the budget; children = each further period, budget-bounded
        q, _ = hydro_lp(a, F; dt=dt)
        on = sort([i for i in 1:T if q[i] > 1e-6]; by=i -> -F[i])
        npar = max(1, cld(length(on), 2))
        for (r, i) in enumerate(on)
            fam = r <= npar ? "BLKL:$z:$(a.id)-p" : "BLKL:$z:$(a.id)-c$i:parent=$(a.id)-p"
            push!(o, _lo(:supply, a.wv, q[i], z, day, i, res, fam))
        end
    elseif fmt == "exclusive"  # same energy spread over different numbers of periods
        for (k, frac) in enumerate(range(0.5, 1.0; length=nx))     # spread: energy at frac·… of Pmax
            nper = clamp(round(Int, a.e / (a.p * frac * dt)), 1, T)
            pcap = a.e / (nper * dt)
            q, _ = hydro_lp(a, F; dt=dt, pcap=min(a.p, pcap))
            fam = "BLKX:$z:$(a.id)-x$k:group=$(a.id)"
            for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:supply, a.wv, q[i], z, day, i, res, fam)); end
        end
    else
        error("hydro format $fmt")
    end
    return o
end

"""PV + battery. PV is offered at 0 €/MWh (its marginal cost) in every format; the battery follows the
storage format. `block`/`exclusive`: one combined loop family (PV + battery schedule) — accepted whole."""
function bids(a::PVBat, fmt::String, F::Vector{Float64}, day::Date; res=60, nx=5, kw...)
    T = length(F); dt = res / 60; z = a.zone; o = MarketOrder[]
    pv = length(a.pv) == T ? a.pv : repeat(a.pv; inner=T ÷ length(a.pv))
    if fmt == "hourly_oc"
        for i in 1:T; pv[i] > 1e-6 && push!(o, _so(:supply, 0.0, pv[i], z, day, i, res)); end
        append!(o, bids(a.bat, "hourly_oc", F, day; res=res))
    elseif fmt == "hourly_sched"   # PV at 0 €/MWh + the battery's forecast schedule price-taking
        for i in 1:T; pv[i] > 1e-6 && push!(o, _so(:supply, 0.0, pv[i], z, day, i, res)); end
        append!(o, bids(a.bat, "hourly_sched", F, day; res=res))
    else
        alts = fmt == "block" ? [F] : _alts(F, dt)[1:nx]
        seen = Set{Vector{Float64}}()
        for (k, G) in enumerate(alts)
            c, d, _ = storage_lp(a.bat, G; dt=dt)
            net = pv .+ d .- c
            key = round.(net, digits=3); key in seen && continue; push!(seen, key)
            fam = fmt == "block" ? "BLK:$z:PVBAT-b" : "BLKX:$z:PVBAT-x$k:group=PVBAT"
            for i in 1:T
                net[i] > 1e-6 && push!(o, _lo(:supply, 0.0, net[i], z, day, i, res, fam))
                net[i] < -1e-6 && push!(o, _lo(:demand, 0.0, -net[i], z, day, i, res, fam))
            end
        end
    end
    return o
end

"""Retailer. Firm part (1 − shift − curt) bid at the price cap; curtailable part at WTP; the shiftable energy
E_s = shift·Σ load: `hourly_oc` = hourly bids up to pshift_max at the forecast opportunity price (the LP dual of
'buy E_s at least cost'), `block` = one buy profile on the forecast-cheapest periods at limit WTP, `exclusive` =
alternative profiles (forecast transforms), at most one bought."""
function bids(a::Flex, fmt::String, F::Vector{Float64}, day::Date; res=60, nx=5, kw...)
    T = length(F); dt = res / 60; z = a.zone; o = MarketOrder[]
    L = length(a.load) == T ? a.load : repeat(a.load; inner=T ÷ length(a.load))
    firm = 1.0 - a.shift - a.curt
    for i in 1:T
        push!(o, _so(:demand, PRICE_CAP, firm * L[i], z, day, i, res))
        push!(o, _so(:demand, a.wtp, a.curt * L[i], z, day, i, res))
    end
    Es = a.shift * sum(L) * dt
    function plan(G)   # least-cost purchase of Es on G, ≤ pshift_max per period
        m = _lp(); @variable(m, 0 <= q[1:T] <= a.pshift_max); @constraint(m, en, sum(q) * dt >= Es)
        @objective(m, Min, sum(G[t] * dt * q[t] for t in 1:T)); optimize!(m)
        return value.(q), abs(dual(en))
    end
    if fmt == "hourly_oc"
        _, μ = plan(F)
        for i in 1:T; push!(o, _so(:demand, μ, a.pshift_max, z, day, i, res)); end
    elseif fmt == "hourly_sched"   # the forecast least-cost purchase plan, price-taking (bid at the cap)
        q, _ = plan(F)
        for i in 1:T; q[i] > 1e-6 && push!(o, _so(:demand, PRICE_CAP, q[i], z, day, i, res)); end
    else
        alts = fmt == "block" ? [F] : _alts(F, dt)[1:nx]
        seen = Set{Vector{Float64}}()
        for (k, G) in enumerate(alts)
            q, _ = plan(G)
            key = round.(q, digits=3); key in seen && continue; push!(seen, key)
            fam = fmt == "block" ? "BLK:$z:FLEX-b" : "BLKX:$z:FLEX-x$k:group=FLEX"
            for i in 1:T; q[i] > 1e-6 && push!(o, _lo(:demand, a.wtp, q[i], z, day, i, res, fam)); end
        end
    end
    return o
end

include("pricetaker.jl")

end # module
