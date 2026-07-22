# batch_runners.jl — Date-range and all-zones orchestration (single- and multi-zone), incl. progress reporting and daily summaries.
# Included by ../Euphemia.jl inside `module Euphemia` (definition order preserved).

"""
    run_multi_zone_for_date_range(start_date::Date, end_date::Date;
                                  zones::Vector{String}=String[],
                                  order_method::Symbol=:uc_based,
                                  optimizer::String="auto",
                                  markup_factor::Float64=1.1,
                                  silent::Bool=true,
                                  save_to_db::Bool=false,
                                  skip_existing::Bool=true,
                                  force_rerun::Bool=false,
                                  parallel::Bool=false)

Run multi-zone market clearing with cross-border transmission flows for a date range.

Processes multiple dates sequentially, running `run_multi_zone_market_clearing()` for each date.
Provides comprehensive progress tracking and timing statistics.

# Arguments
- `start_date::Date`: First date to process (inclusive)
- `end_date::Date`: Last date to process (inclusive)
- `zones::Vector{String}`: List of bidding zones to include (default: auto-discover from DB)
- `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for supply bids (default: 1.1)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `save_to_db::Bool`: Whether to save results to database (default: false)
- `skip_existing::Bool`: Whether to skip dates that already have data (default: true)
- `force_rerun::Bool`: Whether to force UC re-solve, bypassing cache (default: false)
- `parallel::Bool`: Whether to run UC for each zone in parallel using Distributed.jl (default: false)

# Returns
- `NamedTuple` with the following fields:
  - `date_results::Vector{NamedTuple}`: Results for each date processed
  - `total_dates::Int`: Total number of dates in the range
  - `successful_dates::Int`: Number of dates processed successfully
  - `failed_dates::Int`: Number of dates that failed
  - `skipped_dates::Int`: Number of dates skipped (if skip_existing=true)
  - `total_time::Float64`: Total processing time for entire date range in seconds
  - `avg_time_per_date::Float64`: Average processing time per date in seconds

Each date result contains:
- `date::Date`: The date processed
- `success::Bool`: Whether the date was processed successfully
- `result::Union{MPCCResult,Nothing}`: The MPCC result (or nothing if failed)
- `elapsed_time::Float64`: Processing time for this date
- `num_zones::Int`: Number of zones processed
- `error_message::String`: Error details (empty if successful)

# Example
```julia
using Euphemia, Dates

# Process a week of multi-zone market clearing
result = run_multi_zone_for_date_range(
    Date(2024, 6, 1),
    Date(2024, 6, 7);
    save_to_db=true
)

println("Processed \$(result.successful_dates)/\$(result.total_dates) dates")
println("Total time: \$(round(result.total_time/60, digits=1)) minutes")
println("Average per date: \$(round(result.avg_time_per_date, digits=1)) seconds")

# Analyze results
for dr in result.date_results
    if dr.success
        println("\$(dr.date): \$(dr.num_zones) zones, \$(round(dr.elapsed_time, digits=1))s")
    else
        println("\$(dr.date): FAILED - \$(dr.error_message)")
    end
end
```
"""
function run_multi_zone_for_date_range(start_date::Date, end_date::Date;
                                       zones::Vector{String}=String[],
                                       order_method::Symbol=:uc_based,
                                       optimizer::String="auto",
                                       markup_factor::Float64=1.1,
                                       silent::Bool=true,
                                       save_to_db::Bool=false,
                                       skip_existing::Bool=true,
                                       force_rerun::Bool=false,
                                       parallel::Bool=false)

    # Validate date range
    if start_date > end_date
        error("start_date ($start_date) cannot be after end_date ($end_date)")
    end

    # Generate date range
    dates = collect(start_date:Day(1):end_date)
    total_dates = length(dates)

    println("=" ^ 70)
    println("🌍 MULTI-ZONE MARKET CLEARING FOR DATE RANGE")
    println("=" ^ 70)
    println("   📅 Date range: $start_date to $end_date ($total_dates days)")
    println("   📋 Order method: $order_method")
    println("   🔧 Optimizer: $optimizer")
    if !isempty(zones)
        println("   🗺️  Zones: $(join(zones, ", "))")
    else
        println("   🗺️  Zones: auto-discover")
    end
    if save_to_db
        println("   💾 Database saving: enabled")
    end
    println()

    range_start_time = time()
    date_results = NamedTuple[]

    successful_dates = 0
    failed_dates = 0
    skipped_dates = 0

    # Check for existing data if skip_existing is enabled
    dates_to_process = dates
    if skip_existing && save_to_db
        try
            println("🔍 Checking for existing multi-zone data...")
            # Check which dates already have data for multi_zone clearing mode
            existing_query = """
                SELECT DISTINCT DATE(date_time_utc) as run_date
                FROM simulations.energy_prices
                WHERE order_method = \$1
                AND clearing_mode = 'multi_zone'
                AND DATE(date_time_utc) >= \$2
                AND DATE(date_time_utc) <= \$3
                AND code_version = \$4
            """
            existing_df = sql2df(existing_query, [string(order_method), start_date, end_date, ENERGY_PRICES_CODE_VERSION])
            existing_dates = Set(Date.(existing_df.run_date))

            dates_to_process = filter(d -> d ∉ existing_dates, dates)
            skipped_count = length(dates) - length(dates_to_process)

            if skipped_count > 0
                skipped_dates = skipped_count
                println("⏭️  Skipping $skipped_count dates with existing data")
            end
        catch e
            @warn "Failed to check existing data, processing all dates: $e"
        end
    end

    if isempty(dates_to_process)
        println("✅ All dates already processed!")
        return (
            date_results=date_results,
            total_dates=total_dates,
            successful_dates=0,
            failed_dates=0,
            skipped_dates=skipped_dates,
            total_time=time() - range_start_time,
            avg_time_per_date=0.0
        )
    end

    println("🚀 Processing $(length(dates_to_process)) dates...")
    println()

    for (i, date) in enumerate(dates_to_process)
        date_start_time = time()

        println("=" ^ 60)
        println("📅 [$i/$(length(dates_to_process))] Processing $date")
        println("=" ^ 60)

        try
            result = run_multi_zone_market_clearing(date;
                                                    zones=zones,
                                                    order_method=order_method,
                                                    optimizer=optimizer,
                                                    markup_factor=markup_factor,
                                                    silent=silent,
                                                    save_to_db=save_to_db,
                                                    force_rerun=force_rerun,
                                                    parallel=parallel)

            date_elapsed = time() - date_start_time

            if result.status == :optimal
                successful_dates += 1
                num_zones = length(keys(result.market_prices))

                push!(date_results, (
                    date=date,
                    success=true,
                    result=result,
                    elapsed_time=date_elapsed,
                    num_zones=num_zones,
                    error_message=""
                ))

                println("\n✅ Date $date completed successfully")
                println("   ⏱️  Time: $(round(date_elapsed, digits=1))s (solver: $(round(result.solve_time, digits=1))s)")
                println("   🗺️  Zones: $num_zones")
            else
                failed_dates += 1

                push!(date_results, (
                    date=date,
                    success=false,
                    result=result,
                    elapsed_time=date_elapsed,
                    num_zones=0,
                    error_message=result.message
                ))

                println("\n❌ Date $date: optimization failed - $(result.message)")
            end

        catch e
            date_elapsed = time() - date_start_time
            failed_dates += 1
            error_msg = string(e)

            push!(date_results, (
                date=date,
                success=false,
                result=nothing,
                elapsed_time=date_elapsed,
                num_zones=0,
                error_message=error_msg
            ))

            println("\n❌ Date $date: EXCEPTION - $(first(split(error_msg, '\n')))")
        end

        # Progress update
        total_elapsed = time() - range_start_time
        remaining_dates = length(dates_to_process) - i
        if i > 0 && remaining_dates > 0
            avg_per_date = total_elapsed / i
            est_remaining = avg_per_date * remaining_dates / 60
            println("   📈 Progress: $i/$(length(dates_to_process)) | Est. remaining: $(round(est_remaining, digits=1)) min")
        end
        println()
    end

    total_time = time() - range_start_time
    processed_count = successful_dates + failed_dates
    avg_time_per_date = processed_count > 0 ? total_time / processed_count : 0.0

    # Print final summary
    println("=" ^ 70)
    println("🏁 MULTI-ZONE DATE RANGE PROCESSING COMPLETE")
    println("=" ^ 70)

    success_rate = total_dates > 0 ? round(100 * successful_dates / (successful_dates + failed_dates + 0.001), digits=1) : 0

    println("📊 Summary:")
    println("   📅 Date range: $start_date to $end_date")
    println("   📆 Total dates: $total_dates")
    if skipped_dates > 0
        println("   ⏭️  Skipped: $skipped_dates")
    end
    println("   ✅ Successful: $successful_dates")
    println("   ❌ Failed: $failed_dates")
    println("   📈 Success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/60, digits=1)) minutes")
    println("   🕒 Average per date: $(round(avg_time_per_date, digits=1)) seconds")

    if failed_dates > 0
        failed_date_list = [r.date for r in date_results if !r.success]
        println("\n❌ Failed dates: $(join(failed_date_list, ", "))")
    end

    return (
        date_results=date_results,
        total_dates=total_dates,
        successful_dates=successful_dates,
        failed_dates=failed_dates,
        skipped_dates=skipped_dates,
        total_time=total_time,
        avg_time_per_date=avg_time_per_date
    )
