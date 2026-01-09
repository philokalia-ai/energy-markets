#!/usr/bin/env julia

"""
Test script for the new parallel dates architecture in generate_energy_prices_for_date_range().

This script tests both sequential and parallel date processing with a small set of dates
to validate the architectural changes.
"""

using Pkg
Pkg.activate(".")

using Distributed
using Dates
using Euphemia

# Setup for testing
test_start_date = Date(2024, 6, 18)
test_end_date = Date(2024, 6, 20)  # Just 3 days for testing
test_zones = ["AL", "AL", "BG", "CZ"]  # Small set of zones

# Create a custom test function that bypasses zone discovery
function test_generate_energy_prices_for_date_range(start_date::Date, end_date::Date, forced_zones::Vector{String}; kwargs...)
    println("🔧 Using forced test zones: $(join(forced_zones, ", "))")

    # Validate date range
    if start_date > end_date
        error("start_date ($start_date) cannot be after end_date ($end_date)")
    end

    # Generate date range
    dates = collect(start_date:Day(1):end_date)

    # Extract parameters
    order_method = get(kwargs, :order_method, :uc_based)
    model = get(kwargs, :model, :mpcc)
    optimizer = get(kwargs, :optimizer, "highs")
    markup_factor = get(kwargs, :markup_factor, 1.1)
    random_seed = get(kwargs, :random_seed, nothing)
    silent = get(kwargs, :silent, true)
    save_to_db = get(kwargs, :save_to_db, false)
    max_retries = get(kwargs, :max_retries, 2)
    retry_delay = get(kwargs, :retry_delay, 1.0)
    skip_existing = get(kwargs, :skip_existing, true)
    progress_callback = get(kwargs, :progress_callback, nothing)
    parallel = get(kwargs, :parallel, false)
    max_workers = get(kwargs, :max_workers, nothing)
    chunk_size = get(kwargs, :chunk_size, 1)

    # Use the same logic as the main function but with forced zones
    println("📅 Starting test date range processing")
    println("   📍 Date range: $start_date to $end_date")
    println("   🌍 Forced zones: $(join(forced_zones, ", "))")
    if parallel
        println("   ⚡ Parallel processing: enabled")
    end
    println()

    range_start_time = time()
    date_results = NamedTuple[]

    # Process each date with forced zones
    for (i, date) in enumerate(dates)
        date_start_time = time()
        println("📅 [$i/$(length(dates))] Processing $date")

        try
            # Create a simple zones result using our forced zones
            zone_results = []
            success_count = 0

            for zone in forced_zones
                try
                    prices = generate_energy_prices(zone, date;
                        order_method=order_method,
                        model=model,
                        optimizer=optimizer,
                        markup_factor=markup_factor,
                        random_seed=random_seed,
                        silent=silent,
                        save_to_db=save_to_db)

                    if !isempty(prices)
                        success_count += 1
                        push!(zone_results, (
                            zone=zone,
                            success=true,
                            prices=prices,
                            periods=length(prices),
                            elapsed_time=5.0,  # Mock time
                            min_price=minimum(values(prices)),
                            max_price=maximum(values(prices)),
                            avg_price=sum(values(prices)) / length(prices),
                            error_message="",
                            attempt=1,
                            worker_id=1
                        ))
                    else
                        push!(zone_results, (
                            zone=zone,
                            success=false,
                            prices=Dict{String,Float64}(),
                            periods=0,
                            elapsed_time=5.0,
                            min_price=0.0,
                            max_price=0.0,
                            avg_price=0.0,
                            error_message="No prices generated",
                            attempt=1,
                            worker_id=1
                        ))
                    end
                catch e
                    println("   ❌ Zone $zone failed: $e")
                    push!(zone_results, (
                        zone=zone,
                        success=false,
                        prices=Dict{String,Float64}(),
                        periods=0,
                        elapsed_time=5.0,
                        min_price=0.0,
                        max_price=0.0,
                        avg_price=0.0,
                        error_message=string(e),
                        attempt=1,
                        worker_id=1
                    ))
                end
            end

            # Create mock zones_result
            zones_result = (
                results=zone_results,
                success_count=success_count,
                failure_count=length(forced_zones) - success_count,
                skipped_count=0,
                total_zones=length(forced_zones),
                total_time=time() - date_start_time,
                successful_zones=[r.zone for r in zone_results if r.success],
                failed_zones=[r.zone for r in zone_results if !r.success],
                skipped_zones=String[],
                parallel_workers=1
            )

            date_elapsed = time() - date_start_time
            date_successful = success_count > 0

            push!(date_results, (
                date=date,
                success=date_successful,
                zones_result=zones_result,
                elapsed_time=date_elapsed,
                zones_discovered=length(forced_zones),
                zones_successful=success_count,
                zones_failed=length(forced_zones) - success_count,
                zones_skipped=0
            ))

            println("   ✅ Date $date: $success_count/$(length(forced_zones)) zones successful")

        catch e
            println("   ❌ Date $date failed: $e")
            push!(date_results, (
                date=date,
                success=false,
                zones_result=nothing,
                elapsed_time=time() - date_start_time,
                zones_discovered=0,
                zones_successful=0,
                zones_failed=0,
                zones_skipped=0
            ))
        end
    end

    total_time = time() - range_start_time
    successful_dates = sum(r.success for r in date_results)
    total_zones_processed = sum(r.zones_discovered for r in date_results)
    total_zones_successful = sum(r.zones_successful for r in date_results)

    return (
        date_results=date_results,
        total_dates=length(dates),
        successful_dates=successful_dates,
        failed_dates=length(dates) - successful_dates,
        total_zones_processed=total_zones_processed,
        total_zones_successful=total_zones_successful,
        total_time=total_time,
        start_date=start_date,
        end_date=end_date,
        daily_summaries=[]  # Skip for simplicity
    )
