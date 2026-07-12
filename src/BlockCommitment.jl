# =============================================================================
# BlockCommitment — v17 commitment + fix-and-reprice single-zone clearing
# =============================================================================
#
# A FAIR variant of the `:merit_order` clear for thermal-cycling zones. It reuses
# the merit book's EXACT input assembly (same fleet after fleet-completion /
# truthing / derate / scenario, same net demand = load − RES − net imports, same
# gas SRMC / water-value drivers, same per-generator offered capacity) via
# `create_merit_order_book(...; return_inputs=true)`, and changes ONLY the
# clearing mechanism:
#
#   1. Commitment MILP (Gurobi): minimise production + startup + no-load, subject
#      to the balance, min/max output gated by commitment u∈{0,1}, startup logic,
#      ramp (relaxed at startup/shutdown), and min-uptime.  Startup / no-load
#      costs come from `FuelTypeParameters` per fuel type.
#   2. Fix u = u*, re-solve the LP → price[t] = dual of the hourly balance
#      (a unit on min-load can now be marginal — the fix-and-reprice non-convex
#      price, the standard day-ahead resolution of integer pricing).
#
# This is the productised form of `proto_mini_uc.jl` / `proto_mini_uc_de.jl`,
# run on PRODUCTION costs and the truthed fleet (never the prototype's crude
# 0.85×gas water value or its raw undercounted fleet). The measured finding it
# targets is ZONE-DEPENDENT: commitment materially helps thermal-cycling zones
# (DE_LU: MAE −30%) and does nothing / slightly hurts hydro / water-value zones
# (GR), where the cost stack already sets the shape. See
# docs/complex-orders-investigation.md.
#
# Gurobi-only by nature: the inter-temporal coupling breaks the per-period
# decomposition, so HiGHS is not a fit.
module BlockCommitment

using JuMP, Dates, Statistics

import ..MeritOrderBook: create_merit_order_book, get_zone_profile,
    WATER_VALUE_FUEL_TYPES
import ..get_fuel_type_parameters
import ..FLEXIBLE_FUEL_TYPES
import ..get_cached_gurobi_optimizer

"""
    _base_cost(g, ts, inp) -> Float64

The per-generator, per-timeslot BASE marginal cost the merit book assigns —
verbatim the `water_value` / `gmc` branch of `create_merit_order_book`'s order
loop, WITHOUT the per-period tranche / scarcity / must-run markups (those are the
merit bidding strategy; the commitment MILP's startup / no-load costs are the
block bidding strategy). Water-value fuels (reservoir / pumped hydro) price at the
opportunity cost of stored water; everything else at SRMC (with the nuclear
opportunity anchor when active). `inp` is the NamedTuple from
`create_merit_order_book(...; return_inputs=true)`.
"""
function _base_cost(g, ts::AbstractString, norm_demand::Float64, inp)
    if g.fuel_type in WATER_VALUE_FUEL_TYPES
        if inp.anchor_active && inp.opportunity_anchor == :hydro &&
           inp.anchor_prices !== nothing && haskey(inp.anchor_prices, ts)
            return clamp(inp.anchor_prices[ts] *
                         (inp.anchor_share + inp.water_value_dry_boost * inp.hydro_dryness),
                         2.0, inp.gas_srmc)
        elseif inp.hydro_model == :reservoir_opportunity
            wv_frac = 0.35 + 0.65 * max(inp.hydro_dryness, inp.reservoir_drawdown)
            return inp.gas_srmc * wv_frac *
                   (inp.water_value_base + inp.water_value_span * norm_demand)
        else
            return inp.gas_srmc * (1.0 + inp.water_value_dry_boost * inp.hydro_dryness) *
                   (inp.water_value_base + inp.water_value_span * norm_demand)
        end
    else
        if inp.anchor_active && inp.opportunity_anchor == :nuclear &&
           g.fuel_type == Symbol("Nuclear") &&
           inp.anchor_prices !== nothing && haskey(inp.anchor_prices, ts)
            return max(g.marginal_cost, inp.anchor_share * inp.anchor_prices[ts])
        end
        return g.marginal_cost
    end
