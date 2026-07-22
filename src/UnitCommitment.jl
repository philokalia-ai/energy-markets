using JuMP, Dates
using .Euphemia: select_solver
using .Euphemia: disaggregate_temporal_data
using .Euphemia: FLEXIBLE_FUEL_TYPES

# MOI is re-exported by JuMP
const MOI = JuMP.MOI

"""
    format_time(seconds::Float64) -> String

Formats time in seconds to a readable format (e.g., "5m 23s", "1h 2m 15s", "45s").
"""
function format_time(seconds::Float64)
    if seconds < 60
        return "$(round(seconds, digits=1))s"
    elseif seconds < 3600  # Less than 1 hour
        minutes = floor(Int, seconds / 60)
        remaining_seconds = seconds - minutes * 60
        if remaining_seconds < 1
            return "$(minutes)m"
        else
            return "$(minutes)m $(round(remaining_seconds, digits=1))s"
        end
    else  # 1 hour or more
        hours = floor(Int, seconds / 3600)
        remaining_seconds = seconds - hours * 3600
        minutes = floor(Int, remaining_seconds / 60)
        remaining_seconds = remaining_seconds - minutes * 60

        if minutes == 0 && remaining_seconds < 1
            return "$(hours)h"
        elseif remaining_seconds < 1
            return "$(hours)h $(minutes)m"
        else
            return "$(hours)h $(minutes)m $(round(remaining_seconds, digits=1))s"
        end
    end
end

function calculate_cost_breakdown(generators, g, u, v_θ, Θ, C_SU, C_NL, T, N)
    # Calculate per-generator costs (production only)
    generator_production_costs = Dict{String,Float64}()
    fuel_type_costs = Dict{Symbol,Float64}()
    period_costs = Float64[]  # Cost per time period (may be 15min, 30min, or 60min)

    # Production costs by generator
    for i in 1:N
        gen_total_cost = 0.0
        for t in 1:T
            cost = generators[i].marginal_cost * g[i, t]
            gen_total_cost += cost
        end
        generator_production_costs[generators[i].name] = gen_total_cost

        # Aggregate by fuel type
        fuel_type = generators[i].fuel_type
        if haskey(fuel_type_costs, fuel_type)
            fuel_type_costs[fuel_type] += gen_total_cost
        else
            fuel_type_costs[fuel_type] = gen_total_cost
        end
    end

    # Calculate total production cost
    total_production_cost = sum(values(generator_production_costs))

    # Calculate startup costs by temperature stage
    startup_costs = Dict{Symbol,Float64}(:hot => 0.0, :warm => 0.0, :cold => 0.0)
    for i in 1:N, θ in Θ, t in 1:T
        startup_costs[θ] += C_SU[(i, θ)] * v_θ[i, θ, t]
    end
    total_startup_cost = sum(values(startup_costs))

    # Calculate no-load costs
    total_noload_cost = sum(C_NL[i] * u[i, t] for i in 1:N, t in 1:T)

    # Calculate per-period total costs (production + startup + no-load)
    for t in 1:T
        production = sum(generators[i].marginal_cost * g[i, t] for i in 1:N)
        startup = sum(C_SU[(i, θ)] * v_θ[i, θ, t] for i in 1:N, θ in Θ)
        noload = sum(C_NL[i] * u[i, t] for i in 1:N)
        push!(period_costs, production + startup + noload)
    end

    # Calculate utilization statistics
    total_capacity = sum(gen.p_max for gen in generators)
    committed_capacity = sum(generators[i].p_max * sum(u[i, t] for t in 1:T) for i in 1:N) / T
    actual_generation = sum(g[i, t] for i in 1:N, t in 1:T) / T

    # Count startups by temperature
    startup_counts = Dict{Symbol,Int}(:hot => 0, :warm => 0, :cold => 0)
    for i in 1:N, θ in Θ, t in 1:T
        if v_θ[i, θ, t] > 0.5  # Binary variable
            startup_counts[θ] += 1
        end
    end

    return (
        generator_costs=generator_production_costs,
        fuel_type_costs=fuel_type_costs,
        period_costs=period_costs,
        total_capacity=total_capacity,
        avg_committed_capacity=committed_capacity,
        avg_generation=actual_generation,
        capacity_utilization=actual_generation / total_capacity,
        commitment_utilization=committed_capacity / total_capacity,
        # New cost breakdown fields
        production_cost=total_production_cost,
        startup_cost=total_startup_cost,
        startup_costs_by_type=startup_costs,
        startup_counts=startup_counts,
        noload_cost=total_noload_cost
    )
end