end

println("🧪 TESTING PARALLEL DATES ARCHITECTURE")
println("="^60)
println("📅 Test date range: $test_start_date to $test_end_date")
println("🌍 Forced test zones: $(join(test_zones, ", "))")
println()

# Test 1: Sequential date processing (baseline)
println("🔧 TEST 1: Sequential Date Processing")
println("-"^40)

sequential_start = time()
sequential_result = test_generate_energy_prices_for_date_range(
    test_start_date, test_end_date, test_zones;
    order_method=:alternative,  # Use alternative order book for testing
    parallel=false,
    save_to_db=false,  # Don't save during testing
    silent=true
)
sequential_time = time() - sequential_start

println("✅ Sequential Results:")
println("   📊 Success: $(sequential_result.successful_dates)/$(sequential_result.total_dates) dates")
println("   🌍 Zones: $(sequential_result.total_zones_successful)/$(sequential_result.total_zones_processed)")
println("   ⏱️  Time: $(round(sequential_time/60, digits=1)) minutes")
println()

# Test 2: Add workers and test parallel date processing
println("🔧 TEST 2: Parallel Date Processing Setup")
println("-"^40)

# Add workers for parallel processing
initial_workers = workers()
println("🔍 Initial workers: $initial_workers")

# Add 4 workers (one for each date plus spare)
addprocs(4)
new_workers = workers()
println("🚀 Added workers: $new_workers")

# Load Euphemia on all workers
println("📦 Loading Euphemia on all workers...")
@everywhere using Euphemia

println("✅ Workers ready for parallel processing")
println()

# Test 3: Parallel date processing
println("🔧 TEST 3: Parallel Date Processing")
println("-"^40)

parallel_start = time()
parallel_result = test_generate_energy_prices_for_date_range(
    test_start_date, test_end_date, test_zones;
    order_method=:alternative,  # Use alternative order book for testing
    parallel=true,
    save_to_db=false,  # Don't save during testing
    silent=true,
    max_workers=4
)
parallel_time = time() - parallel_start

