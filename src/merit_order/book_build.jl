# book_build.jl — create_merit_order_book: builds one zone-day merit-order
# book from generators, load, RES, flows and the zone profile.
# Included by ../MeritOrderBook.jl inside `module MeritOrderBook`.
#
# The build runs in nine stages (banners mark each in the main function;
# stages 1/2/4/5 are the named helpers defined below):
#   1. _true_up_fleet     — fleet completion / truthing derate / SRMC pricing
#   2. _demand_series     — load & RES series on the clearing grid
#   3. inline             — net imports, demand state, gas anchor, backstop
#   4. _hydro_state       — hydro offer scale, dryness, seasonal drawdown
#   5. _committed_set     — UC-lite must-run selection
#   6. inline             — the supply order loop (RES, imports, hydro, thermal)
#   7. inline             — demand orders
#   8. inline             — scenario hooks (extra_orders, strategist)
#   9. inline             — merge identical blocks + assemble the MPCC book


# =============================================================================
# Stage helpers for create_merit_order_book
# =============================================================================
# Each helper is one stage of the book build, extracted verbatim from the
# original single-function body (operation order unchanged — the book is
# bit-identical). State flows explicitly: a helper takes what the stage read
# and returns what later stages use.

"""Hydro-family test shared by the offer-scale, capacity and water-value logic."""
_is_hydro(g::Generator) = g.fuel_type in WATER_VALUE_FUEL_TYPES ||
                          g.fuel_type == Symbol("Hydro Run-of-river and pondage")

