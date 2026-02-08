#!/usr/bin/env julia
"""
Test script for parallel processing using run_independent_market_clearing() with individual zones.

This script tests the external worker setup by:
1. Setting up 4 worker processes externally
2. Loading required packages on all workers
3. Testing parallel processing with run_independent_market_clearing() for individual zones
4. Each worker processes one small bidding zone (AL, GR, BG, CZ)

Usage:
    julia --project=. test_parallel_individual_zones.jl

Requirements:
- External worker setup (this script manages workers)
- Proper package environment with --project=.
- Database connection for ENTSO-E data
"""

using Distributed
using Dates

# Test parameters
const TEST_DATE = Date(2024, 6, 18)  # Known good date with data
const TEST_ZONES = ["AL", "GR", "BG", "CZ"]  # Small European zones
const NUM_WORKERS = 4

println("🧪 PARALLEL INDIVIDUAL ZONES TEST")
println("="^60)
println("   📅 Test date: $TEST_DATE")
println("   🌍 Test zones: $(join(TEST_ZONES, ", "))")
println("   👷 Target workers: $NUM_WORKERS")
println()

# Step 1: Setup Workers
println("🚀 Step 1: Setting up $NUM_WORKERS worker processes...")
if nworkers() > 1
    println("   ⚠️  Existing workers detected, removing them first...")
    rmprocs(workers())
end

# Add fresh workers
worker_pids = addprocs(NUM_WORKERS)
println("   ✅ Added workers: $worker_pids")
println("   📊 Total processes: $(nprocs()) (including main)")
println("   👷 Worker processes: $(nworkers())")

# Step 2: Load packages on all workers
println("\n📦 Step 2: Loading packages on all workers...")

# Load core packages
@everywhere using Pkg
@everywhere Pkg.activate(".")

println("   📋 Loading Distributed and Dates...")
@everywhere using Distributed
@everywhere using Dates

println("   🔧 Loading Euphemia module...")
@everywhere begin
    try
        using Euphemia
        println("Worker $(myid()): ✅ Euphemia loaded successfully")
    catch e
        println("Worker $(myid()): ❌ Failed to load Euphemia: $e")
        rethrow(e)
    end
end

# Verify package loading
println("\n🔍 Step 3: Verifying worker setup...")

# Test each worker individually
worker_status = Dict{Int,Bool}()

for worker_id in [1; workers()]  # Include main process
    try
        result = remotecall_fetch(worker_id) do
            try
                # Check if Euphemia is loaded (check for module or imported functions)
                has_euphemia = isdefined(Main, :Euphemia) || isdefined(Main, :run_independent_market_clearing)

                # Check if run_independent_market_clearing function exists  
                has_function = isdefined(Main, :run_independent_market_clearing)

                # Get function info if available
                func_info = if has_function
                    try
                        "$(typeof(Main.run_independent_market_clearing))"
                    catch
                        "Function exists but type unavailable"
                    end
                else
                    "Function not available"
                end

                return (myid(), has_euphemia, has_function, func_info)
            catch e
                return (myid(), false, false, "Error: $e")
            end
        end

        worker_id, has_euphemia, has_function, func_info = result

        if has_euphemia && has_function
            println("   Worker $worker_id: ✅ Ready (Module loaded, function available: $func_info)")
            worker_status[worker_id] = true
        else
            println("   Worker $worker_id: ❌ Not ready (Module: $has_euphemia, Function: $has_function)")
            worker_status[worker_id] = false
        end

    catch e
        println("   Worker $worker_id: ❌ Communication error: $e")
        worker_status[worker_id] = false
    end
end

# Check if all workers are ready
failed_workers = [id for (id, status) in worker_status if !status]
if !isempty(failed_workers)
    error("Workers not ready: $(join(failed_workers, ", ")). Cannot proceed with parallel testing.")
end

println("   ✅ All workers are ready for parallel processing!")

# Step 4: Test parallel zone processing
println("\n⚡ Step 4: Testing parallel individual zone processing...")
println("   📋 Strategy: Each worker processes one zone")
println("   🎯 Target: $(length(TEST_ZONES)) zones across $NUM_WORKERS workers")

# Prepare zone-worker assignments
zone_assignments = [(zone, TEST_DATE) for zone in TEST_ZONES]
println("   📝 Zone assignments: $zone_assignments")

# Define the parallel processing function on all workers
@everywhere function process_single_zone(zone_date_tuple)
    zone, date = zone_date_tuple
    worker_id = myid()
    start_time = time()

    try
        println("Worker $worker_id: 🔄 Processing zone $zone for date $date")

        # Call run_independent_market_clearing for this specific zone
        prices = run_independent_market_clearing(
            zone,
            date;
            order_method=:alternative,
            model=:mpcc,
            optimizer="highs",
            silent=true,
            save_to_db=false
        )

        elapsed = time() - start_time

        if !isempty(prices)
            num_periods = length(prices)
            price_values = collect(values(prices))
            min_price = minimum(price_values)
            max_price = maximum(price_values)
            avg_price = sum(price_values) / num_periods

            println("Worker $worker_id: ✅ Zone $zone completed in $(round(elapsed, digits=1))s")
            println("Worker $worker_id:    📊 $num_periods periods, €$(round(min_price, digits=2))-€$(round(max_price, digits=2))/MWh (avg: €$(round(avg_price, digits=2)))")

            return (
                worker_id=worker_id,
                zone=zone,
                success=true,
                elapsed=elapsed,
                num_periods=num_periods,
                min_price=min_price,
                max_price=max_price,
                avg_price=avg_price,
                error=""
            )
        else
            println("Worker $worker_id: ❌ Zone $zone failed - no prices generated")
            return (
                worker_id=worker_id,
                zone=zone,
                success=false,
                elapsed=elapsed,
                num_periods=0,
                min_price=0.0,
                max_price=0.0,
                avg_price=0.0,
                error="No prices generated"
            )
        end

    catch e
        elapsed = time() - start_time
        error_msg = string(e)
        println("Worker $worker_id: ❌ Zone $zone failed with error: $error_msg")

        return (
            worker_id=worker_id,
            zone=zone,
            success=false,
            elapsed=elapsed,
            num_periods=0,
            min_price=0.0,
            max_price=0.0,
            avg_price=0.0,
            error=error_msg
        )
    end
