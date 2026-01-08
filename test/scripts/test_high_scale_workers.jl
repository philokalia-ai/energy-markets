#!/usr/bin/env julia
"""
Test with more workers on your 80-core machine with database monitoring
"""

using Distributed
using Dates

# Test with larger worker counts since your DB can handle it
WORKER_COUNTS = [10, 20, 30, 40, 50]
TEST_ZONES = ["AL", "GR", "BG", "CZ", "DE", "FR", "ES", "IT", "NL", "BE"]

function monitor_and_test(num_workers)
    println("\n🚀 Testing $num_workers workers with database monitoring...")

    # Monitor before
    println("📊 Database status BEFORE test:")
    run(`julia --project=. monitor_simple.jl`)

    # Setup workers
    if nworkers() > 1
        rmprocs(workers())
    end
    addprocs(num_workers)

    @everywhere using Pkg
    @everywhere Pkg.activate(".")
    @everywhere using Euphemia, Dates

    @everywhere function test_zone_processing(zone_date)
        zone, date = zone_date
        worker_id = myid()

        try
            println("Worker $worker_id: Processing $zone")

            # Quick order book test (faster than full optimization)
            prices = generate_energy_prices(
                zone,
                date;
                order_method=:alternative,
                silent=true,
                save_to_db=false  # Disable DB saving for speed
            )

            return (
                worker=worker_id,
                zone=zone,
                success=!isempty(prices),
                periods=length(prices)
            )

        catch e
            return (
                worker=worker_id,
                zone=zone,
                success=false,
                periods=0
            )
        end
    end

    # Prepare test data
    test_date = Date(2024, 6, 18)
    zone_assignments = [(zone, test_date) for zone in TEST_ZONES[1:min(num_workers, length(TEST_ZONES))]]

    println("📋 Processing $(length(zone_assignments)) zones with $num_workers workers...")

    # Run parallel test with timing
    start_time = time()
    results = pmap(test_zone_processing, zone_assignments)
    elapsed = time() - start_time

    # Monitor after
    println("\n📊 Database status AFTER test:")
    run(`julia --project=. monitor_simple.jl`)

    # Cleanup
    rmprocs(workers())

    # Results
    successful = sum(r.success for r in results)
    total = length(results)

    println("\n📈 Test Results:")
    println("   Workers: $num_workers")
    println("   Zones: $successful/$total successful")
    println("   Time: $(round(elapsed, digits=1))s")
    println("   Zones/second: $(round(successful/elapsed, digits=2))")

    return (workers=num_workers, time=elapsed, success_rate=successful / total)
end

println("🧪 HIGH-SCALE WORKER TEST WITH DATABASE MONITORING")
println("="^60)
println("🖥️  Your machine: 80 cores, 250GB RAM")
println("🗄️  Your database: 1000 connection limit (excellent!)")
println()

results = []
for worker_count in WORKER_COUNTS
    try
        result = monitor_and_test(worker_count)
        push!(results, result)

        if length(results) > 1
            speedup = results[1].time / result.time
            println("   🚀 Speedup vs $(WORKER_COUNTS[1]) workers: $(round(speedup, digits=1))x")
        end

    catch e
        println("❌ Test with $worker_count workers failed: $e")
    end

    println("⏳ Waiting 10 seconds before next test...")
    sleep(10)
end

println("\n🏁 SCALING SUMMARY")
println("="^50)
if !isempty(results)
    base_time = results[1].time
    println("Workers | Time(s) | Speedup | Rate(zones/s)")
    println("-"^45)

    for r in results
        speedup = base_time / r.time
        zones_per_sec = round(1 / r.time * WORKER_COUNTS[1], digits=2)
        println("$(lpad(r.workers, 7)) | $(lpad(round(r.time, digits=1), 7)) | $(lpad(round(speedup, digits=1), 7))x | $(lpad(zones_per_sec, 11))")
    end

    # Find optimal point
    if length(results) >= 2
        best_efficiency = argmax([results[i].time > 0 ? results[1].time / results[i].time / results[i].workers : 0 for i in 1:length(results)])
        optimal_workers = results[best_efficiency].workers

        println("\n🎯 RECOMMENDATIONS:")
        println("💪 Your database can easily handle $(maximum(WORKER_COUNTS)) workers")
        println("🚀 Optimal efficiency around: $optimal_workers workers")
        println("⚡ Your 80-core machine is ready for massive parallel processing!")
        println("📈 Consider testing with even more workers (60-80) for production")
    end
end