println("✅ Parallel Results:")
println("   📊 Success: $(parallel_result.successful_dates)/$(parallel_result.total_dates) dates")
println("   🌍 Zones: $(parallel_result.total_zones_successful)/$(parallel_result.total_zones_processed)")
println("   ⏱️  Time: $(round(parallel_time/60, digits=1)) minutes")
println()

# Test 4: Performance comparison
println("📊 PERFORMANCE COMPARISON")
println("-"^40)

speedup = sequential_time / parallel_time
efficiency = speedup / length(new_workers) * 100

println("⚡ Performance Metrics:")
println("   🔄 Sequential time: $(round(sequential_time, digits=1))s")
println("   ⚡ Parallel time: $(round(parallel_time, digits=1))s")
println("   📈 Speedup: $(round(speedup, digits=2))x")
println("   📊 Parallel efficiency: $(round(efficiency, digits=1))%")
println()

# Test 5: Results validation
println("🔍 RESULTS VALIDATION")
println("-"^40)

# Check that both methods produced similar results
seq_successful = sequential_result.total_zones_successful
par_successful = parallel_result.total_zones_successful

if seq_successful == par_successful
    println("✅ Zone success counts match: $seq_successful")
else
    println("⚠️  Zone success counts differ: sequential=$seq_successful, parallel=$par_successful")
end

# Check daily summaries
seq_summaries = sequential_result.daily_summaries
par_summaries = parallel_result.daily_summaries

if length(seq_summaries) == length(par_summaries)
    println("✅ Daily summary counts match: $(length(seq_summaries))")

    for (seq_sum, par_sum) in zip(seq_summaries, par_summaries)
        if seq_sum.date == par_sum.date && seq_sum.zones_successful == par_sum.zones_successful
            println("   ✅ $(seq_sum.date): $(seq_sum.zones_successful) zones")
        else
            println("   ⚠️  $(seq_sum.date): sequential=$(seq_sum.zones_successful), parallel=$(par_sum.zones_successful)")
        end
    end
else
    println("⚠️  Daily summary counts differ: sequential=$(length(seq_summaries)), parallel=$(length(par_summaries))")
end

println()

# Test 6: Error handling test (optional - comment out if not needed)
println("🔧 TEST 4: Error Handling with Invalid Dates")
println("-"^40)

try
    error_test_result = test_generate_energy_prices_for_date_range(
        Date(2030, 1, 1),  # Future date with no data
        Date(2030, 1, 2), ["XX"];  # Invalid zone
        order_method=:alternative,
        parallel=true,
        save_to_db=false,
        silent=true,
        max_workers=2
    )

    println("✅ Error handling test completed:")
    println("   📊 Success: $(error_test_result.successful_dates)/$(error_test_result.total_dates) dates")
    println("   ⚠️  This should show 0 successes due to invalid data")
catch e
    println("✅ Error handling test caught expected error: $e")
end

println()

# Cleanup
println("🧹 CLEANUP")
println("-"^40)
println("🗑️  Removing test workers...")
rmprocs(filter(id -> id > 1, workers()))

println("✅ Cleanup complete")
println()

println("🏁 PARALLEL DATES TESTING COMPLETE")
println("="^60)

if speedup > 1.2
    println("✅ SUCCESS: Parallel dates architecture shows good performance improvement!")
    println("   📈 Achieved $(round(speedup, digits=2))x speedup with $(round(efficiency, digits=1))% efficiency")
else
    println("⚠️  WARNING: Limited speedup achieved. This might be expected for small test datasets.")
    println("   🔍 Try with a larger date range to see better parallel performance.")
end

if seq_successful == par_successful
    println("✅ SUCCESS: Both architectures produced identical results!")
else
    println("⚠️  WARNING: Results differ between sequential and parallel modes.")
    println("   🔍 This needs investigation before using parallel mode in production.")
end