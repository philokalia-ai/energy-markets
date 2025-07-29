#!/usr/bin/env julia

# Test script for the BiddingStrategy module
# This demonstrates how to convert UC results to market orders

using Pkg
Pkg.activate(".")

using Dates

# Include modules in dependency order
include("../src/dbutils.jl")
include("../src/Euphemia.jl")  # Database interface
include("../src/MarketOrders.jl")

# Include modules that depend on external libraries
include("../src/Loads.jl")
include("../src/Renewables.jl")
include("../src/FuelTypeParameters.jl")  # Fuel parameters
include("../src/Generators.jl")
include("../src/UnitCommitment.jl")
include("../src/BiddingStrategy.jl")

using .BiddingStrategy: generate_market_orders_from_uc, print_orders_summary, export_orders_to_csv

function test_bidding_strategy()
    println("🚀 Testing Bidding Strategy Module")
    println("="^50)

    # Test parameters
    bidding_zone = "GR"
    day = Date("2018-06-24")

    println("📊 Generating market orders for $bidding_zone on $day")

    # Generate market orders from unit commitment
    result = generate_market_orders_from_uc(bidding_zone, day)

    # Print summary
    print_orders_summary(result)

    if result.success
        # Export to CSV for analysis
        csv_path = "/tmp/market_orders_$(bidding_zone)_$(day).csv"
        export_orders_to_csv(result, csv_path)

        # Show first few orders as examples
        println("\n📋 Sample Supply Orders:")
        for (i, order) in enumerate(result.supply_orders[1:min(3, length(result.supply_orders))])
            println("  $i. $(order.quantity) MW @ €$(round(order.price, digits=2))/MWh ($(order.zone))")
        end

        println("\n📋 Sample Demand Orders:")
        for (i, order) in enumerate(result.demand_orders[1:min(3, length(result.demand_orders))])
            println("  $i. $(order.quantity) MW @ €$(round(order.price, digits=2))/MWh ($(order.zone))")
        end

        # Basic validation
        println("\n🔍 Validation:")
        supply_total = sum(order.quantity for order in result.supply_orders)
        demand_total = sum(order.quantity for order in result.demand_orders)
        balance_diff = abs(supply_total - demand_total)

        println("  Total supply: $(round(supply_total, digits=1)) MW")
        println("  Total demand: $(round(demand_total, digits=1)) MW")
        println("  Balance difference: $(round(balance_diff, digits=1)) MW")

        if balance_diff < 1.0  # Within 1 MW tolerance
            println("  ✅ Supply-demand balance looks good!")
        else
            println("  ⚠️  Supply-demand imbalance detected")
        end
    end

    return result
end

# Run the test if this script is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    test_bidding_strategy()
end
