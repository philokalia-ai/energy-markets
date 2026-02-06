#!/usr/bin/env julia
#
# Iterative Multi-Zone Market Clearing Script
#
# This script is invoked by the GitHub Action defined in:
# .github/workflows/generate-iterative-multi-zone-prices.yml
#
# Runs iterative UC-MPCC market clearing with feedback loop until price convergence.
# This accounts for interconnection effects in unit commitment decisions.
#
# Required environment variables:
# - START_DATE: Start date in YYYY-MM-DD format
# - END_DATE: End date in YYYY-MM-DD format
# - PARALLEL: Boolean for parallel UC processing (true/false)
# - OPTIMIZER: Optimizer to use (highs/gurobi)
# - MAX_WORKERS: Maximum parallel workers (0 for auto-detect based on optimizer)
# - MAX_ITERATIONS: Maximum UC-MPCC iterations per date (default: 10)
# - PRICE_TOLERANCE: Convergence tolerance in €/MWh (default: 1.0)
# - DAMPING_FACTOR: Flow update damping factor (default: 0.7)
# - MARKUP_FACTOR: Price markup factor for supply bids (default: 1.1)

using Euphemia, Dates
using Distributed

# Parse inputs
start_date = Date(ENV["START_DATE"])
end_date = Date(ENV["END_DATE"])
use_parallel = parse(Bool, get(ENV, "PARALLEL", "true"))
optimizer = get(ENV, "OPTIMIZER", "highs")
max_workers_input = get(ENV, "MAX_WORKERS", "0")
max_iterations = parse(Int, get(ENV, "MAX_ITERATIONS", "10"))
price_tolerance = parse(Float64, get(ENV, "PRICE_TOLERANCE", "1.0"))
damping_factor = parse(Float64, get(ENV, "DAMPING_FACTOR", "0.7"))
markup_factor = parse(Float64, get(ENV, "MARKUP_FACTOR", "1.1"))

# Parse max_workers (0 means auto-detect based on optimizer)
max_workers = if max_workers_input == "0"
    nothing  # Will auto-detect: 2 for Gurobi, half for HiGHS
else
    parse(Int, max_workers_input)
end

println("🔄 Starting ITERATIVE multi-zone market clearing")
println("📅 Date range: $start_date to $end_date")
println("⚡ Parallel UC: $use_parallel")
println("👥 Max workers: $(max_workers === nothing ? "auto (2 for Gurobi, half for HiGHS)" : max_workers)")
println("⚖️ Optimizer: $optimizer")
println("🔁 Max iterations: $max_iterations")
println("💰 Price tolerance: $price_tolerance €/MWh")
println("🎚️ Damping factor: $damping_factor")
println("💹 Markup factor: $markup_factor")
println()

# Set up parallel processing if requested
if use_parallel
    initial_workers = workers()
    println("🔍 Initial workers: $initial_workers")

    # Determine number of workers to add based on optimizer
    workers_to_add = if max_workers !== nothing
        max_workers
    elseif lowercase(optimizer) == "gurobi"
        2  # Gurobi WLS license limit
    else
        min(Sys.CPU_THREADS ÷ 2, 20)  # HiGHS: use half of available cores, max 20
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

# Track results across dates
dates = collect(start_date:Day(1):end_date)
total_dates = length(dates)
successful_dates = 0
failed_dates = 0
converged_dates = 0
total_iterations = 0
all_prices = Float64[]
total_zones = 0
total_time = 0.0
date_results = []

println("="^60)
println("📅 Processing $total_dates date(s)")
println("="^60)

