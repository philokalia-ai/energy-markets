#!/usr/bin/env julia
#
# Multi-Zone Market Clearing Script
#
# This script is invoked by the GitHub Action defined in:
# .github/workflows/generate-multi-zone-prices.yml
#
# Runs multi-zone market clearing with cross-border transmission flows.
# Zones are auto-discovered from transfer capacity data in the database.
#
# Required environment variables:
# - START_DATE: Start date in YYYY-MM-DD format
# - END_DATE: End date in YYYY-MM-DD format
# - PARALLEL: Boolean for parallel UC processing (true/false)
# - OPTIMIZER: Optimizer to use (highs/gurobi/cplex)
# - MAX_WORKERS: Maximum parallel workers (0 for auto-detect)
# - ORDER_METHOD: Order generation method (uc_based/alternative)

using Euphemia, Dates
using Distributed

# Parse inputs
start_date = Date(ENV["START_DATE"])
end_date = Date(ENV["END_DATE"])
use_parallel = parse(Bool, ENV["PARALLEL"])
optimizer = ENV["OPTIMIZER"]
max_workers_input = ENV["MAX_WORKERS"]
order_method = Symbol(ENV["ORDER_METHOD"])

# Parse max_workers (0 means auto-detect)
max_workers = if max_workers_input == "0"
    nothing
else
    parse(Int, max_workers_input)
end

println("🌍 Starting multi-zone market clearing")
println("📅 Date range: $start_date to $end_date")
println("⚡ Parallel UC: $use_parallel")
println("👥 Max workers: $(max_workers === nothing ? "auto" : max_workers)")
println("⚖️ Optimizer: $optimizer")
println("📋 Order method: $order_method")
println()

# Set up parallel processing if requested
if use_parallel
    initial_workers = workers()
    println("🔍 Initial workers: $initial_workers")

    # Determine number of workers to add
    workers_to_add = if max_workers === nothing
        min(Sys.CPU_THREADS ÷ 2, 20)  # Use half of available cores, max 20
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
    println("✅ All workers ready for parallel UC processing")
    println()
end

try
    # Run multi-zone market clearing for date range
    result = run_multi_zone_for_date_range(
        start_date, end_date;
        order_method=order_method,
        optimizer=optimizer,
        save_to_db=true,
        skip_existing=true,
        parallel=use_parallel,
        silent=true
    )

    # Extract metrics
    successful_dates = result.successful_dates
    total_dates = result.total_dates
    failed_dates = result.failed_dates
    skipped_dates = result.skipped_dates
    total_time_hours = round(result.total_time / 3600, digits=2)

    # Calculate success rate
    date_success_rate = total_dates > 0 ? round(100 * successful_dates / total_dates, digits=1) : 0.0

    # Log success metrics
    println()
    println("="^60)
    println("🎉 MULTI-ZONE CLEARING COMPLETED")
    println("="^60)
    println("✅ Date success: $successful_dates/$total_dates ($date_success_rate%)")
    println("⏭️  Skipped (existing): $skipped_dates")
    println("❌ Failed: $failed_dates")
    println("⏱️ Total time: $total_time_hours hours")
    println()

    # Set outputs for GitHub Actions
    open(ENV["GITHUB_OUTPUT"], "a") do io
        println(io, "successful_dates=$successful_dates")
        println(io, "total_dates=$total_dates")
        println(io, "failed_dates=$failed_dates")
        println(io, "skipped_dates=$skipped_dates")
        println(io, "date_success_rate=$date_success_rate")
        println(io, "processing_time_hours=$total_time_hours")
        println(io, "status=success")
    end

    # Analyze successful results for price statistics
    successful_results = filter(r -> r.success, result.date_results)
    if !isempty(successful_results)
        # Collect all prices across all zones and dates
        all_prices = Float64[]
        total_zones = 0

        for dr in successful_results
            if dr.success && haskey(dr, :result) && dr.result !== nothing
                for (zone, prices) in dr.result.market_prices
                    append!(all_prices, values(prices))
                    total_zones += 1
                end
            end
        end

        if !isempty(all_prices)
            avg_price = round(sum(all_prices) / length(all_prices), digits=2)
            min_price = round(minimum(all_prices), digits=2)
            max_price = round(maximum(all_prices), digits=2)

            println("💰 Price Analysis (across all zones):")
            println("   📊 Range: €$min_price - €$max_price/MWh")
            println("   📈 Average: €$avg_price/MWh")
            println("   🌍 Total zone-days: $total_zones")

            # Set price outputs
            open(ENV["GITHUB_OUTPUT"], "a") do io
                println(io, "avg_price=$avg_price")
                println(io, "min_price=$min_price")
                println(io, "max_price=$max_price")
                println(io, "total_zone_days=$total_zones")
            end
        end
    end

    # Check for any failures
    if failed_dates > 0
        println()
        println("⚠️ PARTIAL SUCCESS - Some dates failed:")
        failed_date_list = [r.date for r in result.date_results if !r.success]
        println("❌ Failed dates: $(join(failed_date_list, ", "))")

        # Still exit successfully if we got some results
        if successful_dates > 0
            println("✅ Continuing as $successful_dates dates were processed successfully")
            if use_parallel
                println("🧹 Cleaning up worker processes...")
                rmprocs(filter(id -> id > 1, workers()))
            end
            exit(0)
        else
            println("❌ All dates failed - marking as failure")
            if use_parallel
                println("🧹 Cleaning up worker processes...")
                rmprocs(filter(id -> id > 1, workers()))
            end
            exit(1)
        end
    end

    # Cleanup workers on successful completion
    if use_parallel
        println("🧹 Cleaning up worker processes...")
        rmprocs(filter(id -> id > 1, workers()))
        println("✅ Worker cleanup complete")
    end

catch e
    println()
    println("❌ CRITICAL ERROR during multi-zone market clearing:")
    println("Error: $e")

    # Set failure outputs
    open(ENV["GITHUB_OUTPUT"], "a") do io
        println(io, "successful_dates=0")
        println(io, "total_dates=0")
        println(io, "status=failure")
        println(io, "error_message=$e")
    end

    # Cleanup workers before exit
    if use_parallel
        println("🧹 Cleaning up worker processes...")
        rmprocs(filter(id -> id > 1, workers()))
    end

    exit(1)
end
