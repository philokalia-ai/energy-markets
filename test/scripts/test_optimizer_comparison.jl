#!/usr/bin/env julia

"""
Optimizer Performance Comparison Test
Compares Gurobi vs HiGHS performance for MPCC with UC-based order generation.
Tests the same zone with both optimizers without database saves.
"""

using Pkg
Pkg.activate(".")

using Euphemia
using Printf
using Statistics
using Dates

# Test configuration
const TEST_ZONE = "ES"  # Spain - high complexity zone
const TEST_DATE = Date(2025, 10, 1)
const ORDER_METHOD = :uc_based  # Use Symbol instead of String
const MODEL = :mpcc  # Use Symbol instead of String
const NUM_RUNS = 3  # Number of runs for averaging

println("🏁 OPTIMIZER PERFORMANCE COMPARISON")
println("="^60)
println("📅 Date: $TEST_DATE")
println("🌍 Zone: $TEST_ZONE")
println("📋 Order Method: $ORDER_METHOD")
println("⚖️  Model: $MODEL")
println("🔄 Runs per optimizer: $NUM_RUNS")
println("💾 Database Save: false (for pure performance)")
println("="^60)

struct TestResult
    optimizer::String
    run::Int
    total_time::Float64
    uc_time::Float64
    mpcc_time::Float64
    success::Bool
    error_msg::String
    periods::Int
    min_price::Float64
    max_price::Float64
end

function run_single_test(optimizer::String, run_num::Int)
    println("\n🔄 Run $run_num with $optimizer")
    println("-"^40)

    try
        start_time = time()

        prices = run_independent_market_clearing(TEST_ZONE, TEST_DATE;
            order_method=ORDER_METHOD,
            model=MODEL,
            optimizer=optimizer,
            save_to_db=false,  # No database save for pure performance
            silent=false)

        total_time = time() - start_time

        if length(prices) > 0
            min_price = minimum(values(prices))
            max_price = maximum(values(prices))

            println("✅ SUCCESS: $(round(total_time, digits=2))s")
            println("   $(length(prices)) periods: €$(round(min_price, digits=2)) - €$(round(max_price, digits=2))/MWh")

            return TestResult(
                optimizer, run_num, total_time, 0.0, 0.0, true, "",
                length(prices), min_price, max_price
            )
        else
            println("❌ FAILED: No prices generated")
            return TestResult(
                optimizer, run_num, total_time, 0.0, 0.0, false, "No prices generated",
                0, 0.0, 0.0
            )
        end

    catch e
        error_msg = string(e)
        println("❌ ERROR: $(first(split(error_msg, '\n')))")
        return TestResult(
            optimizer, run_num, 0.0, 0.0, 0.0, false, error_msg,
            0, 0.0, 0.0
        )
    end
end

function run_optimizer_test(optimizer::String)
    println("\n" * "="^60)
    println("🚀 TESTING $optimizer")
    println("="^60)

    results = TestResult[]
    successful_runs = 0

    for run in 1:NUM_RUNS
        result = run_single_test(optimizer, run)
        push!(results, result)

        if result.success
            successful_runs += 1
        end

        # Small delay between runs
        if run < NUM_RUNS
            sleep(1)
        end
    end

    # Summary for this optimizer
    if successful_runs > 0
        successful_results = filter(r -> r.success, results)
        times = [r.total_time for r in successful_results]

        avg_time = mean(times)
        min_time = minimum(times)
        max_time = maximum(times)
        std_time = std(times)

        @printf("\n📊 %s Summary (%d/%d successful):\n", optimizer, successful_runs, NUM_RUNS)
        @printf("   ⏱️  Average time: %.2fs\n", avg_time)
        @printf("   🏃 Best time: %.2fs\n", min_time)
        @printf("   🐌 Worst time: %.2fs\n", max_time)
        @printf("   📈 Std dev: %.3fs\n", std_time)

        if successful_runs == NUM_RUNS
            println("   ✅ All runs successful")
        else
            println("   ⚠️  $(NUM_RUNS - successful_runs) runs failed")
        end
    else
        println("\n❌ $optimizer: All runs failed")
    end

    return results
end

function compare_results(gurobi_results, highs_results)
    println("\n" * "="^60)
    println("🏆 PERFORMANCE COMPARISON")
    println("="^60)

    # Filter successful results
    gurobi_success = filter(r -> r.success, gurobi_results)
    highs_success = filter(r -> r.success, highs_results)

    if length(gurobi_success) == 0 || length(highs_success) == 0
        println("❌ Cannot compare: insufficient successful runs")
        return
    end

    # Calculate averages
    gurobi_avg = mean([r.total_time for r in gurobi_success])
    highs_avg = mean([r.total_time for r in highs_success])

    # Speed comparison
    if gurobi_avg < highs_avg
        speedup = highs_avg / gurobi_avg
        println("🚀 Gurobi is $(@sprintf("%.2f", speedup))x FASTER than HiGHS")
        println("   ⚡ Gurobi: $(@sprintf("%.2f", gurobi_avg))s")
        println("   🐌 HiGHS:  $(@sprintf("%.2f", highs_avg))s")
        println("   💾 Time saved: $(@sprintf("%.2f", highs_avg - gurobi_avg))s per run")
    elseif highs_avg < gurobi_avg
        speedup = gurobi_avg / highs_avg
        println("🚀 HiGHS is $(@sprintf("%.2f", speedup))x FASTER than Gurobi")
        println("   ⚡ HiGHS:  $(@sprintf("%.2f", highs_avg))s")
        println("   🐌 Gurobi: $(@sprintf("%.2f", gurobi_avg))s")
        println("   💾 Time saved: $(@sprintf("%.2f", gurobi_avg - highs_avg))s per run")
    else
        println("⚖️  Both optimizers have similar performance")
        println("   Gurobi: $(@sprintf("%.2f", gurobi_avg))s")
        println("   HiGHS:  $(@sprintf("%.2f", highs_avg))s")
    end

    # Reliability comparison
    gurobi_success_rate = length(gurobi_success) / NUM_RUNS * 100
    highs_success_rate = length(highs_success) / NUM_RUNS * 100

    println("\n📊 Reliability:")
    println("   Gurobi: $(@sprintf("%.1f", gurobi_success_rate))% success rate")
    println("   HiGHS:  $(@sprintf("%.1f", highs_success_rate))% success rate")

    # Estimate time savings for full 51-zone test
    if gurobi_avg < highs_avg
        time_per_zone_saved = highs_avg - gurobi_avg
        total_time_saved = time_per_zone_saved * 51
        println("\n💡 Estimated time savings for full 51-zone test:")
        println("   Per zone: $(@sprintf("%.2f", time_per_zone_saved))s")
        println("   Total: $(@sprintf("%.1f", total_time_saved/60)) minutes")
    end
end

# Main execution
println("\n🎯 Starting performance comparison test...")

try
    # Test Gurobi
    gurobi_results = run_optimizer_test("gurobi")

    println("\n⏳ Waiting 3 seconds before HiGHS test...")
    sleep(3)

    # Test HiGHS
    highs_results = run_optimizer_test("highs")

    # Compare results
    compare_results(gurobi_results, highs_results)

    println("\n🏁 Performance comparison completed!")

catch e
    println("❌ Test failed with error: $e")
    exit(1)
end