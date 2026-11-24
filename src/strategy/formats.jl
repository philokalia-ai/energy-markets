# src/strategy/formats.jl — st-blocks: asset archetypes, order constructors per bid format, and the
# price-taker evaluator (EUPHEMIA acceptance rules applied at given prices + physical settlement).
#
# Standalone module, NOT included from src/Euphemia.jl (zero effect on production). Load with
#     using Euphemia
#     include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
#
# Every bid is a Vector{MarketOrder}: SimpleOrders (hourly / quarter-hourly curves) and LinkedHourlyOrder
# families whose id names the block semantics (the same ids the complex-order master understands):
#   BLK:<zone>:<name>                 all-or-nothing profile block (existing master semantics: SUPPLY members only —
#                                     the BLK path ignores the side, so a block with demand members must be BLKL)
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

export CompanyStrategy, CompanyCtx, offers, cost_reflective, strategy_of, label,
    HourlyMC, HourlyAC, HourlyOC, HourlySched, Block, Linked, Exclusive, MarFull, MarMin, BlockHAC,
    Thermal, Storage, Hydro, PVBat, Flex, archetype, srmc_gas, srmc_coal,
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
    :thermal => ["hourly_mc", "hourly_ac", "block", "linked", "exclusive", "mar", "mar_full", "block_hac"],
    :storage => ["hourly_oc", "hourly_sched", "block", "exclusive"],
    :hydro => ["hourly_oc", "hourly_sched", "block", "linked", "exclusive", "mar"],
    :pvbat => ["hourly_oc", "hourly_sched", "block", "exclusive"],
    :flex => ["hourly_oc", "hourly_sched", "block", "exclusive"],
)

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

# ------------------------------------------------------------------------- company strategies (plug-ins)
# One file per strategy (struct + offers methods); `bids` (round 1's entry point) is a thin wrapper in interface.jl.
for f in ("interface", "hourly_mc", "hourly_ac", "hourly_oc", "hourly_sched", "block", "mar", "linked", "exclusive",
          "block_hac")
    include(joinpath(@__DIR__, "company", f * ".jl"))
end

include("pricetaker.jl")

end # module
