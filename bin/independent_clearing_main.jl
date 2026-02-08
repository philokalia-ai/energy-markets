#!/usr/bin/env julia
#
# Independent Market Clearing Script
#
# This script is invoked by the GitHub Action defined in:
# .github/workflows/independent-market-clearing.yml
#
# Required environment variables:
# - START_DATE: Start date in YYYY-MM-DD format
# - END_DATE: End date in YYYY-MM-DD format
# - PARALLEL: Boolean for parallel processing (true/false)
# - OPTIMIZER: Optimizer to use (highs/gurobi/cplex)
# - MAX_WORKERS: Maximum parallel workers (0 for auto-detect)
# - ORDER_METHOD: Order generation method (uc_based/alternative)
# - FORCE_RERUN: Force UC re-solve, bypassing cache (true/false)
# - SKIP_EXISTING: Skip dates/zones with existing price data (default: true)
# - MARKUP_FACTOR: Price markup factor for supply bids (default: 1.1)

using Euphemia, Dates
using Distributed  # Add this for parallel processing

# Parse inputs
start_date = Date(ENV["START_DATE"])
end_date = Date(ENV["END_DATE"])
use_parallel = parse(Bool, ENV["PARALLEL"])
optimizer = ENV["OPTIMIZER"]
max_workers_input = ENV["MAX_WORKERS"]
order_method = Symbol(ENV["ORDER_METHOD"])
force_rerun = parse(Bool, get(ENV, "FORCE_RERUN", "false"))
skip_existing = parse(Bool, get(ENV, "SKIP_EXISTING", "true"))
markup_factor = parse(Float64, get(ENV, "MARKUP_FACTOR", "1.1"))
bidding_strategy = Symbol(get(ENV, "BIDDING_STRATEGY", "merit_order"))

# Parse max_workers (0 means auto-detect)
max_workers = if max_workers_input == "0"
    nothing
else
    parse(Int, max_workers_input)
end

# Limit workers to 2 for Gurobi (WLS license session baseline constraint)
if optimizer == "gurobi" && use_parallel
    gurobi_max = 2
    if max_workers === nothing || max_workers > gurobi_max
        println("⚠️ Gurobi WLS license limits concurrent sessions to $gurobi_max")
        println("   Capping max_workers from $(max_workers === nothing ? "auto" : max_workers) to $gurobi_max")
        max_workers = gurobi_max
    end
end

println("🚀 Starting energy price generation")
println("📅 Date range: $start_date to $end_date")
println("⚡ Parallel: $use_parallel")
println("👥 Max workers: $(max_workers === nothing ? "auto" : max_workers)")
println("⚖️ Optimizer: $optimizer")
println("📋 Order method: $order_method")
println("🔄 Force rerun: $force_rerun")
println("⏭️  Skip existing: $skip_existing")
println("💹 Markup factor: $markup_factor")
println("📊 Bidding strategy: $bidding_strategy")
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
    println("✅ All workers ready for parallel processing")
    println()
end

try
    # Generate energy prices for date range
    result = run_independent_clearing_for_date_range(
        start_date, end_date;
        order_method=order_method,
        model=:mpcc,
        optimizer=optimizer,
        save_to_db=true,
        skip_existing=skip_existing,
        parallel=use_parallel,
        max_workers=max_workers,
        chunk_size=3,
        silent=true,
        max_retries=3,
        retry_delay=2.0,
        force_rerun=force_rerun,
        markup_factor=markup_factor,
        bidding_strategy=bidding_strategy
    )

    # Extract metrics
    successful_dates = result.successful_dates
    total_dates = result.total_dates
    total_zones_processed = result.total_zones_processed
    total_zones_successful = result.total_zones_successful
    total_time_hours = round(result.total_time / 3600, digits=2)

    # Calculate success rates
    date_success_rate = total_dates > 0 ? round(100 * successful_dates / total_dates, digits=1) : 0.0
    zone_success_rate = total_zones_processed > 0 ? round(100 * total_zones_successful / total_zones_processed, digits=1) : 0.0

    # Log success metrics
    println()
    println("="^60)
    println("🎉 GENERATION COMPLETED SUCCESSFULLY")
    println("="^60)
    println("✅ Date success: $successful_dates/$total_dates ($date_success_rate%)")
    println("✅ Zone success: $total_zones_successful/$total_zones_processed ($zone_success_rate%)")
    println("⏱️ Total time: $total_time_hours hours")
    println()

    # Set outputs for GitHub Actions
    open(ENV["GITHUB_OUTPUT"], "a") do io
        println(io, "successful_dates=$successful_dates")
        println(io, "total_dates=$total_dates")
        println(io, "date_success_rate=$date_success_rate")
        println(io, "zone_success_rate=$zone_success_rate")
        println(io, "processing_time_hours=$total_time_hours")
        println(io, "total_zones_processed=$total_zones_processed")
        println(io, "total_zones_successful=$total_zones_successful")
        println(io, "status=success")
    end

    # Detailed analysis
    if total_zones_successful > 0
        successful_summaries = filter(s -> s.zones_successful > 0, result.daily_summaries)
        if !isempty(successful_summaries)
            avg_price = sum(s.avg_price * s.zones_successful for s in successful_summaries) / sum(s.zones_successful for s in successful_summaries)

            # Get valid prices (avoiding empty collection errors)
            valid_min_prices = [s.min_price for s in successful_summaries if s.min_price > 0]
            valid_max_prices = [s.max_price for s in successful_summaries if s.max_price > 0]

            min_price = isempty(valid_min_prices) ? 0.0 : minimum(valid_min_prices)
            max_price = isempty(valid_max_prices) ? 0.0 : maximum(valid_max_prices)

            println("💰 Price Analysis:")
            println("   📊 Range: €$(min_price) - €$(max_price)/MWh")
            println("   📈 Weighted average: €$(round(avg_price, digits=2))/MWh")

            # Set price outputs
            open(ENV["GITHUB_OUTPUT"], "a") do io
                println(io, "avg_price=$(round(avg_price, digits=2))")
                println(io, "min_price=$(min_price)")
                println(io, "max_price=$(max_price)")
            end
        end
    end

    # Check for any failures
    if successful_dates < total_dates
        println()
        println("⚠️ PARTIAL SUCCESS - Some dates failed:")
        failed_dates = [r.date for r in result.date_results if !r.success]
        println("❌ Failed dates: $(join(failed_dates, ", "))")

        # Still exit successfully if we got some results
        if successful_dates > 0
            println("✅ Continuing as $successful_dates dates were processed successfully")
            # Cleanup workers before exit
            if use_parallel
                println("🧹 Cleaning up worker processes...")
                rmprocs(filter(id -> id > 1, workers()))
            end
            exit(0)
        else
            println("❌ All dates failed - marking as failure")
            # Cleanup workers before exit
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
    println("❌ CRITICAL ERROR during energy price generation:")
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