"""
Stage 1 — true the offered fleet to the zone's demonstrated capability and
price it: fleet completion (aggregate small units up to the p95/installed
truth target), fleet-truthing derate of baseload types, the thermal SRMC
premium / nuclear bid floor, and the cv18 per-unit spread factors.
Returns `(generators, unit_spread_factor, apply_unit_spread)`.
"""
function _true_up_fleet(generators::Vector{Generator}, bidding_zone::String,
    day::Date, profile::ZoneProfile;
    fleet_completion::Bool, fleet_truthing::Bool, derate_headroom::Float64,
    thermal_srmc_multiplier::Float64, nuclear_srmc_floor::Float64,
    anchor_active::Bool, opportunity_anchor::Symbol)
    # Fleet completion: ENTSO-E's unit-level table only lists larger
    # units, so for some zones (RO, BG, RS) the fleet is structurally
    # undersized and the book clears at spurious shortage-cap prices.
    # When the zone's recent per-type actual output (p95, trailing 30
    # days — strictly historical) exceeds the unit-level capacity of
    # that type, the missing capacity demonstrably exists and produces:
    # add it as one aggregate generator per fuel type. Wind/solar are
    # excluded (netted via the RES forecast). Harmless for zones with
    # good unit coverage — the gap is ~0 there (verified on GR).
    # Shared by fleet completion (upward) and fleet-truthing derate
    # (downward); keys normalized once to canonical fuel names
    type_p95_raw = (fleet_completion || fleet_truthing) ?
                   get_type_output_p95(bidding_zone, day) : Dict{String,Float64}()
    type_p95 = Dict{String,Float64}(
        normalize_fuel_type_name(k) => v for (k, v) in type_p95_raw)
    # Fleet-truth mode (iter7, gated — see the ZoneProfile field docstring).
    # `fleet_truth_target` holds the per-type truth target of MARKET-ACTIVE
    # types only (trailing-30d p95 > 100 MW): those types complete UP to it
    # and are never derated below it. Types with no recent output (phantom
    # post-closure capacity with stale COMMISSIONED status) never enter —
    # that is the activity gate that replaces get_generators' validity
    # filter for this purpose. Empty for :p95 (the default) — byte-identical
    # v10/iter6 behaviour.
    fleet_truth_target = Dict{String,Float64}()
    fleet_truth_mode = _effective_fleet_truth_mode(profile)
    if fleet_completion && fleet_truth_mode != :p95
        src = fleet_truth_mode == :installed ?
              get_installed_capacity_by_type(bidding_zone) :
              Dict{String,Float64}(normalize_fuel_type_name(k) => v
                  for (k, v) in get_type_output_p95(bidding_zone, day;
                                                    lookback_days=365))
        for (t, cap) in src
            get(type_p95, t, 0.0) > 100.0 && (fleet_truth_target[t] = cap)
        end
    end
    if fleet_completion
        for (ptype, p95) in type_p95
            ptype in ("Wind Onshore", "Wind Offshore", "Solar") && continue
            fleet = sum((g.p_max for g in generators
                         if g.fuel_type == Symbol(ptype)); init=0.0)
            target = max(p95, get(fleet_truth_target, ptype, 0.0))
            gap = target - fleet
            gap > 100.0 || continue
            push!(generators, Generator(
                "AGG-$(bidding_zone)-$(replace(ptype, " " => "_"))",
                "Aggregate small units: $ptype",
                Symbol(ptype),
                bidding_zone,
                gap,
                0.0,
                bidding_zone,
                get_marginal_cost(day, ptype, bidding_zone)))
            src = target > p95 ? "installed $(round(Int, target))" :
                                 "recent p95 $(round(Int, p95))"
            println("  ➕ Fleet completion: +$(round(Int, gap)) MW $ptype " *
                    "($src MW vs $(round(Int, fleet)) MW unit-level)")
        end
    end

    # Fleet-truthing derate — the symmetric case of fleet completion.
    # When the unit-level fleet (after outage filtering) far exceeds
    # what the type has recently delivered, the excess is phantom
    # capacity: unfiled long-term derates, fuel-supply constraints, or
    # stale unit records. 2022 GR lignite is the canonical case — the
    # book offered ~2.2 GW at lignite SRMC while the real fleet's p95
    # was ~1.2 GW, so cheap phantom lignite displaced gas from the
    # margin and the whole crisis year cleared ~140 €/MWh low. Thermal
    # types only: hydro availability is handled by the water-value
    # offer scale, and RES never enters the thermal stack. The signal
    # (trailing 30-day p95, strictly historical) is ex-ante; 15%
    # headroom above p95 leaves room for genuinely tight days to call
    # on more of the fleet than it recently ran.
    #
    # Baseload/fuel-constrained types ONLY. For a fuel whose SRMC sits
    # below the market price, running under its capacity means it
    # genuinely could not run (mining limits, fuel supply, unfiled
    # derates) — it would have been dispatched otherwise. Mid-merit
    # and peaking fuels (gas, oil) run below capacity simply because
    # of their merit-order position; their capacity IS available at
    # its SRMC, and derating them manufactures phantom scarcity.
    derate_types = ("Fossil Brown coal/Lignite", "Fossil Hard coal",
                    "Fossil Oil shale", "Fossil Coal-derived gas",
                    "Fossil Peat", "Nuclear")
    # One scale per fuel type, applied in a single pass. Iterates the
    # FLEET's types (not type_p95's keys): a derate-listed type with a
    # p95 of zero is a fully offline fleet and derates all the way
    # down, while a type entirely absent from the aggregate table is
    # ambiguous (never-reporting type vs ETL gap) and is skipped
    # loudly rather than silently zeroed. Thermal orders offer raw
    # p_max (availability_factor only shapes the scarcity margin), so
    # the target compares against the raw fleet sum. p_min scales
    # proportionally with p_max — clamping instead would balloon the
    # must-run fraction of every derated unit.
    derate_scale = Dict{Symbol,Float64}()
    if fleet_truthing
        for ptype in derate_types
            fsym = Symbol(ptype)
            fleet_raw = sum((g.p_max for g in generators if g.fuel_type == fsym); init=0.0)
            fleet_raw > 0 || continue
            if !haskey(type_p95, ptype)
                println("  ⚠️  Fleet-truthing: no recent output data for $ptype " *
                        "($(round(Int, fleet_raw)) MW fleet) — derate skipped")
                continue
            end
            # Fleet-truth mode: a market-active type never derates below
            # its truth target (the completion above just trued it to
            # exactly that — derating it back to 1.15×30d-p95 would cancel
            # the mechanism for precisely the baseload derate-types it
            # targets). :p95 zones (GR/SEE) have fleet_truth_target empty —
            # byte-identical v10 behaviour.
            target = max(derate_headroom * type_p95[ptype],
                         get(fleet_truth_target, ptype, 0.0))
            fleet_raw > target + 100.0 || continue
            derate_scale[fsym] = target / fleet_raw
            println("  ➖ Fleet-truthing derate: $ptype ×$(round(target / fleet_raw, digits=2)) " *
                    "(fleet $(round(Int, fleet_raw)) MW vs recent p95 $(round(Int, type_p95[ptype])) MW)")
        end
    end
    # Thermal SRMC premium (ITALY_PROFILE): scale the marginal cost of
    # thermal fuels only — hydro/storage price at water value, not fuel
    # cost, and RES never enters the thermal stack. gas_srmc (the hydro
    # anchor) is computed separately and is unaffected. Default multiplier
    # 1.0 leaves every cost untouched (byte-identical for SEE).
    srmc_exempt_fuels = Set{Symbol}(vcat(WATER_VALUE_FUEL_TYPES,
        [Symbol("Hydro Run-of-river and pondage"), Symbol("Energy storage")]))
    apply_srmc_premium = thermal_srmc_multiplier != 1.0
    # Nuclear bid-position floor (FRANCE_PROFILE): raise the nuclear bid
    # base to at least this level — nuclear-dominated exporters price their
    # modulating fleet at opportunity cost, not fuel SRMC. Default 0.0 is a
    # no-op (byte-identical for SEE).
    # When the :nuclear anchor is ACTIVE the static floor is replaced by the
    # per-slot anchor floor in the order loop (a static floor would hold the
    # price up in exactly the RES-surplus hours where the coupled price —
    # and EDF's opportunity cost — collapses: 2026-04 weekends, FR actual
    # €9 vs the €55 floor).
    apply_nuclear_floor = nuclear_srmc_floor > 0.0 &&
                          !(anchor_active && opportunity_anchor == :nuclear)
    # Per-unit SRMC spread (cv18) is applied at ORDER-PRICE time in the
    # order loop below (to gmc), NOT here: applying it to marginal_cost
    # would also perturb the UC-lite must-run SELECTION (SRMC <=
    # 1.15 x gas gate) and the committed-set ordering, which the validated
    # prototype left untouched — measured: spraying mc reproduced only
    # half the CSOUTH gain and worsened MAE (+2.4) via a shifted
    # commitment set.
    apply_unit_spread = profile.unit_srmc_spread > 0.0
    # Rank-based spread factors (cv18): thermal units ordered by p_max
    # (desc, code tiebreak) get equally-spaced factors in 1 ∓ spread —
    # the largest unit prices cheapest. Physically grounded (bigger CCGTs
    # are newer/more efficient as a rule) and draw-free: a hash draw was
    # measured at ±0.1 corr variance across seeds on IT-CSOUTH (0.51–0.71)
    # — the mechanism helped under EVERY draw, but the per-zone outcome
    # depended on luck; ranking removes the luck and is bit-reproducible.
    unit_spread_factor = Dict{String,Float64}()
    if apply_unit_spread
        # Canonical fixed assignment: unsalted FNV-1a draw per unit code.
        # Deterministic permutation schemes were measured and rejected —
        # ANY fixed ordering has same-parity/adjacency clusters, and the
        # units that pin a zone's price can land in one cluster (IT-CSOUTH
        # collapsed to stock under both monotone and interleaved ranking,
        # while every hash draw improved it, 0.51–0.71 across salts). The
        # unsalted draw is arbitrary-but-fixed (bit-reproducible across
        # runs and Julia versions); inferred heat rates replace it when
        # unit history supports them.
        for g in generators
            g.fuel_type in srmc_exempt_fuels && continue
            unit_spread_factor[g.code] =
                1.0 + profile.unit_srmc_spread * (2.0 * _unit_hash01(g.code) - 1.0)
        end
    end
    if !isempty(derate_scale) || apply_srmc_premium || apply_nuclear_floor
        generators = [begin
            s = get(derate_scale, g.fuel_type, 1.0)
            m = (apply_srmc_premium && !(g.fuel_type in srmc_exempt_fuels)) ?
                thermal_srmc_multiplier : 1.0
            mc = g.marginal_cost * m
            if apply_nuclear_floor && g.fuel_type == Symbol("Nuclear")
                mc = max(mc, nuclear_srmc_floor)
            end
            (s < 1.0 || mc != g.marginal_cost) ?
                Generator(g.code, g.name, g.fuel_type, g.location,
                          g.p_max * s, g.p_min * s,
                          g.bidding_zone, mc,
                          g.ramp_up, g.ramp_down, g.min_uptime, g.min_downtime) :
                g
        end for g in generators]
    end
    return generators, unit_spread_factor, apply_unit_spread
end