try
    for (idx, date) in enumerate(dates)
        println()
        println("-"^60)
        println("📅 [$idx/$total_dates] Processing $date")
        println("-"^60)

        date_start = time()

        try
            result = run_iterative_multi_zone_market_clearing(date;
                optimizer=optimizer,
                max_iterations=max_iterations,
                price_tolerance=price_tolerance,
                damping_factor=damping_factor,
                markup_factor=markup_factor,
                silent=true,
                save_to_db=true,
                parallel=use_parallel,
                max_workers=max_workers
            )

            date_time = time() - date_start
            global total_time += date_time

            # Track success
            global successful_dates += 1
            if result.converged
                global converged_dates += 1
            end
            global total_iterations += result.iterations

            # Collect prices
            for (zone, prices) in result.market_prices
                append!(all_prices, values(prices))
                global total_zones += 1
            end

            push!(date_results, (
                date=date,
                success=true,
                converged=result.converged,
                iterations=result.iterations,
                price_change=result.convergence_metrics.price_change,
                time=date_time
            ))

            status_emoji = result.converged ? "✅" : "⚠️"
            println("$status_emoji $date: $(result.iterations) iterations, " *
                    "Δλ=$(round(result.convergence_metrics.price_change, digits=2)) €/MWh, " *
                    "$(round(date_time/60, digits=1)) min")

        catch e
            date_time = time() - date_start
            global total_time += date_time
            global failed_dates += 1

            push!(date_results, (
                date=date,
                success=false,
                converged=false,
                iterations=0,
                price_change=Inf,
                time=date_time,
                error=string(e)
            ))

            println("❌ $date failed: $e")
        end
    end

    # Summary
    println()
    println("="^60)
    println("🎉 ITERATIVE MULTI-ZONE CLEARING COMPLETED")
    println("="^60)
    println("✅ Successful: $successful_dates/$total_dates dates")
    println("🔄 Converged: $converged_dates/$successful_dates dates")
    println("📊 Total iterations: $total_iterations (avg: $(round(total_iterations/max(1,successful_dates), digits=1))/date)")
    println("❌ Failed: $failed_dates")
    println("⏱️ Total time: $(round(total_time/3600, digits=2)) hours")

    if !isempty(all_prices)
        avg_price = round(sum(all_prices) / length(all_prices), digits=2)
        min_price = round(minimum(all_prices), digits=2)
        max_price = round(maximum(all_prices), digits=2)
        println()
        println("💰 Price Analysis (across all zones):")
        println("   📊 Range: €$min_price - €$max_price/MWh")
        println("   📈 Average: €$avg_price/MWh")
        println("   🌍 Total zone-days: $total_zones")
    end

    # Calculate success rate
    date_success_rate = total_dates > 0 ? round(100 * successful_dates / total_dates, digits=1) : 0.0
    convergence_rate = successful_dates > 0 ? round(100 * converged_dates / successful_dates, digits=1) : 0.0
    total_time_hours = round(total_time / 3600, digits=2)

    # Set outputs for GitHub Actions
    open(ENV["GITHUB_OUTPUT"], "a") do io
        println(io, "successful_dates=$successful_dates")
        println(io, "total_dates=$total_dates")
        println(io, "failed_dates=$failed_dates")
        println(io, "converged_dates=$converged_dates")
        println(io, "date_success_rate=$date_success_rate")
        println(io, "convergence_rate=$convergence_rate")
        println(io, "total_iterations=$total_iterations")
        println(io, "processing_time_hours=$total_time_hours")
        println(io, "status=success")

        if !isempty(all_prices)
            println(io, "avg_price=$(round(sum(all_prices) / length(all_prices), digits=2))")
            println(io, "min_price=$(round(minimum(all_prices), digits=2))")
            println(io, "max_price=$(round(maximum(all_prices), digits=2))")
            println(io, "total_zone_days=$total_zones")
        end
    end

    # Cleanup workers
    if use_parallel
        println()
        println("🧹 Cleaning up worker processes...")
        rmprocs(filter(id -> id > 1, workers()))
        println("✅ Worker cleanup complete")
    end

    # Exit with appropriate code
    if failed_dates > 0 && successful_dates == 0
        exit(1)
    else
        exit(0)
    end

catch e
    println()
    println("❌ CRITICAL ERROR during iterative multi-zone market clearing:")
    println("Error: $e")
    println(stacktrace(catch_backtrace()))

    # Set failure outputs
    open(ENV["GITHUB_OUTPUT"], "a") do io
        println(io, "successful_dates=0")
        println(io, "total_dates=$total_dates")
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
