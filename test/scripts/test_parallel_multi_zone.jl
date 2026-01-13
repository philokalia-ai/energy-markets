#!/usr/bin/env julia

"""
Test script for parallel UC execution in multi-zone market clearing.

This script tests the `parallel` parameter in `run_multi_zone_market_clearing()`
which runs UC solves concurrently across zones using Distributed.jl.

Usage:
    julia --project=. test/scripts/test_parallel_multi_zone.jl
    # or with specific number of workers:
    julia --project=. -p 4 test/scripts/test_parallel_multi_zone.jl
"""

using Distributed
using Dates

# Add workers if not already present
if nworkers() == 1
    println("🚀 No workers detected. Adding 4 worker processes...")
    addprocs(4)
    println("✅ Added $(nworkers()) workers: $(workers())")
else
    println("✅ Found $(nworkers()) existing workers: $(workers())")
end

# Load packages on all workers
println("📦 Loading Euphemia package on all workers...")
@everywhere begin
    using Pkg
    Pkg.activate(@__DIR__)
end

@everywhere begin
    using Euphemia
    using Dates
    println("Worker $(myid()): Euphemia loaded successfully")
end

# Test configuration
test_date = Date(2024, 6, 15)
test_zones = ["GR", "BG", "RO", "HU"]

println("\n" * "="^60)
println("🧪 TESTING PARALLEL MULTI-ZONE MARKET CLEARING")
println("="^60)
println("📅 Test date: $test_date")
println("🌍 Test zones: $(join(test_zones, ", "))")
println("⚡ Workers: $(nworkers()) (IDs: $(join(workers(), ", ")))")
println()

# Test 1: Sequential execution (baseline)
println("="^60)
println("📊 TEST 1: Sequential execution (parallel=false)")
println("="^60)

sequential_start = time()
try
    result_seq = run_multi_zone_market_clearing(test_date;
        zones=test_zones,
        order_method=:uc_based,
        optimizer="highs",
        parallel=false,
        save_to_db=false
    )
    sequential_time = time() - sequential_start
    println("\n✅ Sequential completed in $(round(sequential_time, digits=1))s")
    println("   Status: $(result_seq.status)")
catch e
    sequential_time = time() - sequential_start
    println("\n❌ Sequential failed after $(round(sequential_time, digits=1))s: $e")
end

# Test 2: Parallel execution
println("\n" * "="^60)
println("📊 TEST 2: Parallel execution (parallel=true)")
println("="^60)

parallel_start = time()
try
    result_par = run_multi_zone_market_clearing(test_date;
        zones=test_zones,
        order_method=:uc_based,
        optimizer="highs",
        parallel=true,
        save_to_db=false
    )
    parallel_time = time() - parallel_start
    println("\n✅ Parallel completed in $(round(parallel_time, digits=1))s")
    println("   Status: $(result_par.status)")
catch e
    parallel_time = time() - parallel_start
    println("\n❌ Parallel failed after $(round(parallel_time, digits=1))s: $e")
end

# Summary
println("\n" * "="^60)
println("🏁 PERFORMANCE COMPARISON")
println("="^60)

if @isdefined(sequential_time) && @isdefined(parallel_time)
    speedup = sequential_time / parallel_time
    println("   Sequential: $(round(sequential_time, digits=1))s")
    println("   Parallel:   $(round(parallel_time, digits=1))s")
    println("   Speedup:    $(round(speedup, digits=2))x")
    println("   Workers:    $(nworkers())")
    println("   Zones:      $(length(test_zones))")

    if speedup > 1.5
        println("\n✅ Parallel execution shows significant speedup!")
    elseif speedup > 1.0
        println("\n✅ Parallel execution is faster (modest speedup)")
    else
        println("\n⚠️  Parallel overhead exceeded gains (try more zones or check cache)")
    end
end

# Cleanup
println("\n🧹 Cleaning up workers...")
rmprocs(workers())
println("✅ Done!")