"""
Stage 2 — turn raw load/RES rows into per-timeslot MW dictionaries on the
clearing grid: temporal disaggregation, down-aggregation to hourly or
piecewise-constant upsampling to the shared finer grid, then the scenario
load/renewable modifiers. Returns
`(target_timeslots, load_by_time, renewable_by_time, resolution_minutes)`.
"""
function _demand_series(loads, renewables,
    target_resolution_minutes::Union{Int,Nothing},
    load_modifier::Union{Nothing,Function},
    renewable_modifier::Union{Nothing,Function})
    target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
        disaggregate_temporal_data(loads, renewables)

    # Resolution harmonization for multi-zone books: zones publish at
    # different resolutions (e.g. RO/HU 15-min, GR/BG hourly) and a
    # combined book with mixed timeslots isolates the hourly zones in
    # sub-hour slots. Aggregate MW values to the coarser target by
    # averaging sub-slots (MW is power — averaging preserves energy).
    if target_resolution_minutes !== nothing && resolution_minutes < target_resolution_minutes
        target_resolution_minutes == 60 ||
            error("Only hourly (60) target resolution is supported for down-aggregation, got $target_resolution_minutes")
        hour_key(ts) = ts[1:11] * "00"
        function aggregate_to_hours(d::Dict{String,Float64})
            sums = Dict{String,Tuple{Float64,Int}}()
            for (ts, v) in d
                k = hour_key(ts)
                s, n = get(sums, k, (0.0, 0))
                sums[k] = (s + v, n + 1)
            end
            return Dict{String,Float64}(k => s / n for (k, (s, n)) in sums)
        end
        load_by_time = aggregate_to_hours(load_by_time)
        renewable_by_time = aggregate_to_hours(renewable_by_time)
        target_timeslots = sort(collect(keys(load_by_time)))
        println("  🕐 Aggregated $(resolution_minutes)-min data to hourly ($(length(target_timeslots)) slots)")
        resolution_minutes = target_resolution_minutes
    elseif target_resolution_minutes !== nothing && resolution_minutes > target_resolution_minutes
        # UPSAMPLE (piecewise-constant REPLICATION) to a finer target grid.
        # A zone whose native data is coarser than the shared clearing grid
        # (e.g. an hourly PT60M zone in a 15-min clear) has each native
        # slot's MW LEVEL copied into every finer sub-slot it spans.
        # Load and generation are power levels (MW), NOT energy (MWh): a
        # plant offering 500 MW offers 500 MW in each quarter — the energy
        # divides naturally because the period is shorter, but the level is
        # unchanged. DIVIDING by the sub-slot count would quarter both
        # demand and supply and misprice everything. Downstream per-slot
        # computations (scarcity margin, water value, demand orders, net
        # imports which are hour-keyed) then run on the shared finer grid
        # exactly as they would for a natively-fine zone.
        target_resolution_minutes in (15, 30) ||
            error("Only 15 or 30-min target resolution is supported for up-replication, got $target_resolution_minutes")
        load_by_time = replicate_to_finer_resolution(load_by_time, resolution_minutes, target_resolution_minutes)
        renewable_by_time = replicate_to_finer_resolution(renewable_by_time, resolution_minutes, target_resolution_minutes)
        target_timeslots = sort(collect(keys(load_by_time)))
        println("  🕐 Upsampled $(resolution_minutes)-min data to $(target_resolution_minutes)-min " *
                "($(length(target_timeslots)) slots) by piecewise-constant replication")
        resolution_minutes = target_resolution_minutes
    end

    # Scenario demand/supply modifiers, applied at the SOURCE dictionaries
    # (after disaggregation and any hourly aggregation) so the change
    # propagates to net demand, scarcity margin, water value and demand
    # orders. No-op when the hooks are nothing.
    if load_modifier !== nothing
        for ts in keys(load_by_time)
            load_by_time[ts] = load_modifier(ts, load_by_time[ts])
        end
    end
    if renewable_modifier !== nothing
        for ts in keys(renewable_by_time)
            renewable_by_time[ts] = renewable_modifier(ts, renewable_by_time[ts])
        end
    end
    return target_timeslots, load_by_time, renewable_by_time, resolution_minutes
end

"""
Stage 4 — hydro fleet state: offered-quantity scale (recent-output cap or,
for `:reservoir_opportunity` zones, reservoir fullness), dryness (reservoir
levels vs seasonal norm, output-based fallback) and the seasonal drawdown
signal. Returns `(hydro_pmax, hydro_scale, hydro_dryness, reservoir_drawdown)`.
"""
function _hydro_state(generators::Vector{Generator}, bidding_zone::String,
    day::Date, hydro_model::Symbol, seasonal_drawdown::Bool)
    hydro_pmax = sum((g.p_max for g in generators if _is_hydro(g)); init=0.0)
    hydro_scale = 1.0   # offered-quantity cap (fraction of nameplate)
    hydro_dryness = 0.0 # 0 = normal water conditions, →1 = severe drought
    reservoir_drawdown = 0.0 # 0 = reservoir at seasonal peak, →1 = drawn down
    if hydro_pmax > 1.0
        hydro_avail = get_hydro_availability(bidding_zone, day)
        if hydro_avail !== nothing
            hydro_scale = clamp(hydro_avail / hydro_pmax, 0.2, 1.0)
        end
        # Dryness: prefer reservoir filling levels vs seasonal norm
        # (measures the water itself); fall back to recent-vs-1y output
        # when filling data is unavailable for the zone. Output-based
        # dryness is confounded by dispatch incentive: hydro running
        # hard because prices are high looks "wet" while reservoirs
        # are actually draining.
        reservoir_dryness = get_reservoir_dryness(bidding_zone, day)
        if reservoir_dryness !== nothing
            hydro_dryness = reservoir_dryness
        elseif hydro_avail !== nothing
            # Fallback only when no reservoir filling data: the 365-day
            # output norm is an expensive near-full scan of the per-type
            # table, so compute it lazily here rather than unconditionally.
            hydro_norm = get_hydro_availability(bidding_zone, day; lookback_days=365)
            if hydro_norm !== nothing && hydro_norm > 1.0
                hydro_dryness = clamp(1.0 - hydro_avail / hydro_norm, 0.0, 1.0)
            end
        end
        # Reservoir-opportunity zones (Nordic) govern offered hydro QUANTITY
        # by reservoir level, not by recent output. The p95-output cap above
        # is a gas-world energy-limited heuristic; in a hydro-dominated,
        # capacity-rich system it spuriously starves the book (e.g. NO1's
        # standalone supply/demand ratio ≈ 0.95 → phantom shortage at the
        # cap) even when reservoirs are full. Tie the offered fraction to
        # reservoir fullness instead: full → near-nameplate, severe drought
        # → half (inflow-only). Scarcity here is priced through the water
        # value, not rationed through quantity.
        if hydro_model == :reservoir_opportunity
            hydro_scale = clamp(1.0 - hydro_dryness, 0.5, 1.0)
            # Seasonal water-value signal: the absolute reservoir drawdown
            # (vs the trailing-52-week peak) prices the water as scarcer
            # through winter even when the prior-year-relative dryness reads
            # ~0. Affects the PRICE (wv_frac below), never the offered
            # quantity. Only the non-anchored reservoir zones
            # (SE1/SE2/FI/DK1/DK2/NO4) reach the wv_frac branch — the
            # Norway/alpine :hydro-anchored zones price off the anchor.
            if seasonal_drawdown
                dd = get_reservoir_drawdown(bidding_zone, day)
                dd !== nothing && (reservoir_drawdown = dd)
            end
        end
        println("  💧 Hydro: offer scale $(round(hydro_scale, digits=2)), " *
                "dryness $(round(hydro_dryness, digits=2))" *
                (reservoir_dryness !== nothing ? " (reservoir levels)" : " (output-based fallback)") *
                (hydro_model == :reservoir_opportunity ? " [reservoir-opportunity]" : ""))
    end
    return hydro_pmax, hydro_scale, hydro_dryness, reservoir_drawdown
