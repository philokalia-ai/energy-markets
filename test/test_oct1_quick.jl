#!/usr/bin/env julia

"""
Quick Test: UC-based Energy Price Generation for October 1st, 2024
=================================================================

Testing UC-based energy price generation for a small set of zones.
"""

using Pkg
Pkg.activate(".")

using Euphemia
using Dates
using Printf

# Configuration
const TEST_DATE = Date(2024, 10, 1)
const ORDER_METHOD = :uc_based
const MODEL = :mpcc
const OPTIMIZER = "highs"
const SAVE_TO_DB = true

# Test just a few zones first
const TEST_ZONES = ["GR", "AL", "AT", "FR", "DE_LU"]

function test_single_zone(zone::String)
    println("🏃 Testing zone: $zone")
    println("-"^40)

    start_time = time()

    try
        prices = generate_energy_prices(zone, TEST_DATE;
            order_method=ORDER_METHOD,
            model=MODEL,
            optimizer=OPTIMIZER,
            save_to_db=SAVE_TO_DB,
            silent=false)  # Show output for debugging

        elapsed = round(time() - start_time, digits=2)

        if length(prices) > 0
            min_price = round(minimum(values(prices)), digits=2)
            max_price = round(maximum(values(prices)), digits=2)
            avg_price = round(sum(values(prices)) / length(prices), digits=2)

            println("✅ SUCCESS: $zone ($(elapsed)s)")
            println("   💰 $(length(prices)) periods: €$min_price - €$max_price/MWh (avg: €$avg_price)")

            return (success=true, error=nothing, elapsed=elapsed, periods=length(prices),
                min_price=min_price, max_price=max_price, avg_price=avg_price)
        else
            println("⚠️  WARNING: $zone - No prices generated ($(elapsed)s)")
            return (success=false, error="No prices generated", elapsed=elapsed, periods=0,
                min_price=0.0, max_price=0.0, avg_price=0.0)
        end

    catch e
        elapsed = round(time() - start_time, digits=2)
        error_msg = string(e)
        println("❌ FAILED: $zone ($(elapsed)s)")
        println("   📝 Error: $(first(split(error_msg, '\n')))")

        return (success=false, error=error_msg, elapsed=elapsed, periods=0,
            min_price=0.0, max_price=0.0, avg_price=0.0)
    end
end

function main()
    println("🚀 QUICK TEST: UC-based Energy Prices for Oct 1st, 2024")
    println("="^60)
    println("📅 Date: $TEST_DATE")
    println("📋 Method: $ORDER_METHOD")
    println("⚖️  Model: $MODEL")
    println("🔧 Optimizer: $OPTIMIZER")
    println("🎯 Test zones: $TEST_ZONES")
    println("="^60)
    println()

    results = []
    success_count = 0
    failure_count = 0

    for (i, zone) in enumerate(TEST_ZONES)
        println("[$i/$(length(TEST_ZONES))] Zone: $zone")

        result = test_single_zone(zone)
        result_with_zone = merge(result, (zone=zone,))
        push!(results, result_with_zone)

        if result.success
            success_count += 1
        else
            failure_count += 1
        end

        println()
        sleep(1)  # Brief pause between zones
    end

    # Summary
    println("🏁 QUICK TEST COMPLETE")
    println("="^40)
    println("✅ Successful: $success_count/$((success_count + failure_count))")
    println("❌ Failed: $failure_count/$((success_count + failure_count))")

    if success_count > 0
        successful_results = filter(r -> r.success, results)
        avg_solve_time = round(sum(r.elapsed for r in successful_results) / success_count, digits=2)
        total_periods = sum(r.periods for r in successful_results)

        println("\\n💰 Success Statistics:")
        println("   ⏱️  Average solve time: $(avg_solve_time)s")
        println("   📊 Total periods: $total_periods")

        if length(successful_results) > 0
            successful_zones = [r.zone for r in successful_results]
            println("   🎯 Successful zones: $successful_zones")
        end
    end

    if failure_count > 0
        failed_results = filter(r -> !r.success, results)
        failed_zones = [r.zone for r in failed_results]
        println("\\n❌ Failed zones: $failed_zones")
    end

    # Check database
    if SAVE_TO_DB && success_count > 0
        println("\\n🗄️  Database Check:")
        try
            runs = Euphemia.sql2df("
                SELECT bidding_zone, status, ROUND(solve_time_seconds::numeric, 2) as solve_time
                FROM simulations.optimization_runs 
                WHERE optimization_date = '$TEST_DATE' 
                AND order_method = '$ORDER_METHOD'
                ORDER BY created_at DESC 
                LIMIT 10
            ")
            display(runs)
        catch e
            println("   ⚠️  Database check failed: $e")
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end