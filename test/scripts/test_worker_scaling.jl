#!/usr/bin/env julia
"""
Test script to find optimal worker count for your 80-core machine.

This script tests different worker counts to find the sweet spot where
performance plateaus due to I/O limitations rather than CPU constraints.
"""

using Distributed
using Dates

println("🧪 WORKER SCALING TEST FOR 80-CORE MACHINE")
println("="^60)

# Test with different worker counts
WORKER_COUNTS = [4, 8, 16, 24, 32, 40]  # Conservative range to start
TEST_DATE = Date(2024, 6, 18)
TEST_ZONES = ["AL", "GR", "BG", "CZ", "DE", "FR", "ES", "IT"]  # 8 zones

function test_worker_count(num_workers)
    println("\n🚀 Testing with $num_workers workers...")

    # Clean up existing workers
    if nworkers() > 1
        rmprocs(workers())
    end

    # Add workers
    addprocs(num_workers)

    # Load packages
    @everywhere using Pkg
    @everywhere Pkg.activate(".")
    @everywhere using Euphemia

    # Define processing function
    @everywhere function quick_zone_test(zone)
        worker_id = myid()
        start_time = time()

        try
            # Quick test - just create order book, don't run full optimization
            println("Worker $worker_id: Testing zone $zone")

            # This is much faster than full run_independent_market_clearing
            # Just tests data loading and order book creation
            using Euphemia.AlternativeOrderBook
            result = create_adjusted_order_book(zone, Date(2024, 6, 18))

            elapsed = time() - start_time

            if result.success
                return (
                    worker_id=worker_id,
                    zone=zone,
                    success=true,
                    elapsed=elapsed,
                    num_orders=length(result.order_book.orders)
                )
            else
                return (
                    worker_id=worker_id,
                    zone=zone,
                    success=false,
                    elapsed=elapsed,
                    num_orders=0
                )
            end
        catch e
            elapsed = time() - start_time
            return (
                worker_id=worker_id,
                zone=zone,
                success=false,
                elapsed=elapsed,
                num_orders=0
            )
        end
    end

    # Run test
    start_time = time()
    results = pmap(quick_zone_test, TEST_ZONES[1:min(num_workers, length(TEST_ZONES))])
    total_time = time() - start_time

    # Analyze results
    successful = sum(r.success for r in results)
    total_zones = length(results)
    efficiency = successful > 0 ? (sum(r.elapsed for r in results if r.success) / successful) / total_time * 100 : 0

    # Clean up
    rmprocs(workers())

    return (
        num_workers=num_workers,
        total_time=total_time,
        successful_zones=successful,
        total_zones=total_zones,
        efficiency=efficiency,
        avg_zone_time=successful > 0 ? sum(r.elapsed for r in results if r.success) / successful : 0
    )
end

# Run scaling tests
println("Testing worker scaling (order book creation only for speed)...")
results = []

for worker_count in WORKER_COUNTS
    try
        result = test_worker_count(worker_count)
        push!(results, result)

        println("   Workers: $(result.num_workers), Time: $(round(result.total_time, digits=1))s, Success: $(result.successful_zones)/$(result.total_zones), Efficiency: $(round(result.efficiency, digits=1))%")
    catch e
        println("   Workers: $worker_count FAILED: $e")
    end
end

# Analyze scaling
println("\n📊 SCALING ANALYSIS")
println("="^60)
println("Workers | Time(s) | Zones | Success | Efficiency | Speedup")
println("-"^60)

base_time = length(results) > 0 ? results[1].total_time : 1.0

for result in results
    speedup = base_time / result.total_time
    println("$(lpad(result.num_workers, 7)) | $(lpad(round(result.total_time, digits=1), 7)) | $(lpad(result.total_zones, 5)) | $(lpad(result.successful_zones, 7)) | $(lpad(round(result.efficiency, digits=1), 10))% | $(lpad(round(speedup, digits=1), 7))x")
end

# Recommendations
if length(results) >= 2
    best_efficiency = maximum(r.efficiency for r in results)
    best_worker_count = [r.num_workers for r in results if r.efficiency == best_efficiency][1]

    fastest_time = minimum(r.total_time for r in results)
    fastest_worker_count = [r.num_workers for r in results if r.total_time == fastest_time][1]

    println("\n🎯 RECOMMENDATIONS FOR YOUR 80-CORE MACHINE:")
    println("="^60)
    println("🏆 Best efficiency: $best_worker_count workers ($(round(best_efficiency, digits=1))% efficient)")
    println("⚡ Fastest processing: $fastest_worker_count workers ($(round(fastest_time, digits=1))s)")

    if best_worker_count < 40
        println("💡 Your bottleneck appears to be I/O (database/network), not CPU")
        println("   Consider testing with even fewer workers for optimal database performance")
    else
        println("💡 You may be able to scale higher - consider testing 50-80 workers")
        println("   Your 80 cores can handle much more parallel processing")
    end

    println("\n📈 For production energy price generation:")
    println("   • Start with $best_worker_count workers for best efficiency")
    println("   • Monitor database connection pool usage")
    println("   • Scale up gradually if database can handle more connections")
    println("   • Your 250GB RAM can easily support 50-80 workers")
end

println("\n🔍 Next step: Test with full run_independent_market_clearing() using recommended worker count")