end

"""
Stage 5 — UC-lite committed set: the cheapest eligible thermal units whose
derated capacity covers the day's peak residual demand. Only these units
self-schedule their minimum load in the order loop.
"""
function _committed_set(generators::Vector{Generator}, peak_residual::Float64,
    gas_srmc::Float64, must_run_srmc_threshold::Float64,
    availability_factor::Float64)
    committed = Set{String}()
    eligible = sort(
        [g for g in generators
         if !(g.fuel_type in WATER_VALUE_FUEL_TYPES) &&
            g.marginal_cost <= must_run_srmc_threshold * gas_srmc &&
            g.p_min > 0.1],
        by=g -> g.marginal_cost)
    cum_capacity = 0.0
    for g in eligible
        cum_capacity >= 1.05 * peak_residual && break
        push!(committed, g.code)
        cum_capacity += availability_factor * g.p_max
    end
    return committed
end

"""
    create_merit_order_book(bidding_zone::String, day::Date; kwargs...)

Create a deterministic merit-order-based order book for MPCC clearing.

# Keyword arguments (bidding strategy parameters)
- `tranches`: supply tranches as (capacity share, price multiplier on SRMC)
- `scarcity_threshold`: capacity margin below which scarcity markup kicks in
- `scarcity_kappa`: quadratic scarcity markup coefficient
- `water_value_base` / `water_value_span`: hydro opportunity cost as a
  multiple of gas SRMC, scaled across the day's demand range
- `demand_elastic_share` / `demand_elastic_price`: size and price of the
  price-sensitive demand tail
- `price_cap`: price of the inelastic demand tranche
- `fleet_completion`: add aggregate capacity where the type's recent output
  (p95) exceeds the unit-level fleet (under-reported fleets: RO/BG/RS)
- `fleet_truthing` / `derate_headroom`: derate baseload types whose
  unit-level fleet exceeds `derate_headroom ×` recent p95 — phantom
  capacity from unfiled derates or fuel constraints (2022 GR lignite)

# Scenario hooks (all default `nothing`; when all are `nothing` the code path
# is byte-identical to the no-kwargs call)
- `load_modifier::Union{Nothing,Function}`: `f(timeslot::String, load_mw::Float64) -> Float64`,
  applied to every entry of `load_by_time` at the source (after temporal
  disaggregation and any hourly aggregation), so the change propagates to net
  demand, scarcity margin, water value and demand orders.
- `renewable_modifier::Union{Nothing,Function}`: same signature, applied to
  `renewable_by_time` at the same point (e.g. `(ts, v) -> v + 300` during
  daylight slots models +300 MW of solar).
- `extra_orders::Union{Nothing,Function}`: `f(ctx) -> Vector{SimpleOrder}`,
  called after all standard orders are built and BEFORE merging. `ctx` is a
  NamedTuple `(zone, day, timeslots, resolution_minutes, load_by_time,
  renewable_by_time)`. Returned orders (`:supply` or `:demand`) are appended
  (tagged `"EXTRA"`). Models "ships request more power" (cap-priced demand) or
  "a new plant" (supply).
- `strategist::Union{Nothing,Function}`: `f(ctx) -> Vector{Tuple{SimpleOrder,String}}`
  (a plain `Vector{SimpleOrder}` is also accepted and re-tagged `"STRATEGIST"`),
  called after `extra_orders` and before merging. `ctx` is a NamedTuple
  `(tagged_orders, zone, day, timeslots, load_by_time, renewable_by_time,
  firm_of)` where `firm_of` is a `Dict{String,String}` unit_code→firm from
  `simulations.unit_firms`. The returned set REPLACES the tagged order list.

  Example — "what if the incumbent PPC marked up its peakers' top tranches 20%?":
  ```julia
  strat = ctx -> [ (firm_of_ppc(ctx, o, tag) ? bump(o) : o, tag)
                   for (o, tag) in ctx.tagged_orders ]
  ```
  A strategist that finds all orders whose `firm_of[tag] == "PPC"` and
  multiplies their two top tranche prices by 1.2, returning everything else
  unchanged.
- `fleet_modifier::Union{Nothing,Function}`: `f(zone::String, gens::Vector{Generator}) -> Vector{Generator}`,
  a first-class capacity primitive — add, remove or derate physical units as
  DATA (not orders). Called AFTER fleet completion and fleet-truthing, so a
  removed unit is not re-added by the `:installed`/p95 truth-up and the offered
  fleet is exactly what the modifier returns (scenario edits are physical
  reality changes; truthing runs on the pre-scenario registry). Returning an
  empty vector fails the build gracefully.

Both the single-zone (`:merit_order`) `generate_energy_prices` path and the
multi-zone `run_multi_zone_market_clearing(...; scenario=...)` path thread these
hooks (the latter via `ZoneScenario`). When every hook is `nothing` the built
book is byte-identical to the no-hook book.
"""
function create_merit_order_book(
    bidding_zone::String,
    day::Date;
    profile::ZoneProfile=SEE_PROFILE,
    tranches::Union{Nothing,Vector{Tuple{Float64,Float64}}}=nothing,
    must_run_price_factor::Union{Nothing,Float64}=nothing,
    must_run_srmc_threshold::Union{Nothing,Float64}=nothing,
    availability_factor::Union{Nothing,Float64}=nothing,
    scarcity_threshold::Union{Nothing,Float64}=nothing,
    scarcity_kappa::Union{Nothing,Float64}=nothing,
    peak_kappa::Union{Nothing,Float64}=nothing,
    peak_exponent::Union{Nothing,Float64}=nothing,
    water_value_base::Union{Nothing,Float64}=nothing,
    water_value_dry_boost::Union{Nothing,Float64}=nothing,
    water_value_span::Union{Nothing,Float64}=nothing,
    demand_elastic_share::Union{Nothing,Float64}=nothing,
    demand_elastic_price::Union{Nothing,Float64}=nothing,
    price_cap::Union{Nothing,Float64}=nothing,
    include_net_imports::Bool=true,
    net_import_exclude::Vector{String}=String[],
    net_import_import_only::Vector{String}=String[],
    target_resolution_minutes::Union{Int,Nothing}=nothing,
    fleet_completion::Union{Nothing,Bool}=nothing,
    fleet_truthing::Union{Nothing,Bool}=nothing,
    derate_headroom::Union{Nothing,Float64}=nothing,
    thermal_srmc_multiplier::Union{Nothing,Float64}=nothing,
    hydro_model::Union{Nothing,Symbol}=nothing,
    nuclear_srmc_floor::Union{Nothing,Float64}=nothing,
    opportunity_anchor::Union{Nothing,Symbol}=nothing,
    anchor_share::Union{Nothing,Float64}=nothing,
    anchor_prices::Union{Nothing,Dict{String,Float64}}=nothing,
    anchor_export_mw::Dict{Int,Float64}=Dict{Int,Float64}(),
    res_coalesce_missing::Bool=false,
    load_modifier::Union{Nothing,Function}=nothing,
    renewable_modifier::Union{Nothing,Function}=nothing,
    extra_orders::Union{Nothing,Function}=nothing,
    strategist::Union{Nothing,Function}=nothing,
    fleet_modifier::Union{Nothing,Function}=nothing
)
    # Resolve every bid parameter from the profile, letting an explicit keyword
    # override its profile field. With no overrides and the default SEE_PROFILE
    # this reproduces the pre-abstraction defaults exactly (byte-identical).
    tranches = tranches === nothing ? profile.tranches : tranches
    must_run_price_factor = must_run_price_factor === nothing ? profile.must_run_price_factor : must_run_price_factor
    must_run_srmc_threshold = must_run_srmc_threshold === nothing ? profile.must_run_srmc_threshold : must_run_srmc_threshold
    availability_factor = availability_factor === nothing ? profile.availability_factor : availability_factor
    scarcity_threshold = scarcity_threshold === nothing ? profile.scarcity_threshold : scarcity_threshold
    scarcity_kappa = scarcity_kappa === nothing ? profile.scarcity_kappa : scarcity_kappa
    peak_kappa = peak_kappa === nothing ? profile.peak_kappa : peak_kappa
    peak_exponent = peak_exponent === nothing ? profile.peak_exponent : peak_exponent
    water_value_base = water_value_base === nothing ? profile.water_value_base : water_value_base
    water_value_dry_boost = water_value_dry_boost === nothing ? profile.water_value_dry_boost : water_value_dry_boost
    water_value_span = water_value_span === nothing ? profile.water_value_span : water_value_span
    demand_elastic_share = demand_elastic_share === nothing ? profile.demand_elastic_share : demand_elastic_share
    demand_elastic_price = demand_elastic_price === nothing ? profile.demand_elastic_price : demand_elastic_price
    price_cap = price_cap === nothing ? profile.price_cap : price_cap
    fleet_completion = fleet_completion === nothing ? profile.fleet_completion : fleet_completion
    fleet_truthing = fleet_truthing === nothing ? profile.fleet_truthing : fleet_truthing
    derate_headroom = derate_headroom === nothing ? profile.derate_headroom : derate_headroom
    thermal_srmc_multiplier = thermal_srmc_multiplier === nothing ? profile.thermal_srmc_multiplier : thermal_srmc_multiplier
    hydro_model = hydro_model === nothing ? profile.hydro_model : hydro_model
    nuclear_srmc_floor = nuclear_srmc_floor === nothing ? profile.nuclear_srmc_floor : nuclear_srmc_floor
    opportunity_anchor = opportunity_anchor === nothing ? profile.opportunity_anchor : opportunity_anchor
    anchor_share = anchor_share === nothing ? profile.anchor_share : anchor_share
    # The opportunity anchor is active only when BOTH the profile opts in AND
    # pass-1 reference prices were supplied (two-pass clearing, pass 2). With
    # either missing the whole mechanism is dead code — pass 1 and every
    # single-pass path (incl. SEE) are unchanged.
    anchor_active = opportunity_anchor != :none && anchor_prices !== nothing

    try
        println("📊 Creating merit-order order book for $bidding_zone on $day")

        generators = get_generators(bidding_zone, day)

        # ── Stage 1: true up + price the offered fleet ──────────────────
        generators, unit_spread_factor, apply_unit_spread =
            _true_up_fleet(generators, bidding_zone, day, profile;
                fleet_completion, fleet_truthing, derate_headroom,
                thermal_srmc_multiplier, nuclear_srmc_floor,
                anchor_active, opportunity_anchor)

        # Scenario fleet_modifier — add / remove / derate physical units as
        # DATA. Applied AFTER fleet completion and fleet-truthing (above) on
        # purpose: those two mechanisms true the registry to the zone's
        # recently-observed capability, and they must run on the PRE-scenario
        # registry. If the modifier ran first, removing a 500 MW unit would
        # enlarge the completion gap and the `:installed`/p95 truth-up would
        # silently re-add the same aggregate MW — nullifying the edit. Running
        # it last makes scenario edits genuine "physical reality changes": the
        # offered fleet reflects exactly what the modifier returns. No-op when
        # the hook is nothing (byte-identical).
        if fleet_modifier !== nothing
            generators = collect(fleet_modifier(bidding_zone, generators))
            eltype(generators) <: Generator ||
                error("fleet_modifier must return a Vector{Generator}, got eltype $(eltype(generators))")
            isempty(generators) &&
                return AdjustedOrderBookResult(false,
                    "fleet_modifier removed all generators", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        loads = get_loads(bidding_zone, day)
        renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day;
            coalesce_missing=res_coalesce_missing)

        if isempty(generators)
            return AdjustedOrderBookResult(false, "No generators found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        if isempty(loads)
            return AdjustedOrderBookResult(false, "No load data found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end

        # ── Stage 2: load/RES series on the clearing grid ───────────────
        target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
            _demand_series(loads, renewables, target_resolution_minutes,
                load_modifier, renewable_modifier)

        # ── Stage 3: net imports, demand state, gas anchor, backstop ────
        # Residual demand per slot (load minus renewables) drives water value
        # and scarcity. Renewables themselves are offered as near-zero-price
        # supply below, NOT netted from demand — this lets prices collapse
        # toward zero in renewable-surplus hours, as they do in reality.
        # Net physical imports as fixed injections: observed cross-border
        # schedules (positive = import). A single zone cleared in isolation
        # systematically overprices import hours and underprices export
        # hours; using the observed schedule is the standard single-zone
        # backtesting treatment. Set include_net_imports=false for a pure
        # isolated-zone simulation (or when forecasting without flow data).
        net_imports = include_net_imports ?
                      get_net_imports(bidding_zone, day;
                          exclude_counterparties=net_import_exclude,
                          import_only_counterparties=net_import_import_only) :
                      Dict{Int,Float64}()
        slot_import(ts) = get(net_imports, Dates.hour(parse_timeslot_to_datetime(ts, day)), 0.0)

        gross_demand = Dict{String,Float64}()
        net_demand = Dict{String,Float64}()
        for ts in target_timeslots
            load_value = get(load_by_time, ts, 0.0)
            renewable_gen = get(renewable_by_time, ts, 0.0)
            gross_demand[ts] = max(10.0, load_value)
            # Residual demand on domestic thermal: load - RES - net imports
            net_demand[ts] = max(10.0, load_value - renewable_gen - slot_import(ts))
        end
        nd_values = [net_demand[ts] for ts in target_timeslots]
        nd_min, nd_max = minimum(nd_values), maximum(nd_values)
        nd_span = max(nd_max - nd_min, 1.0)

        # Gas SRMC anchors hydro water value (TTF-based when data exists)
        gas_srmc = get_marginal_cost(day, "Fossil Gas", bidding_zone)

        # Ex-ante elastic import backstop (cv17, profile-gated — see the
        # `import_backstop` field docstring). Computed next to the :v2 flow
        # climatology off the same cached day relations; the offered ATC of
        # the ENDOGENOUS borders (net_import_exclude — kept-ATC neighbors plus
        # shadowed aggregate codes, whose aggregate-coded ATC the remap already
        # carries endogenously) is subtracted so MPCC-deliverable capacity is
        # never double-counted. Empty Dict for every non-backstop profile —
        # byte-identical books.
        backstop_by_hour = (profile.import_backstop && include_net_imports) ?
            get_import_backstop(bidding_zone, day;
                weeks=profile.backstop_weeks,
                endogenous_counterparties=net_import_exclude) :
            Dict{Int,Float64}()
        backstop_price = profile.backstop_price_mult * gas_srmc
        isempty(backstop_by_hour) ||
            println("  🛟 Import backstop: peak $(round(Int, maximum(values(backstop_by_hour)))) MW " *
                    "@ €$(round(backstop_price, digits=1))/MWh " *
                    "($(length(backstop_by_hour)) hours, $(profile.backstop_weeks)-week window)")

        # ── Stage 4: hydro fleet state (offer scale, dryness, drawdown) ──
        hydro_pmax, hydro_scale, hydro_dryness, reservoir_drawdown =
            _hydro_state(generators, bidding_zone, day, hydro_model,
                profile.seasonal_drawdown)
        offered_pmax(g) = _is_hydro(g) ? g.p_max * hydro_scale : g.p_max

        # Dispatchable capacity for the scarcity margin, derated for the
        # realistic availability of the fleet (unreported outages) and for
        # the hydro energy limit — nameplate capacity never looks scarce.
        dispatchable_capacity =
            availability_factor * sum((g.p_max for g in generators if !_is_hydro(g)); init=0.0) +
            hydro_scale * hydro_pmax

        # Available import capacity per UTC hour, credited into the scarcity
        # margin when the profile opts in (thermal import/export zones). 0 = off.
        import_atc_by_hour = profile.scarcity_import_credit > 0.0 ?
            get_import_atc_capacity(bidding_zone, day) : Dict{Int,Float64}()

        # ── Stage 5: UC-lite committed set (peak-covering cheap thermal) ─
        committed = _committed_set(generators, nd_max, gas_srmc,
            must_run_srmc_threshold, availability_factor)

        # ── Stage 6: the supply order loop (RES, imports, hydro, thermal) ─
        # Every order is tagged with an owner (Feature 5, strategist hook):
        # the generator code for unit orders, "RES" for the renewable
        # forecast, "IMPORT" for net-import injections, "DEMAND" for demand
        # orders, "EXTRA" for extra_orders, "STRATEGIST" for strategist
        # replacements. Tags never affect the SimpleOrder values, so with no
        # hooks the merged book is byte-identical to before.
        tagged = Tuple{SimpleOrder,String}[]
        supply_orders_count = 0
        demand_orders_count = 0
        total_demand_quantity = 0.0
        total_supply_capacity = 0.0

        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)
            hr = Dates.hour(date_time)   # UTC hour key for all hour-keyed lookups

            # Renewable forecast offered at near-zero price (RES bids as
            # price-taker; support schemes make it insensitive to price)
            res_qty = get(renewable_by_time, ts, 0.0)
            if res_qty > 0.1
                push!(tagged, (SimpleOrder(:supply, 1.0, res_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "RES"))
                supply_orders_count += 1
                total_supply_capacity += res_qty
            end

            # Net imports as price-taking supply (imports) or firm extra
            # demand (exports) — scheduled flows are committed either way
            ni = get(net_imports, hr, 0.0)
            if ni > 0.1
                # :hydro-anchored zones (pass 2): observed imports arrive at
                # the BORDER price, not free — pricing them near zero lets the
                # import block set near-zero clearing prices in every
                # import-covered hour (NO1's flat undershoot: sim ≈ €3 at
                # night vs actual ≈ €88 tracking its neighbors). Priced at the
                # anchor level the import-marginal hours clear at the coupled
                # reference, as they do in reality. Everywhere else imports
                # stay price-taking at €1 (unchanged).
                import_price = (anchor_active && opportunity_anchor == :hydro &&
                                haskey(anchor_prices, ts)) ?
                               clamp(anchor_share * anchor_prices[ts], 1.0, gas_srmc) : 1.0
                push!(tagged, (SimpleOrder(:supply, import_price, ni,
                    Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                supply_orders_count += 1
                total_supply_capacity += ni
            elseif ni < -0.1
                # cv17 ref-priced retained-border exports (profile-gated,
                # pass 2 only): a net export over RETAINED borders (SI–HR,
                # BE–GB) enters as demand at the coupled/anchor reference
                # instead of firm at the cap, so the exporter curtails under
                # domestic stress like a real one — the demand-side mirror of
                # the dropped-border anchor_export_mw treatment. Everywhere
                # else (and in pass 1) the export stays cap-priced firm demand.
                export_price = (profile.ref_priced_exports && anchor_active &&
                                haskey(anchor_prices, ts)) ?
                               max(anchor_prices[ts], 1.0) : price_cap
                push!(tagged, (SimpleOrder(:demand, export_price, -ni,
                    Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                demand_orders_count += 1
                total_demand_quantity += -ni
            end

            # cv17 import-backstop supply block (profile-gated; empty Dict
            # otherwise). Priced above every domestic tranche multiplier, so
            # it binds only when the book would otherwise jump to the cap.
            backstop_qty = get(backstop_by_hour, hr, 0.0)
            if backstop_qty > 1.0
                push!(tagged, (SimpleOrder(:supply, backstop_price, backstop_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "BACKSTOP"))
                supply_orders_count += 1
                total_supply_capacity += backstop_qty
            end

            # :hydro-anchored zones (pass 2): the export volume observed over
            # the DROPPED flow-based borders re-enters as demand priced at the
            # coupled reference — NOT the cap. NO5 is the measured case: a
            # structural exporter whose import-only clamp removed the export
            # outlet entirely, collapsing its surplus onto a tiny local load
            # (sim €36 vs actual €104). Ref-priced demand clears only when the
            # zone's price is at/below the coupled price, so it cannot
            # manufacture cap scarcity; and it is SEPARATE from the clamped
            # import supply, so it cannot net away import energy either
            # (measured failure mode of netting: NO1 −23 → +134).
            if anchor_active && opportunity_anchor == :hydro &&
               haskey(anchor_prices, ts) && !isempty(anchor_export_mw)
                ex_mw = get(anchor_export_mw, hr, 0.0)
                if ex_mw > 0.1
                    push!(tagged, (SimpleOrder(:demand, max(anchor_prices[ts], 1.0),
                        ex_mw, Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                    demand_orders_count += 1
                    total_demand_quantity += ex_mw
                end
            end

            # Normalized within-day demand position (0 = trough, 1 = peak)
            norm_demand = (net_demand[ts] - nd_min) / nd_span

            # Markup on upper supply tranches: absolute scarcity (capacity
            # margin below threshold) plus peak-hour strategic bidding —
            # participants know when the daily peak is and price their last
            # tranches accordingly, even when capacity is formally adequate.
            # The high exponent concentrates the markup in the true peak
            # hours: at norm_demand 0.5 (e.g. summer nights, where residual
            # demand is mid-range) the markup is ~6% of peak_kappa, not 25%.
            # Credit available import capacity (gated): a zone that can import
            # GWs is not domestically scarce. Only the scarcity term is relieved;
            # the peak strategic-bidding term is left intact.
            import_credit = profile.scarcity_import_credit > 0.0 ?
                profile.scarcity_import_credit *
                get(import_atc_by_hour, hr, 0.0) : 0.0
            # cv17: gated scarcity credit for the backstop quantity (the
            # scarcity MARKUP cannot otherwise see the backstop supply, so
            # restored-import days can keep a residual markup overshoot).
            # 0 (default) = off everywhere.
            backstop_credit = profile.backstop_scarcity_credit > 0.0 ?
                profile.backstop_scarcity_credit *
                get(backstop_by_hour, hr, 0.0) : 0.0
            margin = (dispatchable_capacity + import_credit + backstop_credit) / net_demand[ts]
            scarcity = 1.0 +
                       scarcity_kappa * max(0.0, scarcity_threshold - margin)^2 +
                       peak_kappa * norm_demand^peak_exponent

            for g in generators
                if g.fuel_type in WATER_VALUE_FUEL_TYPES
                    # Hydro water value. Two models:
                    #
                    # :gas_anchored (SEE default) — opportunity cost tied to gas
                    # SRMC: cheap relative to gas off-peak, premium over gas at
                    # the peak, boosted in dry periods. Correct where hydro
                    # competes against a gas-set margin.
                    #
                    # :reservoir_opportunity (Nordic) — in a hydro-dominated
                    # zone the price is the shadow value of stored water, NOT a
                    # gas anchor: near-free when reservoirs are full, rising
                    # toward the continental thermal alternative (gas SRMC as a
                    # proxy for the export-market price) as they empty. This
                    # stops full Nordic reservoirs from slamming into scarcity/
                    # cap prices.
                    # :hydro opportunity anchor (two-pass, pass 2): stored
                    # water prices at the export opportunity — the pass-1
                    # coupled reference price (level AND hourly shape) — times
                    # a share slightly below 1 when reservoirs are full
                    # (willing to undercut the continent to export), rising
                    # with dryness. Clamped to [2, gas SRMC].
                    water_value = if anchor_active && opportunity_anchor == :hydro &&
                                     haskey(anchor_prices, ts)
                        clamp(anchor_prices[ts] *
                              (anchor_share + water_value_dry_boost * hydro_dryness),
                              2.0, gas_srmc)
                    elseif hydro_model == :reservoir_opportunity
                        # Stored water is worth a FRACTION of the continental
                        # thermal price (gas SRMC proxy): an export-opportunity
                        # floor (~0.35×) when reservoirs are full, rising to the
                        # full thermal alternative (1.0×) as they empty. Then
                        # shaped by within-day demand. NOT gas-anchored at parity
                        # — full Nordic reservoirs price well below gas, which is
                        # what stops the scarcity/cap blow-up.
                        # Floor rises with EITHER prior-year dryness OR the
                        # absolute seasonal drawdown (winter reservoir depletion
                        # raises the shadow value of stored water — SE1/SE2 draw
                        # to 55–60% of the annual peak by February at dryness 0).
                        wv_frac = 0.35 + 0.65 * max(hydro_dryness, reservoir_drawdown)
                        gas_srmc * wv_frac * (water_value_base + water_value_span * norm_demand)
                    else
                        gas_srmc * (1.0 + water_value_dry_boost * hydro_dryness) *
                        (water_value_base + water_value_span * norm_demand)
                    end
                    push!(tagged, (SimpleOrder(:supply, water_value, offered_pmax(g),
                        Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                    supply_orders_count += 1
                    total_supply_capacity += offered_pmax(g)
                else
                    # :nuclear opportunity anchor (two-pass, pass 2): nuclear's
                    # effective bid base per slot is the export opportunity —
                    # anchor_share × the pass-1 coupled reference price —
                    # floored at fuel SRMC. It rises with the coupled price on
                    # weekday nights and COLLAPSES with it in RES-surplus hours
                    # (weekends/midday), which a static floor cannot do.
                    # Everywhere else gmc ≡ g.marginal_cost.
                    gmc = (anchor_active && opportunity_anchor == :nuclear &&
                           g.fuel_type == Symbol("Nuclear") &&
                           haskey(anchor_prices, ts)) ?
                          max(g.marginal_cost, anchor_share * anchor_prices[ts]) :
                          g.marginal_cost
                    # cv18 per-unit SRMC spread: order prices only (must-run
                    # blocks + tranches scale together via gmc); the must-run
                    # SELECTION above used the unsprayed costs, exactly like
                    # the validated prototype.
                    if apply_unit_spread
                        gmc *= get(unit_spread_factor, g.code, 1.0)
                    end
                    # Must-run self-scheduling: baseload-ish units (SRMC not
                    # far above gas) bid their minimum-load block near zero —
                    # shutting down and restarting costs more than running a
                    # few hours below cost. This is what lets midday prices
                    # collapse below thermal SRMC in renewable-surplus hours.
                    must_run_qty = 0.0
                    if g.code in committed
                        must_run_qty = min(g.p_min, offered_pmax(g))
                        # Graduated self-scheduling: the deepest block is
                        # near-free (never shut down), the rest bids below
                        # cost — real curves are convex, not a cliff. The
                        # below-cost discount is ABSOLUTE (startup-cost
                        # amortization is €/MWh over the p_min hours, not a
                        # fraction of fuel cost): a proportional 0.5×SRMC
                        # discount is benign at gas ≈ 90 (−45) but capped
                        # crisis evenings at half the real gas cost
                        # (−212 at TTF 218, 2022) and sank the whole year.
                        deep_qty = must_run_qty * 0.6
                        push!(tagged, (SimpleOrder(:supply,
                            gmc * must_run_price_factor, deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        push!(tagged, (SimpleOrder(:supply,
                            max(gmc * 0.5, gmc - 40.0),
                            must_run_qty - deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        supply_orders_count += 2
                        total_supply_capacity += must_run_qty
                    end

                    # Remaining capacity: tranche ladder on SRMC, scarcity
                    # markup on the upper tranches (first tranche stays at
                    # cost so mid-merit keeps clearing)
                    flexible_capacity = max(offered_pmax(g) - must_run_qty, 0.0)
                    for (i, (share, mult)) in enumerate(tranches)
                        price = gmc * mult * (i == 1 ? 1.0 : scarcity)
                        qty = flexible_capacity * share
                        qty < 0.1 && continue
                        push!(tagged, (SimpleOrder(:supply, price, qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        supply_orders_count += 1
                        total_supply_capacity += qty
                    end
                end
            end
        end

        # ── Stage 7: demand orders ──────────────────────────────────────
        # Demand: inelastic tranche at the cap + small price-sensitive tail
        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)
            gd = gross_demand[ts]

            inelastic_qty = gd * (1.0 - demand_elastic_share)
            push!(tagged, (SimpleOrder(:demand, price_cap, inelastic_qty,
                Symbol(bidding_zone), date_time, resolution_minutes), "DEMAND"))
            demand_orders_count += 1

            elastic_qty = gd * demand_elastic_share
            if elastic_qty > 0.1
                push!(tagged, (SimpleOrder(:demand, demand_elastic_price, elastic_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "DEMAND"))
                demand_orders_count += 1
            end
            # Export-absorption ladder (cv18): elastic demand below the thermal
            # band that binds only in RES-surplus hours — see the profile field
            # docstring. Tagged distinctly so the bids view can label it.
            for (step_price, step_mw) in profile.export_absorption_steps
                push!(tagged, (SimpleOrder(:demand, step_price, step_mw,
                    Symbol(bidding_zone), date_time, resolution_minutes), "EXPORT_ABS"))
                demand_orders_count += 1
            end
            total_demand_quantity += gd
        end

        # ── Stage 8: scenario hooks (extra_orders, strategist) ──────────
        # Feature 3/4: extra scenario orders appended after all standard
        # orders and BEFORE merging. Both :supply and :demand are allowed.
        if extra_orders !== nothing
            ctx = (zone=bidding_zone, day=day, timeslots=target_timeslots,
                   resolution_minutes=resolution_minutes,
                   load_by_time=load_by_time, renewable_by_time=renewable_by_time)
            for o in extra_orders(ctx)
                push!(tagged, (o, "EXTRA"))
                if o.type == :supply
                    supply_orders_count += 1
                    total_supply_capacity += o.quantity
                else
                    demand_orders_count += 1
                    total_demand_quantity += o.quantity
                end
            end
        end

        # Feature 5: strategist hook, called after extra_orders and before
        # merging. It receives the full tagged order list plus a unit→firm
        # map and RETURNS the replacement tagged list.
        if strategist !== nothing
            firm_of = get_firm_of(bidding_zone)
            sctx = (tagged_orders=tagged, zone=bidding_zone, day=day,
                    timeslots=target_timeslots, load_by_time=load_by_time,
                    renewable_by_time=renewable_by_time, firm_of=firm_of)
            result = strategist(sctx)
            # Accept either Vector{Tuple{SimpleOrder,String}} or a plain
            # Vector{SimpleOrder} (re-tagged "STRATEGIST").
            tagged = Tuple{SimpleOrder,String}[
                x isa Tuple ? (x[1], x[2]) : (x, "STRATEGIST") for x in result]
            # Recount from the replacement set so summary stats stay accurate
            supply_orders_count = count(t -> t[1].type == :supply, tagged)
            demand_orders_count = count(t -> t[1].type == :demand, tagged)
            total_supply_capacity = sum((t[1].quantity for t in tagged if t[1].type == :supply); init=0.0)
            total_demand_quantity = sum((t[1].quantity for t in tagged if t[1].type == :demand); init=0.0)
        end

        # Optional book sink (default nothing = byte-identical no-op): a
        # callback receiving the FULL tagged order list right before merging —
        # the same view the strategist hook gets. Used by the book-export
        # feature to persist per-owner bid ladders for analysis/transparency;
        # in two-pass clears the harness overwrites per (zone, day), so the
        # final (pass-2) book wins. Errors in the sink must never break a
        # clear — swallowed with a warning.
        if BOOK_SINK[] !== nothing
            try
                BOOK_SINK[](bidding_zone, day, tagged, resolution_minutes)
            catch e
                @warn "BOOK_SINK failed (book still cleared)" zone = bidding_zone day error = sprint(showerror, e)
            end
        end

        orders = SimpleOrder[t[1] for t in tagged]

        # ── Stage 9: merge identical blocks + assemble the MPCC book ────
        # Merge orders with identical (type, price, timeslot): all units of a
        # fuel type bid the same SRMC-derived tranche prices, so a zone-day
        # book collapses ~6x with market-equivalent clearing (partial
        # acceptance of a merged block ≡ distributing it among the
        # identically-priced originals). This directly cuts the MPCC binary
        # count, which is what limits multi-zone solve times.
        merged = Dict{Tuple{Symbol,Float64,DateTime},Float64}()
        for o in orders
            key = (o.type, round(o.price, digits=2), o.date_time)
            merged[key] = get(merged, key, 0.0) + o.quantity
        end
        pre_merge_count = length(orders)
        orders = [SimpleOrder(t, p, q, Symbol(bidding_zone), dt, resolution_minutes)
                  for ((t, p, dt), q) in merged]
        println("  🔗 Merged $(pre_merge_count) orders into $(length(orders)) price-distinct blocks")

        nodes = [bidding_zone]
        # EU day-ahead floor is -500; ceiling is the demand cap so shortage
        # hours can price exactly at the cap
        price_limits = (-500.0, price_cap)
        order_book = MPCCOrderBook(orders, nodes, target_timeslots, price_limits, nothing)

        supply_per_slot = total_supply_capacity / length(target_timeslots)
        demand_per_slot = total_demand_quantity / length(target_timeslots)
        ratio = demand_per_slot > 0 ? supply_per_slot / demand_per_slot : 0.0

        println("  ✅ Merit-order book: $supply_orders_count supply / $demand_orders_count demand orders")
        println("     ⚖️  Supply/Demand ratio: $(round(ratio, digits=2))  (gas SRMC €$(round(gas_srmc, digits=1))/MWh)")

        return AdjustedOrderBookResult(
            true, "Merit-order book created successfully", order_book,
            length(generators), demand_orders_count, supply_orders_count,
            total_demand_quantity, total_supply_capacity, ratio)

    catch e
        e isa InterruptException && rethrow()
        error_msg = "Error creating merit-order book: $(sprint(showerror, e))"
        println("  ❌ $error_msg")
        return AdjustedOrderBookResult(false, error_msg, nothing, 0, 0, 0, 0.0, 0.0, 0.0)
    end
end
