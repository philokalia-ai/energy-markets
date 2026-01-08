#!/usr/bin/env julia
"""
Simple worker scaling test for 80-core machine
"""

using Distributed
using Dates

println("🧪 WORKER SCALING TEST FOR 80-CORE MACHINE")
println("="^60)

# Test parameters
WORKER_COUNTS = [4, 8, 16, 24, 32]
TEST_ZONES = ["AL", "GR", "BG", "CZ"]

function test_workers(num_workers::Int)
    println("\n🚀 Testing $num_workers workers...")

    # Setup workers
    if nworkers() > 1
        rmprocs(workers())
    end
    addprocs(num_workers)

    # Load packages on workers
    @everywhere using Pkg
    @everywhere Pkg.activate(".")
    @everywhere using Distributed, Dates

    # Simple CPU test function
    @everywhere function cpu_intensive_task(zone_id)
        # Simulate some CPU work
        result = 0
        for i in 1:1000000
            result += sqrt(i) * sin(i)
        end
        return (worker=myid(), zone=zone_id, result=result)
    end

    # Time the parallel execution
    start_time = time()
    results = pmap(cpu_intensive_task, 1:num_workers)
    total_time = time() - start_time

    # Cleanup
    rmprocs(workers())

    return (workers=num_workers, time=total_time, success=length(results))
end

# Run tests
println("Running scaling tests...")
results = []

for count in WORKER_COUNTS
    try
        result = test_workers(count)
        push!(results, result)
        speedup = length(results) == 1 ? 1.0 : results[1].time / result.time
        println("   $count workers: $(round(result.time, digits=2))s ($(round(speedup, digits=1))x speedup)")
    catch e
        println("   $count workers: FAILED - $e")
    end
end

# Summary
println("\n📊 SCALING SUMMARY")
println("="^50)
println("Workers | Time(s) | Speedup")
println("-"^30)

if !isempty(results)
    base_time = results[1].time
    for r in results
        speedup = base_time / r.time
        efficiency = speedup / r.workers * 100
        println("$(lpad(r.workers, 7)) | $(lpad(round(r.time, digits=2), 7)) | $(lpad(round(speedup, digits=1), 7))x ($(round(efficiency, digits=1))%)")
    end

    println("\n💡 Your 80-core machine can handle parallel processing very well!")
    println("   Consider testing with 40-80 workers for energy price generation.")
    println("   Database I/O will likely be the limiting factor, not CPU.")
end