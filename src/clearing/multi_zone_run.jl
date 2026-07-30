# multi_zone_run.jl — run_multi_zone_market_clearing — clear one date across a footprint (one- or two-pass).
# Included by ../Euphemia.jl inside `module Euphemia` (definition order preserved).

"""
    run_multi_zone_market_clearing(date::Date;
                                   zones::Vector{String}=String[],
                                   order_method::Symbol=:merit_order,
                                   optimizer::String="auto",
                                   markup_factor::Float64=1.1,
                                   silent::Bool=true,
                                   save_to_db::Bool=false,
                                   force_rerun::Bool=false,
                                   parallel::Bool=false)

Run simultaneous multi-zone market clearing with cross-border transmission flows.

Unlike `generate_energy_prices_for_all_zones()` which processes zones independently,
this function solves all zones together in a single optimization problem with
transmission flow constraints between zones based on ENTSO-E ATC data.

# Arguments
- `date::Date`: The date for which to run market clearing
- `zones::Vector{String}`: List of bidding zones to include (default: auto-discover from DB)
- `order_method::Symbol`: only `:merit_order` (the UC-based and alternative books were removed in cv25) (default: `:merit_order`)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for supply bids (default: 1.1)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `save_to_db::Bool`: Whether to save results to database (default: false)
- `force_rerun::Bool`: Whether to force UC re-solve, bypassing cache (default: false)
- `parallel::Bool`: Whether to run UC for each zone in parallel using Distributed.jl (default: false)

# Returns
- `MPCCResult`: Market clearing results including:
  - `market_prices`: Dict of prices per zone per time period
  - `transmission_flows`: Dict of cross-border flows per zone pair per period
  - `status`: Optimization status (:optimal, :infeasible, etc.)
  - `solve_time`: Time taken to solve the optimization

# Example
```julia
using Euphemia, Dates

# Auto-discover zones and run multi-zone clearing
result = run_multi_zone_market_clearing(Date(2024, 6, 15))

# Check zonal prices
for (zone, prices) in result.market_prices
    avg_price = mean(values(prices))
    println("\$zone: avg price = €\$(round(avg_price, digits=2))/MWh")
end

# Check transmission flows
for (flow_id, flows) in result.transmission_flows
    avg_flow = mean(values(flows))
    println("\$flow_id: avg flow = \$(round(avg_flow, digits=1)) MW")
end

# Run with specific zones
result = run_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "BG", "IT_SOUTH"],
    save_to_db=true)
```

# Notes
- Zones must have transfer capacity data in `entsoe.offered_transfer_capacities_implicit`
- Zones without UC data will be skipped with a warning
- ATC constraints bound flows: -backward_cap ≤ flow ≤ forward_cap
- Transmission is modeled as lossless (no losses on flows)
"""
function run_multi_zone_market_clearing(date::Date;
                                        zones::Vector{String}=String[],
                                        order_method::Symbol=:merit_order,
                                        optimizer::String="auto",
                                        markup_factor::Float64=1.1,
                                        silent::Bool=true,
                                        save_to_db::Bool=false,
                                        force_rerun::Bool=false,
                                        parallel::Bool=false,
                                        max_workers::Union{Int, Nothing}=nothing,
                                        clearing_mode::String="multi_zone",
                                        enrich_network::Bool=false,
                                        apply_zone_profiles::Bool=true,
                                        passes::Int=1,
                                        # Temporal resolution of the coupled
                                        # clear. Default 60 (24 hourly periods)
                                        # is byte-identical to the pre-existing
                                        # path. Set 15 for a 96-period 15-minute
                                        # clear: each zone's book is built on the
                                        # shared 15-min grid, with coarser
                                        # (hourly) zones replicated up per the
                                        # replicate-not-divide rule. Merit-order
                                        # path only.
                                        clear_resolution_minutes::Int=60,
                                        # Ex-ante flow mode for this run.
                                        # nothing (default) resolves to:
                                        #   :v2 on the EU-footprint path
                                        #        (enrich_network + merit_order)
                                        #        — the forward product —
                                        #   the process-wide FLOW_ASOF_MODE
                                        #        otherwise (:d0 unless env
                                        #        EUPHEMIA_FLOW_ASOF_MODE set),
                                        # so SEE legacy paths (5-zone
                                        # multi_zone, enrich_network=false)
                                        # keep same-day flows byte-identical.
                                        # An explicit env value always wins.
                                        ex_ante_mode::Union{Nothing,Symbol}=nothing,
                                        # MPCC solver budget. Defaults unchanged
                                        # (900 s / 1e-6). HiGHS needs a longer
                                        # budget than Gurobi to find a first
                                        # incumbent on the 39-zone MIP — see
                                        # bin/reproduce.jl.
                                        mpcc_time_limit::Float64=900.0,
                                        mpcc_mip_gap::Float64=1e-6,
                                        mpcc_heuristic_effort::Union{Float64,Nothing}=nothing,
                                        # Per-period decomposition of the coupled
                                        # MPCC. The clear has no inter-temporal
                                        # coupling, so solving each period
                                        # independently yields the same clear while
                                        # shrinking each MIP by ~1/N_periods.
                                        # `nothing` (default) applies the cv20
                                        # policy: decomposed is the CANONICAL mode
                                        # on the EU-footprint path (enriched
                                        # network + :merit_order) for EVERY solver
                                        # — it is bit-identical across solvers,
                                        # making the published record
                                        # solver-invariant. It differs from the
                                        # monolithic clear only on degenerate
                                        # pass-2 anchor ties (10/29,679 hourly
                                        # cells over the 39-day A/B; scores
                                        # statistically identical). All other
                                        # paths (SEE 5-zone, non-enriched) stay
                                        # monolithic — byte-identical to the
                                        # legacy record. Pass true/false to force.
                                        decompose_periods::Union{Nothing,Bool}=nothing,
                                        # Counterfactual scenario (merit-order
                                        # path only). Either one `ZoneScenario`
                                        # applied to every zone (hooks gate on
                                        # `ctx.zone`) or a `Dict{String,ZoneScenario}`
                                        # for per-zone targeting. `nothing` ⇒
                                        # byte-identical to the no-scenario run.
                                        scenario::Union{Nothing,ZoneScenario,Dict{String,ZoneScenario}}=nothing)

    start_time = time()
    # Resolve the ex-ante flow mode (scoped :v3 default, cv19): the
    # EU-footprint path (enriched network, merit order) defaults to the
    # anad2 :v3 flow rule (analogue x D-2 blend — measured better than :v2
    # in every window, docs/experiments/analogue-flows); every other path
    # keeps the process-wide mode (:d0 same-day unless the env set
    # otherwise). Explicit kwarg > explicit env > scoped default. Restored
    # in the finally at function end. Version scope: cv16..18 saves used
    # :v2, the cv15 backfill :d0.
    # cv25 fix 2: one resolver owns the scoped default (mz_resolve_flow_mode);
    # the wrapper adds only its :merit_order condition on top.
    prev_flow_mode = MeritOrderBook.FLOW_ASOF_MODE[]
    resolved_flow_mode = ex_ante_mode !== nothing ? ex_ante_mode :
        (order_method == :merit_order ? first(mz_resolve_flow_mode(enrich_network)) :
         prev_flow_mode)
    MeritOrderBook.FLOW_ASOF_MODE[] = resolved_flow_mode
    resolved_flow_mode != prev_flow_mode &&
        println("   🔮 Ex-ante flow mode: $resolved_flow_mode (scoped default)")

    # Resolve the period-decomposition policy (cv20): decomposed is the
    # canonical mode on the EU-footprint path for every solver (bit-identical
    # across Gurobi/HiGHS — the record becomes solver-invariant, and HiGHS can
    # actually solve it: the monolithic 39-zone MIP finds no HiGHS incumbent
    # in 20+ min). Non-enriched paths stay monolithic so the SEE legacy record
    # keeps its byte-identity. An explicit kwarg wins over the policy.
    resolved_decompose = decompose_periods !== nothing ? decompose_periods :
        (enrich_network && order_method == :merit_order)
    resolved_decompose &&
        println("   🧩 Period-decomposition ENABLED (per-period independent clears; " *
                "policy: $(decompose_periods === nothing ? "canonical on the EU path" : "explicit"))")
    try
    # Label the optimization_runs row so a non-standard footprint (e.g. the
    # Europe-wide "multi_zone_eu" experiment) does not collide with the standard
    # "MULTI_ZONE" run for the same date. Default preserves prior behaviour.
    run_zone_label = clearing_mode == "multi_zone" ? "MULTI_ZONE" :
                     "MULTI_ZONE_" * uppercase(replace(clearing_mode, "multi_zone_" => ""))

    println("=" ^ 60)
    println("🌍 MULTI-ZONE MARKET CLEARING WITH TRANSMISSION FLOWS")
    println("   Date: $date")
    println("=" ^ 60)

    # Discover zones if not provided
    if isempty(zones)
        println("\n🔍 Discovering available zones from transfer capacity data...")
        zones = Network.get_zones_with_transfer_capacity(date)

        if isempty(zones)
            error("No zones found in transfer capacity data for $date")
        end
    end

    println("\n📋 Target zones: $(join(zones, ", "))")
    println("   📋 Order method: $order_method")

    # Create multi-zone order book based on order_method
    println("\n📊 Creating multi-zone order book...")
    order_method == :merit_order ||
        error("Invalid order_method: $order_method. Only :merit_order remains — the " *
              "UC-based and alternative books were removed in cv25.")
    # Merit-order: deterministic strategy-based books per zone, cross-zone flows
    # endogenous via ATC-constrained MPCC
    order_book = _create_multi_zone_order_book_merit(zones, date;
        enrich_network=enrich_network, apply_zone_profiles=apply_zone_profiles,
        clear_resolution_minutes=clear_resolution_minutes, scenario=scenario)

    # Run MPCC market clearing with transmission constraints
    println("\n⚡ Running multi-zone market clearing optimization...")
    mpcc_result = MPCC.solve_mpcc_market_clearing(order_book;
                                                   preferred_solver=optimizer,
                                                   silent=silent,
                                                   time_limit=mpcc_time_limit,
                                                   mip_gap=mpcc_mip_gap,
                                                   heuristic_effort=mpcc_heuristic_effort,
                                                   decompose_periods=resolved_decompose)

    # PER-DAY ROBUSTNESS FALLBACK (iter8). If the coupled MPCC stays
    # infeasible through the entire retry ladder (including the exact
    # indicator-form rung) and any zone's profile uses a non-:p95 fleet-truth
    # mode, re-clear the WHOLE day with baseline :p95 books (the measured
    # iter6 state) rather than ship a missing day. Implemented as a guarded
    # recursion with a process-wide override so pass 2's anchored rebuilds
    # inherit the same fleet truth. Loud by design.
    pass1_usable = mpcc_result.status == :optimal ||
                   (mpcc_result.status == :time_limit && !isempty(mpcc_result.market_prices))
    if !pass1_usable && order_method == :merit_order && apply_zone_profiles &&
       MeritOrderBook.FLEET_TRUTH_OVERRIDE[] === nothing &&
       any(MeritOrderBook.get_zone_profile(z).fleet_truth_mode != :p95 for z in zones)
        @warn "MPCC unusable after the full retry ladder (status=$(mpcc_result.status)) — " *
              "re-clearing $date with fleet_truth_mode=:p95 books (installed-fleet fallback)"
        MeritOrderBook.FLEET_TRUTH_OVERRIDE[] = :p95
        try
            return run_multi_zone_market_clearing(date;
                zones=zones, order_method=order_method, optimizer=optimizer,
                markup_factor=markup_factor, silent=silent, save_to_db=save_to_db,
                force_rerun=force_rerun, parallel=parallel, max_workers=max_workers,
                clearing_mode=clearing_mode, enrich_network=enrich_network,
                apply_zone_profiles=apply_zone_profiles, passes=passes,
                clear_resolution_minutes=clear_resolution_minutes,
                ex_ante_mode=resolved_flow_mode,
                mpcc_time_limit=mpcc_time_limit, mpcc_mip_gap=mpcc_mip_gap,
                mpcc_heuristic_effort=mpcc_heuristic_effort,
                decompose_periods=resolved_decompose, scenario=scenario)
        finally
            MeritOrderBook.FLEET_TRUTH_OVERRIDE[] = nothing
        end
    end

    # TWO-PASS opportunity-anchor clearing (opt-in via passes=2, merit-order
    # only). Pass 1 above cleared the standard books; zones whose profile
    # opts in (opportunity_anchor != :none — southern Norway :hydro, France
    # :nuclear) now re-bid their dominant modulating resource at opportunity
    # cost against the pass-1 coupled reference price, and the footprint is
    # re-cleared. Non-anchored zones reuse their pass-1 books verbatim. With
    # passes=1 (default) this block is dead code — SEE and the current EU
    # paths are unchanged.
    pass1_solve_time = mpcc_result.solve_time
    if passes >= 2 && order_method == :merit_order &&
       (mpcc_result.status == :optimal ||
        (mpcc_result.status == :time_limit && !isempty(mpcc_result.market_prices)))
        anchor_inputs = mz_extract_anchor_inputs(order_book, mpcc_result;
            apply_zone_profiles=apply_zone_profiles)
        if isempty(anchor_inputs.anchored)
            println("\n⚓ passes=$passes requested but no zone profile opts into an opportunity anchor — keeping pass-1 result")
        else
            println("\n⚓ PASS 2: opportunity-anchored re-clear for $(join(anchor_inputs.anchored, ", "))")
            order_book2 = mz_rebuild_anchored(zones, date,
                anchor_inputs.refs, anchor_inputs.cached;
                enrich_network=enrich_network,
                apply_zone_profiles=apply_zone_profiles,
                clear_resolution_minutes=clear_resolution_minutes,
                scenario=scenario)
            println("\n⚡ Running pass-2 market clearing optimization...")
            result2 = mz_solve_pass(order_book2;
                optimizer=optimizer, silent=silent,
                mpcc_time_limit=mpcc_time_limit, mpcc_mip_gap=mpcc_mip_gap,
                mpcc_heuristic_effort=mpcc_heuristic_effort,
                decompose_periods=resolved_decompose)
            if result2.status == :optimal ||
               (result2.status == :time_limit && !isempty(result2.market_prices))
                order_book = order_book2
                mpcc_result = result2
                println("   ⚓ Pass 2 accepted (status=$(result2.status), " *
                        "solve=$(round(result2.solve_time, digits=1))s; " *
                        "pass 1 was $(round(pass1_solve_time, digits=1))s)")
            else
                @warn "Pass-2 clearing failed (status=$(result2.status)) — falling back to pass-1 result"
            end
        end
    end

    total_time = time() - start_time

    # Update result with correct total_time (includes order book creation)
    result = MPCC.with_total_time(mpcc_result, total_time)

    # Report results
    println("\n" * "=" ^ 60)
    println("📊 MULTI-ZONE CLEARING RESULTS")
    println("=" ^ 60)
    println("   Status: $(result.status)")
    println("   Solve time: $(round(result.solve_time, digits=2))s (total: $(round(result.total_time, digits=2))s)")

    # A time-limited solve still returns its best incumbent — usable, but
    # the optimality gap is unproven, so warn loudly
    result.status == :time_limit && !isempty(result.market_prices) &&
        @warn "Multi-zone MPCC hit the solve time limit for $date — using best incumbent (optimality gap unproven; prices may contain tolerance artifacts)"
    if result.status == :optimal ||
       (result.status == :time_limit && !isempty(result.market_prices))
        println("   Objective value: $(round(result.objective_value, digits=2))")

        # Report zonal prices
        println("\n💰 Zonal Clearing Prices (avg):")
        for zone in order_book.nodes
            if haskey(result.market_prices, zone)
                prices = values(result.market_prices[zone])
                avg_price = isempty(prices) ? 0.0 : sum(prices) / length(prices)
                min_price = isempty(prices) ? 0.0 : minimum(prices)
                max_price = isempty(prices) ? 0.0 : maximum(prices)
                println("   $zone: avg=€$(round(avg_price, digits=2))/MWh (min=$(round(min_price, digits=2)), max=$(round(max_price, digits=2)))")
            end
        end

        # Report transmission flows
        if !isempty(result.transmission_flows)
            println("\n🔌 Cross-Border Flows (avg):")
            for (flow_id, flows) in result.transmission_flows
                flow_values = values(flows)
                avg_flow = isempty(flow_values) ? 0.0 : sum(flow_values) / length(flow_values)
                min_flow = isempty(flow_values) ? 0.0 : minimum(flow_values)
                max_flow = isempty(flow_values) ? 0.0 : maximum(flow_values)
                # Only print if there's significant flow
                if abs(avg_flow) > 0.1 || abs(max_flow) > 0.1
                    println("   $flow_id: avg=$(round(avg_flow, digits=1))MW (min=$(round(min_flow, digits=1)), max=$(round(max_flow, digits=1)))")
                end
            end
        end

        # Save to database if requested
        if save_to_db
            println("\n💾 Saving results to database...")
            try
                # Save optimization run record first and get the ID
                optimization_run_id = save_optimization_run(
                    run_zone_label,  # Special identifier for multi-zone runs (footprint-aware)
                    date,
                    order_method,
                    :mpcc_multi_zone,
                    result.solver_name,
                    result.status;
                    objective_value=result.objective_value,
                    solve_time_seconds=result.solve_time,
                    num_orders=length(order_book.orders),
                    num_price_periods=length(order_book.periods)
                )

                # Save prices for each zone with the optimization run ID
                for zone in order_book.nodes
                    if haskey(result.market_prices, zone)
                        save_energy_prices(result.market_prices[zone], zone, date, order_method;
                                           clearing_mode=clearing_mode,
                                           optimization_run_id=optimization_run_id)
                    end
                end

                # Save transmission flows
                if !isempty(result.transmission_flows)
                    save_transmission_flows(result.transmission_flows, date)
                end

                println("   ✅ Results saved to database")
            catch e
                @error "Failed to save results to database: $e"
            end
        end
    else
        println("   ⚠️  Optimization did not find optimal solution")
        println("   Message: $(result.message)")
    end

    println("\n" * "=" ^ 60)

    return result
    finally
        # Restore the process-wide ex-ante flow mode (see resolution at top).
        MeritOrderBook.FLOW_ASOF_MODE[] = prev_flow_mode
    end
end