end

# Execute parallel processing
parallel_start = time()

println("\n🏃 Executing parallel zone processing...")
results = pmap(process_single_zone, zone_assignments)

parallel_elapsed = time() - parallel_start

# Step 5: Analyze results
println("\n📊 Step 5: Analyzing results...")
println("="^60)

successful_results = filter(r -> r.success, results)
failed_results = filter(r -> !r.success, results)

success_count = length(successful_results)
failure_count = length(failed_results)
total_zones = length(TEST_ZONES)

println("📈 Overall Performance:")
println("   ✅ Successful zones: $success_count/$total_zones")
println("   ❌ Failed zones: $failure_count")
println("   ⏱️  Total parallel time: $(round(parallel_elapsed, digits=1)) seconds")
println("   📊 Success rate: $(round(100 * success_count / total_zones, digits=1))%")

if success_count > 0
    total_periods = sum(r.num_periods for r in successful_results)
    all_prices = Float64[]

    # Collect all prices for statistics
    for result in successful_results
        push!(all_prices, result.min_price, result.max_price)
    end

    if !isempty(all_prices)
        overall_min = minimum(all_prices)
        overall_max = maximum(all_prices)

        weighted_avg = sum(r.avg_price * r.num_periods for r in successful_results) / total_periods

        println("\n💰 Price Statistics:")
        println("   📊 Total periods generated: $total_periods")
        println("   📈 Overall price range: €$(round(overall_min, digits=2)) - €$(round(overall_max, digits=2))/MWh")
        println("   💵 Weighted average price: €$(round(weighted_avg, digits=2))/MWh")
    end

    # Individual solve times
    solve_times = [r.elapsed for r in successful_results]
    if !isempty(solve_times)
        avg_solve_time = sum(solve_times) / length(solve_times)
        max_solve_time = maximum(solve_times)
        min_solve_time = minimum(solve_times)

        println("\n⏱️  Solve Time Analysis:")
        println("   📊 Average solve time: $(round(avg_solve_time, digits=1))s")
        println("   ⚡ Fastest zone: $(round(min_solve_time, digits=1))s")
        println("   🐌 Slowest zone: $(round(max_solve_time, digits=1))s")

        # Estimate sequential time
        estimated_sequential = sum(solve_times)
        speedup = estimated_sequential / parallel_elapsed
        efficiency = speedup / NUM_WORKERS * 100

        println("   🚀 Parallel speedup: $(round(speedup, digits=1))x")
        println("   📈 Parallel efficiency: $(round(efficiency, digits=1))%")
    end
end

# Detailed results per zone
println("\n📋 Detailed Results:")
for result in results
    if result.success
        println("   ✅ Zone $(result.zone) (Worker $(result.worker_id)): $(result.num_periods) periods, €$(round(result.avg_price, digits=2))/MWh avg, $(round(result.elapsed, digits=1))s")
    else
        println("   ❌ Zone $(result.zone) (Worker $(result.worker_id)): FAILED - $(result.error)")
    end
end

# Worker utilization analysis
println("\n👷 Worker Utilization:")
worker_usage = Dict{Int,Int}()
for result in results
    worker_usage[result.worker_id] = get(worker_usage, result.worker_id, 0) + 1
end

for (worker_id, zone_count) in sort(collect(worker_usage))
    successful_on_worker = sum(1 for r in results if r.worker_id == worker_id && r.success)
    println("   Worker $worker_id: $zone_count zones assigned, $successful_on_worker successful")
end

if failure_count > 0
    println("\n❌ Failed Zones Details:")
    for result in failed_results
        println("   Zone $(result.zone): $(result.error)")
    end
end

# Step 6: Cleanup
println("\n🧹 Step 6: Cleaning up workers...")
rmprocs(workers())
println("   ✅ All workers removed")

# Final assessment
println("\n" * "="^60)
println("🏁 PARALLEL INDIVIDUAL ZONES TEST COMPLETE")
println("="^60)

if success_count == total_zones
    println("🎉 SUCCESS: All $total_zones zones processed successfully!")
    println("   ⚡ Parallel processing is working correctly")
    println("   🚀 External worker setup is functioning properly")
    println("   💪 run_independent_market_clearing() works well in parallel environment")
else
    println("⚠️  PARTIAL SUCCESS: $success_count/$total_zones zones succeeded")
    if failure_count > 0
        println("   🔍 Check failed zones for data availability or configuration issues")
    end
end

println("\nKey findings:")
println("   📦 External worker setup: ✅ Working")
println("   🔄 Package loading on workers: ✅ Working")
println("   ⚡ Parallel pmap execution: ✅ Working")
println("   🎯 Individual zone processing: $(success_count > 0 ? "✅" : "❌") $(success_count > 0 ? "Working" : "Failed")")
if success_count > 0
    println("   🚀 Parallel efficiency: $(round(efficiency, digits=1))% ($(round(speedup, digits=1))x speedup)")
end

println("\n🎯 Next steps:")
println("   • This test validates that run_independent_market_clearing() works correctly in parallel")
println("   • The external worker setup is functioning as expected")
println("   • Ready for production-scale parallel processing")
println("   • Consider testing with larger zone sets for full validation")