function print_cost_report(solution, day; resolution_minutes::Int=60)
    println("\n" * "="^60)
    println("UNIT COMMITMENT COST REPORT - $day")
    println("="^60)

    total_cost = solution.total_cost
    breakdown = solution.cost_breakdown
    num_periods = length(solution.time_slots)
    periods_per_hour = 60 / resolution_minutes

    println("OVERALL ECONOMICS")
    println("   Total cost: $(round(total_cost, digits=2)) EUR ($(round(total_cost/1e6, digits=2))M EUR)")
    println("   Average cost per period ($(resolution_minutes)min): $(round(total_cost/num_periods, digits=2)) EUR")
    println("   Cost per MWh generated: $(round(total_cost/sum(breakdown.avg_generation * num_periods / periods_per_hour), digits=2)) EUR")

    # Cost breakdown by component
    println("\nCOST COMPONENTS")
    println("   Production costs: $(round(breakdown.production_cost, digits=2)) EUR ($(round(breakdown.production_cost/total_cost*100, digits=1))%)")
    println("   Startup costs:    $(round(breakdown.startup_cost, digits=2)) EUR ($(round(breakdown.startup_cost/total_cost*100, digits=1))%)")
    println("      Hot startups:  $(breakdown.startup_counts[:hot]) @ $(round(breakdown.startup_costs_by_type[:hot], digits=2)) EUR")
    println("      Warm startups: $(breakdown.startup_counts[:warm]) @ $(round(breakdown.startup_costs_by_type[:warm], digits=2)) EUR")
    println("      Cold startups: $(breakdown.startup_counts[:cold]) @ $(round(breakdown.startup_costs_by_type[:cold], digits=2)) EUR")
    println("   No-load costs:    $(round(breakdown.noload_cost, digits=2)) EUR ($(round(breakdown.noload_cost/total_cost*100, digits=1))%)")

    # Curtailment info (if available)
    if hasproperty(solution, :curtailment) && sum(solution.curtailment) > 0.1
        curtailment_mwh = sum(solution.curtailment)
        curtailment_cost = solution.curtailment_cost
        println("   Curtailment cost: $(round(curtailment_cost, digits=2)) EUR ($(round(curtailment_cost/total_cost*100, digits=1))%)")
        println("      Total curtailed: $(round(curtailment_mwh, digits=1)) MWh")
    end

    println("\nCAPACITY & GENERATION")
    println("   Total installed capacity: $(round(breakdown.total_capacity)) MW")
    println("   Average committed capacity: $(round(breakdown.avg_committed_capacity)) MW")
    println("   Average generation: $(round(breakdown.avg_generation)) MW")
    println("   Capacity utilization: $(round(breakdown.capacity_utilization * 100, digits=1))%")
    println("   Commitment utilization: $(round(breakdown.commitment_utilization * 100, digits=1))%")

    println("\nPRODUCTION COSTS BY FUEL TYPE")
    sorted_fuel_costs = sort(collect(breakdown.fuel_type_costs), by=x -> x[2], rev=true)
    for (fuel_type, cost) in sorted_fuel_costs
        percentage = cost / breakdown.production_cost * 100
        println("   $(fuel_type): $(round(cost, digits=2)) EUR ($(round(percentage, digits=1))%)")
    end

    println("\nTOP GENERATOR PRODUCTION COSTS")
    sorted_gen_costs = sort(collect(breakdown.generator_costs), by=x -> x[2], rev=true)
    for (i, (gen_name, cost)) in enumerate(sorted_gen_costs[1:min(5, end)])
        percentage = cost / breakdown.production_cost * 100
        println("   $i. $gen_name: $(round(cost, digits=2)) EUR ($(round(percentage, digits=1))%)")
    end

    println("\nCOST PROFILE ($(resolution_minutes)min periods)")
    period_costs = breakdown.period_costs
    min_cost = minimum(period_costs)
    max_cost = maximum(period_costs)
    avg_cost = sum(period_costs) / length(period_costs)

    println("   Peak period cost: $(round(max_cost, digits=2)) EUR (period $(argmax(period_costs)))")
    println("   Minimum period cost: $(round(min_cost, digits=2)) EUR (period $(argmin(period_costs)))")
    println("   Average period cost: $(round(avg_cost, digits=2)) EUR")
    println("   Cost variability: $(round((max_cost-min_cost)/avg_cost * 100, digits=1))%")

    println("="^60)
end


# Split by concern; each file is `include`d in the original definition order,
# so the spliced code is line-for-line the pre-split UnitCommitment.jl.
include("uc/model.jl")  # solve_unit_commitment — the UC MILP build + solve + IIS diagnosis
include("uc/cache.jl")  # UC results caching (simulations.uc_results / uc_generation / uc_net_demand)
# Example usage function (can be called from tests)
function test_unit_commitment(
    bidding_zone="GR",
    day=Date("2018-06-24")
)

    println("Solving unit commitment for $bidding_zone on $day")
    solution = solve_unit_commitment(bidding_zone, day)

    if solution.status == OPTIMAL
        println("Solution found!")
        print_cost_report(solution, day; resolution_minutes=solution.resolution_minutes)
    else
        println("Optimization failed with status: ", solution.status)
    end

    return solution
end