end

"""
    generate_energy_prices_for_all_zones(date::Date;
                                        order_method::Symbol=:uc_based,
                                        model::Symbol=:mpcc,
                                        optimizer::String="auto",
                                        markup_factor::Float64=1.1,
                                        random_seed::Union{Int,Nothing}=nothing,
                                        silent::Bool=true,
                                        save_to_db::Bool=false,
                                        max_retries::Int=2,
                                        retry_delay::Float64=1.0,
                                        fallback_zones::Vector{String}=String[],
                                        skip_existing::Bool=true,
                                        progress_callback::Union{Function,Nothing}=nothing,
                                        parallel::Bool=false,
                                        max_workers::Union{Int,Nothing}=nothing,
                                        chunk_size::Int=1)

Generate energy prices for all available bidding zones on a specific date.

This function automatically discovers all available bidding zones for the specified date
using `get_available_zones()` and then generates energy prices for each zone using
`generate_energy_prices()`. It includes comprehensive error handling, retry mechanisms,
progress tracking, and optional parallel processing.

# Arguments
- `date::Date`: The date for which to generate prices for all zones
- `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
- `model::Symbol`: Market clearing model - `:mpcc` (default, more may be added later)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
- `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `save_to_db::Bool`: Whether to save results to database (default: false)
- `max_retries::Int`: Maximum retry attempts per zone (default: 2)
- `retry_delay::Float64`: Delay between retry attempts in seconds (default: 1.0)
- `fallback_zones::Vector{String}`: Custom fallback zones if zone discovery fails (default: empty)
- `skip_existing::Bool`: Whether to skip zones that already have data in database (default: true)
- `progress_callback::Union{Function,Nothing}`: Optional callback function for progress updates (default: nothing)
- `parallel::Bool`: Whether to use parallel processing (default: false)
- `max_workers::Union{Int,Nothing}`: Maximum number of parallel workers to use (default: auto-detect)
- `chunk_size::Int`: Number of zones to process per worker batch (default: 1)

# Returns
- `NamedTuple` with the following fields:
  - `results::Vector{NamedTuple}`: Detailed results for each zone
  - `success_count::Int`: Number of zones processed successfully
  - `failure_count::Int`: Number of zones that failed
  - `skipped_count::Int`: Number of zones skipped (if skip_existing=true)
  - `total_zones::Int`: Total number of zones discovered
  - `total_time::Float64`: Total processing time in seconds
  - `successful_zones::Vector{String}`: List of successfully processed zones
  - `failed_zones::Vector{String}`: List of zones that failed
  - `skipped_zones::Vector{String}`: List of zones that were skipped
  - `parallel_workers::Int`: Number of parallel workers used (1 if parallel=false)

Each result in `results` contains:
- `zone::String`: Bidding zone code
- `success::Bool`: Whether processing was successful
- `prices::Dict{String,Float64}`: Energy prices (empty if failed)
- `periods::Int`: Number of price periods generated
- `elapsed_time::Float64`: Processing time for this zone
- `min_price::Float64`, `max_price::Float64`, `avg_price::Float64`: Price statistics
- `error_message::String`: Error details (empty if successful)
- `attempt::Int`: Number of attempts made (including retries)
- `worker_id::Int`: ID of the worker that processed this zone

# Examples
```julia
using Euphemia, Dates

# Basic usage - generate prices for all zones on a specific date
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1))
println("Success: \$(result.success_count)/\$(result.total_zones) zones")

# With parallel processing using all available cores
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    parallel=true)
println("Processed with \$(result.parallel_workers) workers")

# With parallel processing and limited workers
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    parallel=true,
    max_workers=16,
    chunk_size=2)

# With database saving and Gurobi optimizer (parallel)
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    optimizer="gurobi",
    save_to_db=true,
    silent=true,
    parallel=true)

# With custom progress callback (note: callbacks work differently in parallel mode)
function my_progress(zone, current, total, elapsed)
    println("Processing \$zone (\$current/\$total) - \$(round(elapsed, digits=1))s")
end

result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    progress_callback=my_progress)

# Check detailed results
for zone_result in result.results
    if zone_result.success
        println("\$(zone_result.zone): \$(zone_result.periods) periods, €\$(zone_result.avg_price)/MWh avg (worker \$(zone_result.worker_id))")
    else
        println("\$(zone_result.zone): FAILED - \$(zone_result.error_message) (worker \$(zone_result.worker_id))")
    end
end

# Using alternative order book method with parallel processing
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    order_method=:alternative,
    random_seed=42,
    parallel=true,
    max_workers=32)
```

# Parallel Processing
When `parallel=true`, the function will:
1. Automatically detect available workers or use `max_workers` if specified
2. Distribute zones across workers in batches of size `chunk_size`
3. Process zones concurrently, significantly reducing total processing time
4. Aggregate results from all workers
5. Progress callbacks work but are called less frequently due to batching

Note: Parallel processing requires worker processes to be started before calling this function.
Workers should be set up externally using `addprocs(n)` or `julia -p n`, and the Euphemia 
package should be loaded on all workers using `@everywhere using Euphemia`.

Example setup:
```julia
using Distributed
addprocs(4)
@everywhere using Euphemia

# Now call parallel batch processing
result = generate_energy_prices_for_all_zones(date; parallel=true)
```

# Progress Callback
If provided, the progress_callback function will be called after each zone (sequential mode)
or after each worker batch (parallel mode) with signature:
`progress_callback(zone::String, current_index::Int, total_zones::Int, elapsed_time::Float64)`

# Database Integration
When `save_to_db=true`, the function will:
1. Check for existing data and skip zones if `skip_existing=true`
2. Save both optimization runs and energy prices to the database
3. Handle database constraint violations gracefully
4. Continue processing even if database saves fail
5. In parallel mode, each worker handles its own database connections

# Error Handling
The function includes robust error handling:
- Retry mechanism for transient failures
- Detailed error logging and reporting
- Graceful degradation (continues even if individual zones fail)
- Comprehensive result tracking for analysis
- In parallel mode, worker failures are isolated and reported
"""
function generate_energy_prices_for_all_zones(date::Date;
    order_method::Symbol=:uc_based,
    model::Symbol=:mpcc,
    optimizer::String="auto",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=false,
    max_retries::Int=2,
    retry_delay::Float64=1.0,
    fallback_zones::Vector{String}=String[],
    skip_existing::Bool=true,
    progress_callback::Union{Function,Nothing}=nothing,
    parallel::Bool=false,
    max_workers::Union{Int,Nothing}=nothing,
    chunk_size::Int=1,
    force_rerun::Bool=false)

    start_time = time()

    # Determine number of workers for parallel processing
    workers_used = 1
    println("🔍 Debug: parallel=$parallel, max_workers=$max_workers")
    println("🔍 Debug: CPU threads detected: $(Sys.CPU_THREADS)")
    println("🔍 Debug: Current workers: $(workers())")

    if parallel
        # Check for existing worker processes (user should have set these up)
        worker_ids = filter(id -> id != 1, workers())
        available_workers = length(worker_ids)
        println("🔍 Debug: Filtered worker IDs (excluding main process): $worker_ids")

        if available_workers == 0
            @warn "Parallel processing requested but no worker processes found. Please start workers before calling this function. Falling back to sequential processing."
            parallel = false
            workers_used = 1
        else
            workers_used = isnothing(max_workers) ? available_workers : min(max_workers, available_workers)
            println("🚀 Parallel processing enabled with $workers_used existing workers: $worker_ids")
        end
    end

    # Discover available zones
    println("🔍 Discovering available bidding zones for $date...")
    available_zones = get_available_zones(date; fallback_zones=fallback_zones)

    if isempty(available_zones)
        @warn "No bidding zones discovered for $date"
        return (
            results=NamedTuple[],
            success_count=0,
            failure_count=0,
            skipped_count=0,
            total_zones=0,
            total_time=0.0,
            successful_zones=String[],
            failed_zones=String[],
            skipped_zones=String[],
            parallel_workers=workers_used
        )
    end

    println("✅ Found $(length(available_zones)) zones: $(join(available_zones[1:min(10, length(available_zones))], ", "))$(length(available_zones) > 10 ? "..." : "")")

    # Check for existing data if skip_existing is enabled and save_to_db is true
    zones_to_process = available_zones
    skipped_zones = String[]

    if skip_existing && save_to_db
        try
            println("🔍 Checking for existing data...")
            existing_query = """
                SELECT DISTINCT bidding_zone
                FROM simulations.energy_prices
                WHERE DATE(date_time_utc) = \$1
                AND order_method = \$2
                AND clearing_mode = 'single_zone'
                AND code_version = \$3
            """
            existing_df = sql2df(existing_query, [date, string(order_method), ENERGY_PRICES_CODE_VERSION])
            existing_zones = Set(string(zone) for zone in existing_df.bidding_zone)

            zones_to_process = filter(zone -> zone ∉ existing_zones, available_zones)
            skipped_zones = filter(zone -> zone ∈ existing_zones, available_zones)

            if !isempty(skipped_zones)
                println("⏭️  Skipping $(length(skipped_zones)) zones with existing data: $(join(skipped_zones, ", "))")
            end
        catch e
            @warn "Failed to check existing data, processing all zones: $e"
        end
    end

    if isempty(zones_to_process)
        println("✅ All zones already processed!")
        return (
            results=NamedTuple[],
            success_count=0,
            failure_count=0,
            skipped_count=length(skipped_zones),
            total_zones=length(available_zones),
            total_time=time() - start_time,
            successful_zones=String[],
            failed_zones=String[],
            skipped_zones=skipped_zones,
            parallel_workers=workers_used
        )
    end

    println("🚀 Processing $(length(zones_to_process)) zones$(parallel ? " in parallel with $workers_used workers" : " sequentially with 1 worker")...")
    println("="^60)

    # Choose processing method
    if parallel
        results = _process_zones_parallel(
            zones_to_process, date, order_method, model, optimizer,
            markup_factor, random_seed, silent, save_to_db,
            max_retries, retry_delay, progress_callback, chunk_size, force_rerun
        )
    else
        results = _process_zones_sequential(
            zones_to_process, date, order_method, model, optimizer,
            markup_factor, random_seed, silent, save_to_db,
            max_retries, retry_delay, progress_callback, start_time, force_rerun
        )
    end

    # Aggregate results
    success_count = sum(r.success for r in results)
    failure_count = length(results) - success_count
    successful_zones = [r.zone for r in results if r.success]
    failed_zones = [r.zone for r in results if !r.success]

    total_time = time() - start_time

    # Print summary
    println("\n" * "="^60)
    println("🏁 PROCESSING OF AVAILABLE BIDDING ZONES FOR $date COMPLETE")
    println("="^60)

    total_processed = length(zones_to_process)
    success_rate = total_processed > 0 ? round(100 * success_count / total_processed, digits=1) : 0

    println("📊 Overall Statistics:")
    println("   🎯 Total zones discovered: $(length(available_zones))")
    if !isempty(skipped_zones)
        println("   ⏭️  Skipped zones: $(length(skipped_zones))")
    end
    println("   🔄 Processed zones: $total_processed")
    if parallel
        println("   ⚡ Parallel workers: $workers_used")
    end
    println("   ✅ Successful: $success_count")
    println("   ❌ Failed: $failure_count")
    println("   📈 Success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/60, digits=1)) minutes")
    if total_processed > 0
        println("   🕒 Average per zone: $(round(total_time/total_processed, digits=1)) seconds")
    end

    if success_count > 0
        successful_results = filter(r -> r.success, results)
        total_periods = sum(r.periods for r in successful_results)
        avg_solve_time = sum(r.elapsed_time for r in successful_results) / success_count

        avg_prices = [r.avg_price for r in successful_results if r.avg_price > 0]
        if !isempty(avg_prices)
            min_prices = [r.min_price for r in successful_results if r.min_price > 0]
            max_prices = [r.max_price for r in successful_results if r.max_price > 0]
            overall_min = isempty(min_prices) ? 0.0 : minimum(min_prices)
            overall_max = isempty(max_prices) ? 0.0 : maximum(max_prices)
            overall_avg = sum(avg_prices) / length(avg_prices)

            println("\n💰 Price Statistics (successful zones):")
            println("   📊 Total periods: $total_periods")
            println("   ⏱️  Avg solve time: $(round(avg_solve_time, digits=2))s")
            println("   💵 Price range: €$(round(overall_min, digits=2)) - €$(round(overall_max, digits=2))/MWh")
            println("   📈 Average price: €$(round(overall_avg, digits=2))/MWh")
        end
    end

    if failure_count > 0
        println("\n❌ Failed Zones: $(join(failed_zones, ", "))")
    end

    return (
        results=results,
        success_count=success_count,
        failure_count=failure_count,
        skipped_count=length(skipped_zones),
        total_zones=length(available_zones),
        total_time=total_time,
        successful_zones=successful_zones,
        failed_zones=failed_zones,
        skipped_zones=skipped_zones,
        parallel_workers=workers_used
    )
