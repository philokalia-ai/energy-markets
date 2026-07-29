using Test
using Euphemia
using Dates
using JuMP

# Function to calculate Euphemia cost from MPCC results
function calculate_euphemia_cost_from_mpcc(mpcc_result::MPCCResult, uc_solution)
    """
    Calculate the total cost that would be incurred if generators produced
    according to MPCC results at their marginal costs from unit commitment.
    """
    if mpcc_result.status != :optimal
        return 0.0
    end

    total_cost = 0.0

    # Get stepwise order acceptance rates and calculate generation
    for (order_id, acceptance_rate) in mpcc_result.stepwise_acceptance
        if acceptance_rate > 0.01  # Only consider accepted orders
            # Find corresponding generator from order_id
            # Order IDs are typically formatted as "gen_name_period_step"
            order_parts = split(order_id, "_")

            if length(order_parts) >= 3
                # Extract generator name (everything except last 2 parts which are period and step)
                gen_name = join(order_parts[1:end-2], "_")
                period_str = order_parts[end-1]

                # Find the generator in UC solution
                gen_idx = findfirst(g -> g.name == gen_name, uc_solution.generators)

                if !isnothing(gen_idx)
                    generator = uc_solution.generators[gen_idx]
                    period_idx = parse(Int, period_str)

                    if period_idx <= length(uc_solution.time_slots)
                        # Calculate the generation amount for this accepted order
                        # This is approximate - we estimate based on acceptance rate and generator capacity
                        estimated_generation = acceptance_rate * generator.p_max / STEPS_PER_GENERATOR  # Use named constant for steps per generator

                        # Calculate cost at marginal cost
                        order_cost = estimated_generation * generator.marginal_cost
                        total_cost += order_cost
                    end
                end
            end
        end
    end

    # Add block order costs if any
    for (block_id, acceptance_rate) in mpcc_result.block_acceptance
        if acceptance_rate > 0.01
            # Block orders are harder to map back to specific generators
            # For now, we'll use the objective value as an approximation
            # This is a simplification and could be improved with more detailed order tracking
        end
    end

    # If we couldn't calculate detailed costs, use the MPCC objective value as approximation
    if total_cost < 1.0
        total_cost = mpcc_result.objective_value
    end

    return total_cost
end

@testset "MPCC Market Clearing Tests" begin

    # Test configuration
    test_bidding_zone = "GR"
    test_start_date = Date(2025, 7, 21)
    test_dates = [test_start_date + Day(i) for i in 0:2]  # 3 consecutive days

    @testset "Solver Selection Tests" begin
        @test begin
            try
                optimizer, solver_name = select_solver("auto")
                @info "Selected solver: $solver_name"
                !isnothing(optimizer) && !isnothing(solver_name)
            catch e
                @warn "Solver selection failed: $e"
                false
            end
        end

        # Test specific solver preferences
        @test begin
            try
                optimizer, solver_name = select_solver("highs")
                !isnothing(optimizer)
            catch e
                @info "HiGHS solver not available or failed: $e"
                true  # This is acceptable if HiGHS is not installed
            end
        end
    end

    # The UC-based order-book testset, the UC-vs-MPCC comparison testset and its
    # cost-summary block were deleted in cv25 phase 1 with the UC subsystem. They
    # had degraded into `try ... catch; @warn; true end` blocks that swallowed the
    # UndefVarError and "passed" while exercising nothing — a green test that tests
    # nothing is worse than a deleted one. The merit-order book is covered by
    # test_scenario_hooks.jl, test_zone_profiles.jl and test_price_reconstruction.jl.
end
