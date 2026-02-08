#!/usr/bin/env julia

"""
Test script demonstrating proper external worker setup for parallel energy price generation.

This script follows Julia distributed computing best practices by:
1. Setting up workers externally 
2. Loading packages on all workers with @everywhere
3. Calling the parallel batch processing function

Usage:
    julia --project=. test_parallel_external.jl
    # or with specific number of workers:
    julia --project=. -p 4 test_parallel_external.jl
"""

using Distributed
using Dates

# Add workers if not already present (e.g., when running without -p flag)
if nworkers() == 1
    println("🚀 No workers detected. Adding 4 worker processes...")
    addprocs(4)
    println("✅ Added $(nworkers()) workers: $(workers())")
else
    println("✅ Found $(nworkers()) existing workers: $(workers())")
end

# Load packages on all workers (following distributed computing best practices)
println("📦 Loading Euphemia package on all workers...")
@everywhere begin
    using Pkg
    Pkg.activate(@__DIR__)  # Activate the project environment
end

@everywhere begin
    using Euphemia
    using Dates
    println("Worker $(myid()): Euphemia loaded successfully")
end

# Test configuration
test_date = Date(2024, 10, 1)
println("\n" * "="^60)
println("🧪 TESTING PARALLEL ENERGY PRICE GENERATION")
println("="^60)
println("📅 Test date: $test_date")
println("⚡ Workers: $(nworkers()) (IDs: $(join(workers(), ", ")))")
println("🎯 Testing external worker setup with parallel processing")
println()

# Call the parallel batch processing function
println("🔄 Starting parallel energy price generation...")
println("   📋 Order method: :alternative (faster for testing)")
println("   🔧 Optimizer: highs")
println("   ⚡ Parallel: true")
println("   📦 Chunk size: 2 (process 2 zones per worker batch)")
println()

try
    result = run_independent_clearing_for_all_zones(
        test_date;
        order_method=:alternative,
        optimizer="highs",
        parallel=true,
        chunk_size=2,
        max_workers=nothing,
        silent=true,
        save_to_db=false,
        max_retries=1
    )

    # Display results
    println("\n" * "="^60)
    println("🏁 TEST RESULTS")
    println("="^60)

    println("📊 Summary:")
    println("   🎯 Total zones discovered: $(result.total_zones)")
    println("   ✅ Successful zones: $(result.success_count)")
    println("   ❌ Failed zones: $(result.failure_count)")
    println("   ⏭️ Skipped zones: $(result.skipped_count)")
    println("   ⚡ Workers used: $(result.parallel_workers)")
    println("   📈 Success rate: $(round(100 * result.success_count / max(1, result.total_zones), digits=1))%")
    println("   ⏱️ Total time: $(round(result.total_time, digits=1)) seconds")

    if result.success_count > 0
        println("\n💰 Price Generation Results:")
        successful_results = filter(r -> r.success, result.results)
        for (i, zone_result) in enumerate(successful_results[1:min(5, length(successful_results))])
            println("   $(zone_result.zone): $(zone_result.periods) periods, " *
                    "€$(round(zone_result.avg_price, digits=2))/MWh avg " *
                    "(worker $(zone_result.worker_id))")
        end
        if length(successful_results) > 5
            println("   ... and $(length(successful_results) - 5) more successful zones")
        end
    end

    if result.failure_count > 0
        println("\n❌ Failed Zones:")
        failed_results = filter(r -> !r.success, result.results)
        for zone_result in failed_results[1:min(3, length(failed_results))]
            println("   $(zone_result.zone): $(zone_result.error_message)")
        end
        if length(failed_results) > 3
            println("   ... and $(length(failed_results) - 3) more failed zones")
        end
    end

    # Verify parallel processing worked
    if result.parallel_workers > 1
        println("\n✅ PARALLEL PROCESSING TEST: PASSED")
        println("   🎯 Successfully used $(result.parallel_workers) workers")
        println("   ⚡ External worker setup worked correctly")
    else
        println("\n⚠️  PARALLEL PROCESSING TEST: PARTIAL")
        println("   📝 Only 1 worker used (fell back to sequential)")
    end

catch e
    println("\n❌ TEST FAILED")
    println("Error: $e")

    # Debug information
    println("\n🔍 Debug Information:")
    println("   Workers: $(workers())")
    println("   Main process: $(myid())")
    println("   Package loaded on workers? Run @everywhere @which run_independent_clearing_for_all_zones")
end

println("\n" * "="^60)
println("🏁 TEST COMPLETE")
println("="^60)

# Optional: Remove workers to clean up
println("\n🧹 Cleaning up workers...")
if nworkers() > 1
    rmprocs(workers())
    println("✅ Workers removed")
end