end

"""
    generate_energy_prices_for_date_range(start_date::Date, end_date::Date;
                                          order_method::Symbol=:uc_based,
                                          model::Symbol=:mpcc,
                                          optimizer::String="auto",
                                          markup_factor::Float64=1.1,
                                          random_seed::Union{Int,Nothing}=nothing,
                                          silent::Bool=true,
                                          save_to_db::Bool=true,
                                          max_retries::Int=2,
                                          retry_delay::Float64=1.0,
                                          fallback_zones::Vector{String}=String[],
                                          skip_existing::Bool=true,
                                          progress_callback::Union{Function,Nothing}=nothing,
                                          parallel::Bool=false,
                                          max_workers::Union{Int,Nothing}=nothing,
                                          chunk_size::Int=1)

Generate energy prices for all available bidding zones across a date range.

This function processes multiple dates sequentially, calling `generate_energy_prices_for_all_zones()`
for each date in the specified range. It provides comprehensive progress tracking, error handling,
and result aggregation across the entire date range.

# Arguments
- `start_date::Date`: First date to process (inclusive)
- `end_date::Date`: Last date to process (inclusive)
- All other arguments are passed through to `generate_energy_prices_for_all_zones()`:
  - `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
  - `model::Symbol`: Market clearing model - `:mpcc` (default)
  - `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
  - `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
  - `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
  - `silent::Bool`: Whether to suppress solver output (default: true)
  - `save_to_db::Bool`: Whether to save results to database (default: true for bulk operations)
  - `max_retries::Int`: Maximum retry attempts per zone (default: 2)
  - `retry_delay::Float64`: Delay between retry attempts in seconds (default: 1.0)
  - `fallback_zones::Vector{String}`: Custom fallback zones if zone discovery fails (default: empty)
  - `skip_existing::Bool`: Whether to skip zones that already have data in database (default: true)
  - `progress_callback::Union{Function,Nothing}`: Optional callback function for progress updates (default: nothing)
  - `parallel::Bool`: Whether to use parallel processing (default: false)
  - `max_workers::Union{Int,Nothing}`: Maximum number of parallel workers to use (default: auto-detect)
  - `chunk_size::Int`: Number of zones to process per worker batch (default: 1)

# Returns
- `NamedTuple` with the following fields:
  - `date_results::Vector{NamedTuple}`: Results for each date processed
  - `total_dates::Int`: Total number of dates in the range
  - `successful_dates::Int`: Number of dates processed successfully
  - `failed_dates::Int`: Number of dates that failed completely
  - `total_zones_processed::Int`: Total number of zone-date combinations processed
  - `total_zones_successful::Int`: Total number of zone-date combinations that succeeded
  - `total_time::Float64`: Total processing time for entire date range in seconds
  - `start_date::Date`, `end_date::Date`: Date range processed
  - `daily_summaries::Vector{NamedTuple}`: Summary statistics per date

Each date result in `date_results` contains:
- `date::Date`: The date processed
- `success::Bool`: Whether the date was processed successfully (at least one zone succeeded)
- `zones_result::NamedTuple`: Full result from `generate_energy_prices_for_all_zones()` for this date
- `elapsed_time::Float64`: Processing time for this date
- `zones_discovered::Int`: Number of zones discovered for this date
- `zones_successful::Int`: Number of zones processed successfully for this date
- `zones_failed::Int`: Number of zones that failed for this date
- `zones_skipped::Int`: Number of zones skipped for this date

Each summary in `daily_summaries` contains:
- `date::Date`: The date
- `zones_total::Int`: Total zones for this date
- `zones_successful::Int`: Successful zones for this date
- `success_rate::Float64`: Success rate percentage for this date
- `avg_price::Float64`: Average price across all successful zones (if any)
- `min_price::Float64`, `max_price::Float64`: Price extremes for this date
- `total_periods::Int`: Total price periods generated for this date

# Examples
```julia
using Euphemia, Dates

# Process a single month
result = generate_energy_prices_for_date_range(
    Date(2024, 10, 1), 
    Date(2024, 10, 31)
)

# Process with parallel processing and database saving
result = generate_energy_prices_for_date_range(
    Date(2024, 1, 1), 
    Date(2024, 1, 7);
    parallel=true,
    max_workers=20,
    save_to_db=true,
    optimizer="gurobi"
)

# Process specific date range with custom progress tracking
function date_progress(date, current, total, elapsed)
    println("📅 Date \$date completed (\$current/\$total) - \$(round(elapsed/60, digits=1)) min")
end

result = generate_energy_prices_for_date_range(
    Date(2024, 6, 1), 
    Date(2024, 6, 30);
    progress_callback=date_progress,
    save_to_db=true
)

# Check results
println("Processed \$(result.successful_dates)/\$(result.total_dates) dates successfully")
println("Total zones processed: \$(result.total_zones_successful)/\$(result.total_zones_processed)")
println("Total time: \$(round(result.total_time/3600, digits=1)) hours")

# Analyze daily summaries
for summary in result.daily_summaries
    if summary.zones_successful > 0
        println("\$(summary.date): \$(summary.zones_successful) zones, €\$(round(summary.avg_price, digits=2))/MWh avg")
    end
end

# Check failed dates
failed_dates = [r.date for r in result.date_results if !r.success]
if !isempty(failed_dates)
    println("Failed dates: \$(join(failed_dates, \", \"))")
end
```

# Date Range Processing
- Processes dates sequentially from start_date to end_date (inclusive)
- Each date is processed independently using `generate_energy_prices_for_all_zones()`
- Failed dates don't stop processing of remaining dates
- Comprehensive progress tracking and error reporting per date
- Automatic aggregation of statistics across the entire date range

# Performance Considerations
- Parallel date processing when `parallel=true` (zones within each date are processed sequentially)
- Sequential date processing when `parallel=false` (zones within each date are also processed sequentially)
- Memory efficient - each worker processes one date's zones sequentially
- Database operations are distributed across parallel date workers when `save_to_db=true`
- Progress callbacks help monitor long-running operations

# Error Handling
- Date-level errors are captured and reported but don't stop processing
- Zone-level errors are handled by the underlying `generate_energy_prices_for_all_zones()` function
- Comprehensive error reporting with per-date breakdowns
- Failed dates are clearly identified in results
"""
function generate_energy_prices_for_date_range(start_date::Date, end_date::Date;
    order_method::Symbol=:uc_based,
    model::Symbol=:mpcc,
    optimizer::String="auto",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=true,  # Default true for bulk operations
    max_retries::Int=2,
    retry_delay::Float64=1.0,
    fallback_zones::Vector{String}=String[],
    skip_existing::Bool=true,
    progress_callback::Union{Function,Nothing}=nothing,
    parallel::Bool=false,
    max_workers::Union{Int,Nothing}=nothing,
    chunk_size::Int=1,
    force_rerun::Bool=false)

    # Validate date range
    if start_date > end_date
        error("start_date ($start_date) cannot be after end_date ($end_date)")
    end

    # Generate date range
    dates = collect(start_date:Day(1):end_date)
    total_dates = length(dates)

    println("📅 Starting date range processing")
    println("="^60)
    println("   📍 Date range: $start_date to $end_date")
    println("   📊 Total dates: $total_dates")
    println("   📋 Order method: $order_method")
    println("   ⚖️  Model: $model")
    println("   🔧 Optimizer: $optimizer")
    if parallel
        println("   ⚡ Parallel processing: enabled")
    end
    if save_to_db
        println("   💾 Database saving: enabled")
    end
    println()

    range_start_time = time()
    date_results = NamedTuple[]
    daily_summaries = NamedTuple[]

    successful_dates = 0
    failed_dates = 0
    total_zones_processed = 0
    total_zones_successful = 0

    # Choose processing method: parallel dates vs sequential dates
    if parallel
        # Check for existing worker processes
        worker_ids = filter(id -> id != 1, workers())
        available_workers = length(worker_ids)

        if available_workers == 0
            @warn "Parallel date processing requested but no worker processes found. Please start workers before calling this function. Falling back to sequential date processing."
            parallel = false
        else
            workers_used = isnothing(max_workers) ? available_workers : min(max_workers, available_workers)
            println("🚀 Processing dates in parallel with $workers_used workers")

            # Process dates in parallel using pmap
            date_results = _process_dates_parallel(
                dates, order_method, model, optimizer, markup_factor,
                random_seed, silent, save_to_db, max_retries, retry_delay,
                fallback_zones, skip_existing, range_start_time, force_rerun
            )

            # Aggregate results from parallel processing
            successful_dates = sum(r.success for r in date_results)
            failed_dates = length(date_results) - successful_dates
            total_zones_processed = sum(r.zones_discovered for r in date_results)
            total_zones_successful = sum(r.zones_successful for r in date_results)

            # Generate daily summaries from results
            daily_summaries = _generate_daily_summaries(date_results)
        end
    else
        # Sequential date processing (fallback or when parallel=false)
        consecutive_failures = 0  # Track consecutive date failures
        max_consecutive_failures = 5  # Stop after 5 consecutive date failures

        for (i, date) in enumerate(dates)
            date_start_time = time()

            println("📅 [$i/$total_dates] Processing $date")
            println("-"^50)

            try
                # Process all zones for this date (always sequential when in date loop)
                zones_result = generate_energy_prices_for_all_zones(date;
                    order_method=order_method,
                    model=model,
                    optimizer=optimizer,
                    markup_factor=markup_factor,
                    random_seed=random_seed,
                    silent=silent,
                    save_to_db=save_to_db,
                    max_retries=max_retries,
                    retry_delay=retry_delay,
                    fallback_zones=fallback_zones,
                    skip_existing=skip_existing,
                    progress_callback=nothing,  # Disable per-zone callbacks to avoid clutter
                    parallel=false,  # Force sequential zones when processing dates in sequence
                    max_workers=1,
                    chunk_size=1,
                    force_rerun=force_rerun)

                date_elapsed = time() - date_start_time

                # Determine if date was successful (at least one zone succeeded)
                date_successful = zones_result.success_count > 0
                if date_successful
                    successful_dates += 1
                    consecutive_failures = 0  # Reset consecutive failure counter
                else
                    failed_dates += 1
                    consecutive_failures += 1
                end

                # Early termination if too many consecutive failures (likely systematic issue)
                if consecutive_failures >= max_consecutive_failures
                    println("🛑 EARLY TERMINATION: $consecutive_failures consecutive date failures detected.")
                    println("   This suggests a systematic issue (e.g., worker initialization problem).")
                    println("   Stopping to prevent infinite loop and resource waste.")
                    break
                end

                # Update totals
                total_zones_processed += zones_result.success_count + zones_result.failure_count
                total_zones_successful += zones_result.success_count

                # Create date result
                date_result = (
                    date=date,
                    success=date_successful,
                    zones_result=zones_result,
                    elapsed_time=date_elapsed,
                    zones_discovered=zones_result.total_zones,
                    zones_successful=zones_result.success_count,
                    zones_failed=zones_result.failure_count,
                    zones_skipped=zones_result.skipped_count
                )
                push!(date_results, date_result)

                # Create daily summary with price statistics
                if zones_result.success_count > 0
                    successful_results = filter(r -> r.success, zones_result.results)
                    all_prices = Float64[]
                    total_periods = 0

                    for zone_result in successful_results
                        if !isempty(zone_result.prices)
                            append!(all_prices, collect(values(zone_result.prices)))
                            total_periods += zone_result.periods
                        end
                    end

                    if !isempty(all_prices)
                        daily_summary = (
                            date=date,
                            zones_total=zones_result.total_zones,
                            zones_successful=zones_result.success_count,
                            success_rate=round(100 * zones_result.success_count / max(1, zones_result.total_zones), digits=1),
                            avg_price=round(sum(all_prices) / length(all_prices), digits=2),
                            min_price=round(minimum(all_prices), digits=2),
                            max_price=round(maximum(all_prices), digits=2),
                            total_periods=total_periods
                        )
                    else
                        daily_summary = (
                            date=date,
                            zones_total=zones_result.total_zones,
                            zones_successful=zones_result.success_count,
                            success_rate=round(100 * zones_result.success_count / max(1, zones_result.total_zones), digits=1),
                            avg_price=0.0,
                            min_price=0.0,
                            max_price=0.0,
                            total_periods=0
                        )
                    end
                else
                    daily_summary = (
                        date=date,
                        zones_total=zones_result.total_zones,
                        zones_successful=0,
                        success_rate=0.0,
                        avg_price=0.0,
                        min_price=0.0,
                        max_price=0.0,
                        total_periods=0
                    )
                end
                push!(daily_summaries, daily_summary)

                # Print date summary
                if date_successful
                    println("✅ Date $date: $(zones_result.success_count)/$(zones_result.total_zones) zones successful")
                    if zones_result.success_count > 0 && daily_summary.avg_price > 0
                        println("   💰 Price range: €$(daily_summary.min_price) - €$(daily_summary.max_price)/MWh (avg: €$(daily_summary.avg_price))")
                    end
                else
                    println("❌ Date $date: All zones failed")
                end

                println("   ⏱️  Date processing time: $(round(date_elapsed/60, digits=1)) minutes")

            catch date_error
                date_elapsed = time() - date_start_time
                failed_dates += 1
                consecutive_failures += 1

                # Early termination check for critical errors
                if consecutive_failures >= max_consecutive_failures
                    println("🛑 EARLY TERMINATION: $consecutive_failures consecutive critical failures.")
                    println("   Error: $date_error")
                    println("   Stopping to prevent infinite loop and resource waste.")
                    break
                end

                # Create failed date result
                date_result = (
                    date=date,
                    success=false,
                    zones_result=nothing,
                    elapsed_time=date_elapsed,
                    zones_discovered=0,
                    zones_successful=0,
                    zones_failed=0,
                    zones_skipped=0
                )
                push!(date_results, date_result)

                daily_summary = (
                    date=date,
                    zones_total=0,
                    zones_successful=0,
                    success_rate=0.0,
                    avg_price=0.0,
                    min_price=0.0,
                    max_price=0.0,
                    total_periods=0
                )
                push!(daily_summaries, daily_summary)

                println("❌ Date $date: CRITICAL FAILURE - $(date_error)")
            end

            # Call progress callback if provided
            if progress_callback !== nothing
                try
                    progress_callback(date, i, total_dates, time() - range_start_time)
                catch callback_error
                    @warn "Date-level progress callback failed: $callback_error"
                end
            end

            # Overall progress update
            total_elapsed = time() - range_start_time
            remaining_dates = total_dates - i
            est_remaining = remaining_dates > 0 ? (total_elapsed / i) * remaining_dates / 60 : 0
            println("   📈 Overall progress: $i/$total_dates dates | Est. remaining: $(round(est_remaining, digits=1)) min")
            println()
        end  # End sequential processing loop
    end  # End sequential processing block

    total_time = time() - range_start_time

    # Print final summary
    println("="^60)
    println("🏁 DATE RANGE PROCESSING COMPLETE")
    println("="^60)

    success_rate = total_dates > 0 ? round(100 * successful_dates / total_dates, digits=1) : 0
    zone_success_rate = total_zones_processed > 0 ? round(100 * total_zones_successful / total_zones_processed, digits=1) : 0

    println("📊 Date Range Summary:")
    println("   📅 Date range: $start_date to $end_date")
    println("   📆 Total dates: $total_dates")
    println("   ✅ Successful dates: $successful_dates")
    println("   ❌ Failed dates: $failed_dates")
    println("   📈 Date success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/3600, digits=1)) hours")
    println("   🕒 Average per date: $(round(total_time/total_dates/60, digits=1)) minutes")

    println("\n🌍 Zone Processing Summary:")
    println("   🔄 Total zone-date combinations: $total_zones_processed")
    println("   ✅ Successful zone-date combinations: $total_zones_successful")
    println("   📈 Zone success rate: $zone_success_rate%")

    if total_zones_successful > 0
        successful_summaries = filter(s -> s.zones_successful > 0, daily_summaries)
        if !isempty(successful_summaries)
            avg_daily_price = sum(s.avg_price * s.zones_successful for s in successful_summaries) / sum(s.zones_successful for s in successful_summaries)
            min_prices = [s.min_price for s in successful_summaries if s.min_price > 0]
            max_prices = [s.max_price for s in successful_summaries if s.max_price > 0]
            overall_min = isempty(min_prices) ? 0.0 : minimum(min_prices)
            overall_max = isempty(max_prices) ? 0.0 : maximum(max_prices)

            println("\n💰 Price Statistics:")
            println("   📊 Overall price range: €$(overall_min) - €$(overall_max)/MWh")
            println("   📈 Weighted average price: €$(round(avg_daily_price, digits=2))/MWh")
        end
    end

    if failed_dates > 0
        failed_date_list = [r.date for r in date_results if !r.success]
        println("\n❌ Failed dates: $(join(failed_date_list, ", "))")
    end

    return (
        date_results=date_results,
        total_dates=total_dates,
        successful_dates=successful_dates,
        failed_dates=failed_dates,
        total_zones_processed=total_zones_processed,
        total_zones_successful=total_zones_successful,
        total_time=total_time,
        start_date=start_date,
        end_date=end_date,
        daily_summaries=daily_summaries
    )
end

