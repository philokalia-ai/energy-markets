#!/usr/bin/env julia

# Test script to compare all three bidding strategies
# This script demonstrates the differences between:
# 1. :committed_only - Conservative (only committed units)
# 2. :all_available_max - Maximum capacity (unrealistic but useful for testing)
# 3. :all_available_realistic - UC-informed realistic quantities

using Dates

# Add the src directory to the load path
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

# Load required modules
include("../src/dbutils.jl")
include("../src/FuelTypeParameters.jl")
include("../src/Generators.jl")
include("../src/Loads.jl")
include("../src/Renewables.jl")
include("../src/Orders.jl")
include("../src/MarketOrders.jl")
include("../src/Euphemia.jl")
include("../src/UnitCommitment.jl")
include("../src/BiddingStrategy.jl")

using .BiddingStrategy: generate_market_orders_from_uc, apply_bidding_strategy_to_uc, print_orders_summary
import Main: solve_unit_commitment

function compare_all_bidding_strategies()
    bidding_zone = "GR"
    test_day = Date("2018-06-24")

    println("🔄 TESTING ALL THREE BIDDING STRATEGIES (OPTIMIZED)")
    println("="^60)
    println("Zone: $bidding_zone")
    println("Date: $test_day")
    println()

    # ⚡ PERFORMANCE OPTIMIZATION: Solve UC only once!
    println("🚀 Solving Unit Commitment once (shared across all strategies)...")
    uc_solution = solve_unit_commitment(bidding_zone, test_day)

    if uc_solution.status != OPTIMAL
        println("❌ Unit commitment failed: $(uc_solution.status)")
        return []
    end

    println("✅ UC solved successfully! Now testing bidding strategies...")
    println()

    # Test all three strategies using the same UC solution
    strategies = [
        (:committed_only, "Conservative (Committed Only)"),
        (:all_available_max, "Maximum Capacity (All Units @ p_max)"),
        (:all_available_realistic, "Realistic (UC-Informed)")
    ]

    results = []

    for (strategy, description) in strategies
        println("📊 Testing Strategy: $description")
        println("-"^50)

        # Use the efficient function that doesn't re-solve UC
        result = apply_bidding_strategy_to_uc(
            uc_solution,  # Pre-solved UC result
            bidding_zone,
            test_day,
            bidding_strategy=strategy
        )

        if result.success
            push!(results, (strategy, description, result))

            # Extract key metrics
            supply_orders = result.supply_orders
            total_capacity = result.total_supply_quantity

            if !isempty(supply_orders)
                prices = [order.price for order in supply_orders]
                quantities = [order.quantity for order in supply_orders]
                avg_price = sum(prices .* quantities) / sum(quantities)

                println("✅ SUCCESS:")
                println("  Orders: $(length(supply_orders)) supply orders")
                println("  Total capacity: $(round(total_capacity, digits=1)) MW")
                println("  Price range: €$(round(minimum(prices), digits=2)) - €$(round(maximum(prices), digits=2))/MWh")
                println("  Avg price: €$(round(avg_price, digits=2))/MWh (quantity-weighted)")
            else
                println("⚠️  No supply orders generated")
            end
        else
            println("❌ FAILED: $(result.message)")
        end

        println()
    end

    # Comparative analysis
    if length(results) >= 2
        println("🔍 COMPARATIVE ANALYSIS")
        println("="^60)

        # Reference: committed_only strategy
        ref_result = nothing
        for (strategy, desc, result) in results
            if strategy == :committed_only
                ref_result = result
                break
            end
        end

        if ref_result !== nothing
            ref_capacity = ref_result.total_supply_quantity
            ref_orders = length(ref_result.supply_orders)

            println("📈 Capacity Increases vs Conservative Strategy:")
            for (strategy, desc, result) in results
                if strategy != :committed_only
                    capacity_increase = ((result.total_supply_quantity - ref_capacity) / ref_capacity) * 100
                    order_increase = ((length(result.supply_orders) - ref_orders) / ref_orders) * 100

                    println("  $(desc):")
                    println("    Capacity: +$(round(capacity_increase, digits=1))% ($(round(result.total_supply_quantity, digits=1)) vs $(round(ref_capacity, digits=1)) MW)")
                    println("    Orders: +$(round(order_increase, digits=1))% ($(length(result.supply_orders)) vs $(ref_orders) orders)")
                end
            end
        end

        # Market implications
        println()
        println("💡 MARKET IMPLICATIONS:")
        println("  Conservative: Respects UC constraints, may leave capacity unused")
        println("  Maximum: Tests theoretical market capacity, unrealistic but useful for bounds")
        println("  Realistic: Balances available capacity with operational constraints")
    end

    return results
end

function analyze_strategy_differences(results)
    if length(results) < 3
        println("⚠️  Need all three strategies to run detailed analysis")
        return
    end

    println()
    println("🔬 DETAILED STRATEGY ANALYSIS")
    println("="^60)

    # Extract results by strategy
    committed_result = nothing
    max_result = nothing
    realistic_result = nothing

    for (strategy, desc, result) in results
        if strategy == :committed_only
            committed_result = result
        elseif strategy == :all_available_max
            max_result = result
        elseif strategy == :all_available_realistic
            realistic_result = result
        end
    end

    if committed_result !== nothing && max_result !== nothing && realistic_result !== nothing
        # Calculate theoretical bounds
        committed_capacity = committed_result.total_supply_quantity
        max_capacity = max_result.total_supply_quantity
        realistic_capacity = realistic_result.total_supply_quantity

        println("📊 Capacity Utilization Analysis:")
        println("  Conservative baseline: $(round(committed_capacity, digits=1)) MW (100%)")
        println("  Realistic utilization: $(round(realistic_capacity, digits=1)) MW ($(round((realistic_capacity/committed_capacity)*100, digits=1))%)")
        println("  Theoretical maximum: $(round(max_capacity, digits=1)) MW ($(round((max_capacity/committed_capacity)*100, digits=1))%)")

        # Efficiency analysis
        realistic_efficiency = (realistic_capacity - committed_capacity) / (max_capacity - committed_capacity) * 100
        println()
        println("⚡ Strategy Efficiency:")
        println("  Realistic captures $(round(realistic_efficiency, digits=1))% of available headroom")
        println("  Headroom utilization: $(round(realistic_capacity - committed_capacity, digits=1)) MW of $(round(max_capacity - committed_capacity, digits=1)) MW potential")
    end
end

# Run the comparison
println("Starting three-way bidding strategy comparison...")
results = compare_all_bidding_strategies()
analyze_strategy_differences(results)

println()
println("✅ Three-way strategy comparison completed!")
