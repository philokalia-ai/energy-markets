#!/usr/bin/env julia
#
# Refresh Inference Cache Script
#
# This script is invoked by the GitHub Action defined in:
# .github/workflows/refresh-inference-cache.yml
#
# Proactively refreshes the generator parameter inference cache for all zones.
# This avoids surprise 17+ minute delays during UC solves when cache expires.
#
# Required environment variables:
# - REFERENCE_DATE: Date for inference (YYYY-MM-DD), uses 12 months of data before this
# - PARALLEL: Boolean for parallel processing (true/false)
# - MAX_WORKERS: Maximum parallel workers (0 for auto-detect)

using Euphemia, Dates
using Distributed

# Parse inputs
reference_date = Date(get(ENV, "REFERENCE_DATE", string(today())))
use_parallel = parse(Bool, get(ENV, "PARALLEL", "true"))
max_workers_input = get(ENV, "MAX_WORKERS", "4")

# Parse max_workers (0 means auto-detect)
max_workers = if max_workers_input == "0"
    nothing
else
    parse(Int, max_workers_input)
end

println("🔄 Inference Cache Refresh")
println("📅 Reference date: $reference_date")
println("⚡ Parallel: $use_parallel")
println("👥 Max workers: $(max_workers === nothing ? "auto" : max_workers)")
println()

# Set up parallel processing if requested
if use_parallel
    initial_workers = workers()
    println("🔍 Initial workers: $initial_workers")

    # Determine number of workers to add
    # Inference is I/O bound (DB queries), not CPU bound, so we can use many workers
    workers_to_add = if max_workers === nothing
        Sys.CPU_THREADS ÷ 2  # Use half the cores - leave room for other users
    else
        max_workers
    end

    println("🚀 Adding $workers_to_add worker processes...")
    addprocs(workers_to_add)

    new_workers = workers()
    println("✅ Workers added: $new_workers")

    # Load Euphemia on all workers
    println("📦 Loading Euphemia package on all workers...")
    @everywhere using Euphemia
    println("✅ All workers ready")
    println()
end

try
    # Discover all zones with generator data
    println("🔍 Discovering available zones...")
    zones = get_available_zones(reference_date)
    println("📍 Found $(length(zones)) zones: $(join(zones, ", "))")
    println()

    # Run inference cache refresh
    result = refresh_inference_cache(zones, reference_date; parallel=use_parallel)

    # Set outputs for GitHub Actions
    if haskey(ENV, "GITHUB_OUTPUT")
        open(ENV["GITHUB_OUTPUT"], "a") do io
            println(io, "successful_zones=$(result.successful_zones)")
            println(io, "failed_zones=$(result.failed_zones)")
            println(io, "total_zones=$(length(zones))")
            println(io, "processing_time_seconds=$(result.total_time)")
            println(io, "status=success")
        end
    end

    # Cleanup workers
    if use_parallel
        println()
        println("🧹 Cleaning up worker processes...")
        rmprocs(filter(id -> id > 1, workers()))
        println("✅ Worker cleanup complete")
    end

    # Exit with failure if any zones failed
    if result.failed_zones > 0
        println()
        println("⚠️ Some zones failed - check logs above")
        exit(1)
    end

catch e
    println()
    println("❌ CRITICAL ERROR during inference cache refresh:")
    println("Error: $e")

    # Set failure outputs
    if haskey(ENV, "GITHUB_OUTPUT")
        open(ENV["GITHUB_OUTPUT"], "a") do io
            println(io, "successful_zones=0")
            println(io, "failed_zones=0")
            println(io, "status=failure")
            println(io, "error_message=$e")
        end
    end

    # Cleanup workers before exit
    if use_parallel
        println("🧹 Cleaning up worker processes...")
        rmprocs(filter(id -> id > 1, workers()))
    end

    exit(1)
end
