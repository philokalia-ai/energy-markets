# iterative.jl — Iterative UC-MPCC clearing: UC <-> MPCC feedback loop until prices converge.
# Included by ../Euphemia.jl inside `module Euphemia` (definition order preserved).

"""
    run_iterative_multi_zone_market_clearing(date; kwargs...) -> NamedTuple

Run multi-zone market clearing with iterative UC-MPCC to account for
interconnection flows in unit commitment decisions.

The algorithm iterates between:
1. Solving UC for each zone (with adjusted demand based on expected flows)
2. Running MPCC to determine actual market flows
3. Updating expected flows based on MPCC results

Iteration continues until prices converge or max iterations reached.

# Convergence Criterion

**Primary: Price-based convergence** (recommended by market coupling theory)

Convergence is declared when: `max|λᶻ(k) − λᶻ(k−1)| < price_tolerance`

Price-based convergence is preferred over flow-based because:
- Prices are the economic fixed point of market coupling
- Flows are derived quantities that can oscillate near binding constraints
- UC binaries cause discontinuous flow changes even when prices are stable
- This matches how real market coupling (e.g., Euphemia) operates

Flow changes are logged as diagnostics but not used for convergence.

# Arguments
- `date::Date`: Market date
- `zones::Vector{String}`: Zones to include (empty = auto-discover)
- `optimizer::String`: Solver for MPCC ("highs" or "gurobi")
- `max_iterations::Int`: Maximum iteration count (default: 10)
- `price_tolerance::Float64`: Max price change for convergence in €/MWh (default: 1.0)
- `damping_factor::Float64`: Update damping α ∈ (0,1] (default: 0.7)
- `markup_factor::Float64`: Bid markup over marginal cost (default: 1.1)
- `silent::Bool`: Suppress solver output (default: true)
- `save_to_db::Bool`: Save final results to database (default: false)
- `parallel::Bool`: Parallelize UC across zones within each iteration (default: false)

# Returns
NamedTuple with all MPCCResult fields plus:
- `iterations::Int`: Number of iterations performed
- `converged::Bool`: Whether convergence was achieved
- `final_net_imports::Dict`: Final net imports per zone
- `convergence_metrics::NamedTuple`: Detailed convergence info (price_change, flow_change_pct)

# Caching Behavior
- Each iteration uses `force_rerun=true` to ensure fresh UC solves
- Only the final converged result is retained in cache (DELETE-before-INSERT)
- No database pollution: one cache entry per (zone, date, version)

# Example
```julia
result = run_iterative_multi_zone_market_clearing(
    Date(2025, 12, 10);
    zones=["GR", "IT-NORTH", "IT-SOUTH"],
    optimizer="gurobi",
    max_iterations=10,
    price_tolerance=1.0,  # €/MWh
    parallel=false  # Respect Gurobi license limits
)

println("Converged: \$(result.converged) in \$(result.iterations) iterations")
println("Final price change: \$(result.convergence_metrics.price_change) €/MWh")
```

See also: [`run_multi_zone_market_clearing`](@ref), [`compute_max_price_change`](@ref)
"""
function run_iterative_multi_zone_market_clearing(date::Date;
    zones::Vector{String}=String[],
    optimizer::String="auto",
    max_iterations::Int=10,
    price_tolerance::Float64=1.0,
    damping_factor::Float64=0.7,
    markup_factor::Float64=1.1,
    silent::Bool=true,
    save_to_db::Bool=false,
    parallel::Bool=false,
    max_workers::Union{Int, Nothing}=nothing
)
    total_start_time = time()

    println("\n" * "=" ^ 60)
    println("🔄 ITERATIVE MULTI-ZONE MARKET CLEARING")
    println("=" ^ 60)
    println("📅 Date: $date")
    println("⚙️  Max iterations: $max_iterations")
    println("💰 Price tolerance: $price_tolerance €/MWh")
    println("🎚️  Damping factor: $damping_factor")
    if parallel
        workers_info = isnothing(max_workers) ? "all available" : "max $max_workers"
        println("⚡ Parallel: enabled ($workers_info workers)")
    end

    # Discover zones if not provided
    if isempty(zones)
        zones = Network.get_zones_with_transfer_capacity(date)
        println("📍 Auto-discovered $(length(zones)) zones with transfer capacity")
    else
        println("📍 Using $(length(zones)) specified zones: $(join(zones, ", "))")
    end

    if length(zones) < 2
        error("Iterative UC-MPCC requires at least 2 zones")
    end

    # NOTE: Transfer capacities (ATC) are loaded internally by create_multi_zone_order_book()
    # from entsoe.offered_transfer_capacities_implicit - no explicit loading needed here

    # Initialize iteration state
    expected_net_imports = nothing  # No adjustment for iteration 1
    previous_prices = nothing
    previous_flows = nothing
    best_result = nothing
    order_book = nothing
    converged = false
    iteration = 0
    final_price_change = Inf
    final_flow_change_pct = Inf

    for iter in 1:max_iterations
        iteration = iter
        iter_start_time = time()
        println("\n" * "-" ^ 40)
        println("📊 Iteration $iter / $max_iterations")

        # Step 1: Create order book with current flow expectations
        # Always use force_rerun=true to get fresh UC with current flow adjustments
        order_book = MPCC.create_multi_zone_order_book(zones, date;
            markup_factor=markup_factor,
            optimizer=optimizer,
            use_cache=true,
            force_rerun=true,  # Always fresh solve
            parallel=parallel,
            max_workers=max_workers,
            net_imports_by_zone=expected_net_imports
        )

        # Step 2: Solve MPCC
        mpcc_start = time()
        result = MPCC.solve_mpcc_market_clearing(order_book;
            preferred_solver=optimizer,
            silent=silent
        )
        mpcc_time = time() - mpcc_start

        if result.status != :optimal
            @warn "MPCC failed at iteration $iter with status: $(result.status)"
            if best_result !== nothing
                println("⚠️  Returning best result from previous iteration")
                break
            else
                error("MPCC failed on first iteration: $(result.status)")
            end
        end

        best_result = result

        # Step 3: Compute convergence metrics
        # Primary: Price-based convergence (economic fixed point)
        price_change = MPCC.compute_max_price_change(result.market_prices, previous_prices)

        # Secondary (diagnostic): Relative flow change
        flow_change_pct = MPCC.compute_max_relative_flow_change(result.transmission_flows, previous_flows) * 100

        # Also compute net imports for UC adjustment
        actual_net_imports = MPCC.compute_net_imports_from_flows(result.transmission_flows, zones)

        iter_time = time() - iter_start_time

        # Log metrics
        println("   MPCC solve: $(round(mpcc_time, digits=2))s")
        println("   💰 Price change: $(round(price_change, digits=2)) €/MWh")
        println("   🔌 Flow change: $(round(flow_change_pct, digits=1))% (diagnostic)")
        println("   Iteration time: $(round(iter_time, digits=2))s")

        # Store final metrics
        final_price_change = price_change
        final_flow_change_pct = flow_change_pct

        # Step 4: Check convergence (price-based)
        if price_change < price_tolerance
            converged = true
            println("✅ Converged! Price change $(round(price_change, digits=2)) €/MWh < tolerance $price_tolerance €/MWh")
            break
        end

        # Step 5: Apply damping and update expected flows for next iteration
        previous_prices = result.market_prices
        previous_flows = result.transmission_flows
        expected_net_imports = MPCC.apply_damping(actual_net_imports, expected_net_imports, damping_factor)
    end

    total_time = time() - total_start_time

    println("\n" * "-" ^ 40)
    if converged
        println("✅ CONVERGED in $iteration iterations")
        println("   💰 Final price change: $(round(final_price_change, digits=2)) €/MWh")
        println("   🔌 Final flow change: $(round(final_flow_change_pct, digits=1))%")
    else
        println("⚠️  Did NOT converge after $iteration iterations")
        println("   💰 Final price change: $(round(final_price_change, digits=2)) €/MWh (tolerance: $price_tolerance)")
    end
    println("⏱️  Total time: $(round(total_time, digits=2))s")

    # Save to database if requested (only final result)
    if save_to_db && best_result !== nothing && best_result.status == :optimal
        println("\n💾 Saving final results to database...")
        try
            # Save optimization run record first and get the ID
            # Include iterative metadata for later analysis
            optimization_run_id = save_optimization_run(
                "MULTI_ZONE_ITERATIVE",  # Use special identifier for iterative runs
                date,
                :uc_based,
                :mpcc_iterative,
                best_result.solver_name,
                best_result.status;
                objective_value=best_result.objective_value,
                solve_time_seconds=best_result.solve_time,
                num_orders=length(order_book.orders),
                num_price_periods=length(order_book.periods),
                # Iterative optimization metadata
                is_iterative=true,
                total_time_seconds=total_time,
                iterations=iteration,
                converged=converged,
                final_price_change=final_price_change,
                final_flow_change_pct=final_flow_change_pct
            )

            # Save prices for each zone with the optimization run ID
            for zone in zones
                if haskey(best_result.market_prices, zone)
                    save_energy_prices(best_result.market_prices[zone], zone, date, :uc_based;
                                       clearing_mode="multi_zone_iterative",
                                       optimization_run_id=optimization_run_id)
                end
            end

            # Save transmission flows
            if !isempty(best_result.transmission_flows)
                save_transmission_flows(best_result.transmission_flows, date)
            end

            println("   ✅ Results saved to database")
        catch e
            @error "Failed to save results to database: $e"
        end
    end

    # Return enriched result
    return (
        # All MPCCResult fields
        status=best_result.status,
        objective_value=best_result.objective_value,
        market_prices=best_result.market_prices,
        stepwise_acceptance=best_result.stepwise_acceptance,
        block_acceptance=best_result.block_acceptance,
        block_activation=best_result.block_activation,
        transmission_flows=best_result.transmission_flows,
        solve_time=best_result.solve_time,
        total_time=total_time,
        solver_name=best_result.solver_name,
        message=best_result.message,
        # Additional iteration metadata
        iterations=iteration,
        converged=converged,
        final_net_imports=expected_net_imports,
        convergence_metrics=(
            price_change=final_price_change,
            flow_change_pct=final_flow_change_pct
        )
    )
end