end

"""
    clear_block_commitment(zone, day; kwargs...) -> Dict{String,Float64}

Clear a single zone via commitment + fix-and-reprice on the merit book's exact
fundamentals. Returns a `timeslot => price (€/MWh)` dict with the SAME native
timeslot keys `create_merit_order_book` would produce (each native sub-hour slot
carries its hour's price — the MILP clears at hourly resolution, matching the
validated prototype and the hourly evaluation).

Keyword args mirror the merit-book knobs that affect fundamentals
(`include_net_imports`, `net_import_exclude`, `net_import_import_only`,
`anchor_*`, scenario hooks) and are forwarded unchanged, so block mode and merit
mode see byte-identical inputs. `mip_gap` / `time_limit` tune the MILP.
"""
function clear_block_commitment(zone::String, day::Date;
    profile=get_zone_profile(zone),
    mip_gap::Float64=0.01,
    time_limit::Float64=180.0,
    verbose::Bool=false,
    kwargs...)

    inp = create_merit_order_book(zone, day; profile=profile, return_inputs=true, kwargs...)
    if !(inp isa NamedTuple) || !inp.success
        error("Block commitment: merit input assembly failed for $zone $day")
    end

    gens = inp.generators
    native_ts = inp.timeslots
    resolution_minutes = inp.resolution_minutes
    VOLL = inp.price_cap        # shortage prices at the cap (matches merit)
    FLOOR = 500.0              # over-generation prices at the EU −500 floor

    # ---- Aggregate to hourly (pph = 1): matches the validated prototype and the
    # hourly eval; the daily net-demand shape that drives commitment is preserved
    # (MW averaged over sub-hour slots). Zones already hourly are unchanged.
    hour_key(ts) = ts[1:11] * "00"
    hours = sort(unique(hour_key(ts) for ts in native_ts))
    H = length(hours)
    hidx = Dict(h => t for (t, h) in enumerate(hours))
    # hourly net demand = mean of the native sub-slot net demands in that hour
    nd_acc = Dict{String,Tuple{Float64,Int}}()
    for ts in native_ts
        k = hour_key(ts)
        s, n = get(nd_acc, k, (0.0, 0))
        nd_acc[k] = (s + inp.net_demand[ts], n + 1)
    end
    net = [nd_acc[h][1] / nd_acc[h][2] for h in hours]
    nd_min = minimum(net); nd_span = max(maximum(net) - nd_min, 1.0)

    N = length(gens)
    pmax = inp.offered_pmax
    isflex = [g.fuel_type in FLEXIBLE_FUEL_TYPES for g in gens]
    pmin = [isflex[i] ? 0.0 : min(gens[i].p_min, pmax[i]) for i in 1:N]
    fp = [get_fuel_type_parameters(g.fuel_type) for g in gens]
    # ramp (fraction of p_max per hour → MW/hour; relaxed to full range on
    # startup/shutdown so a unit can reach min-load in the period it commits)
    ru = [something(gens[i].ramp_up, fp[i].ramp_up_rate) * pmax[i] for i in 1:N]
    rd = [something(gens[i].ramp_down, fp[i].ramp_down_rate) * pmax[i] for i in 1:N]
    minup = [isflex[i] ? 1 : max(1, Int(something(gens[i].min_uptime, fp[i].min_uptime))) for i in 1:N]

    # per-(generator, hour) base cost matrix (water value / gmc)
    mc = Array{Float64}(undef, N, H)
    for (t, h) in enumerate(hours)
        norm_demand = (net[t] - nd_min) / nd_span
        for i in 1:N
            mc[i, t] = _base_cost(gens[i], h, norm_demand, inp)
        end
    end
    # representative unit cost for startup / no-load (thermal cost is
    # hour-invariant; hydro uses its daily mean water value)
    rep = [Statistics.mean(@view mc[i, :]) for i in 1:N]
    SU = [fp[i].startup_cost_multiplier * rep[i] * pmax[i] for i in 1:N]   # €/startup
    NL = [fp[i].no_load_cost_fraction * rep[i] * pmin[i] for i in 1:N]     # €/h

    opt = get_cached_gurobi_optimizer()

    # ---- 1) commitment MILP ------------------------------------------------
    m = Model(opt); verbose || set_silent(m)
    set_optimizer_attribute(m, "MIPGap", mip_gap)
    set_optimizer_attribute(m, "TimeLimit", time_limit)
    @variable(m, p[1:N, 1:H] >= 0)
    @variable(m, u[1:N, 1:H], Bin)
    @variable(m, v[1:N, 1:H] >= 0)
    @variable(m, short[1:H] >= 0)
    @variable(m, spill[1:H] >= 0)
    @constraint(m, [t=1:H], sum(p[i, t] for i in 1:N) + short[t] - spill[t] == net[t])
    @constraint(m, [i=1:N, t=1:H], p[i, t] <= pmax[i] * u[i, t])
    @constraint(m, [i=1:N, t=1:H], p[i, t] >= pmin[i] * u[i, t])
    @constraint(m, [i=1:N, t=2:H], p[i, t] - p[i, t-1] <= ru[i] + pmax[i] * v[i, t])
    @constraint(m, [i=1:N, t=2:H], p[i, t-1] - p[i, t] <= rd[i] + pmax[i] * (1 - u[i, t]))
    @constraint(m, [i=1:N, t=2:H], v[i, t] >= u[i, t] - u[i, t-1])
    for i in 1:N, t in 1:H
        minup[i] <= 1 && continue
        @constraint(m, sum(u[i, τ] for τ in t:min(H, t + minup[i] - 1)) >= minup[i] * v[i, t])
    end
    @objective(m, Min,
        sum(mc[i, t] * p[i, t] for i in 1:N, t in 1:H) +
        sum(SU[i] * v[i, t] for i in 1:N, t in 1:H) +
        sum(NL[i] * u[i, t] for i in 1:N, t in 1:H) +
        VOLL * sum(short) + FLOOR * sum(spill))
    optimize!(m)
    st = termination_status(m)
    if !(st == OPTIMAL || st == TIME_LIMIT || st == LOCALLY_SOLVED)
        error("Block commitment MILP for $zone $day terminated $st")
    end
    ustar = round.(value.(u))

    # ---- 2) fix-and-reprice LP → price = dual of the balance ---------------
    lp = Model(opt); set_silent(lp)
    @variable(lp, p2[1:N, 1:H] >= 0)
    @variable(lp, s2[1:H] >= 0)
    @variable(lp, x2[1:H] >= 0)
    @constraint(lp, bal[t=1:H], sum(p2[i, t] for i in 1:N) + s2[t] - x2[t] == net[t])
    @constraint(lp, [i=1:N, t=1:H], p2[i, t] <= pmax[i] * ustar[i, t])
    @constraint(lp, [i=1:N, t=1:H], p2[i, t] >= pmin[i] * ustar[i, t])
    @constraint(lp, [i=1:N, t=2:H],
        p2[i, t] - p2[i, t-1] <= ru[i] + pmax[i] * (ustar[i, t] - ustar[i, t-1] > 0.5 ? 1.0 : 0.0))
    # unscaled production cost → the balance dual is a clean €/MWh price
    @objective(lp, Min,
        sum(mc[i, t] * p2[i, t] for i in 1:N, t in 1:H) + VOLL * sum(s2) + FLOOR * sum(x2))
    optimize!(lp)
    if termination_status(lp) != OPTIMAL
        error("Block commitment reprice LP for $zone $day terminated $(termination_status(lp))")
    end
    hourly_price = Dict(hours[t] => clamp(dual(bal[t]), -FLOOR, VOLL) for t in 1:H)

    # map the hourly price back onto every native timeslot key
    return Dict{String,Float64}(ts => hourly_price[hour_key(ts)] for ts in native_ts)
end

end # module BlockCommitment
