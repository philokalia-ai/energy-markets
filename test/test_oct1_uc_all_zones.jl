#!/usr/bin/env julia

"""
Test script: Energy Price Generation for October 1st, 2024
===========================================================

Configuration:
- Date: October 1st, 2024
- Order Method: UC-based 
- Model: MPCC
- Optimizer: HiGHS
- Database Save: Enabled
- Target: All available bidding zones

This script will:
1. Discover available bidding zones
2. Run energy price generation for each zone
3. Track success/failure rates
4. Save results to database
5. Provide comprehensive reporting
"""

using Pkg
Pkg.activate(".")

using Euphemia
using Dates
using Printf

# Configuration
const TEST_DATE = Date(2024, 10, 1)
const ORDER_METHOD = :uc_based
const MODEL = :mpcc
const OPTIMIZER = "highs"
const SAVE_TO_DB = true
const MAX_RETRIES = 2
const RETRY_DELAY = 1.0

function print_header()
    println("🚀 ENERGY PRICE GENERATION TEST")
    println("="^50)
    println("📅 Date: $(TEST_DATE)")
    println("📋 Order Method: $(ORDER_METHOD)")
    println("⚖️  Model: $(MODEL)")
    println("🔧 Optimizer: $(OPTIMIZER)")
    println("💾 Database Save: $(SAVE_TO_DB)")
    println("🔄 Max Retries: $(MAX_RETRIES)")
    println("="^50)
    println()
end

function check_existing_zones(target_date::Date, order_method::Symbol)
    """Check which zones already have data for the target date and method"""
    try
        sql = """
            SELECT DISTINCT bidding_zone 
            FROM simulations.energy_prices 
            WHERE DATE(date_time_utc) = \$1 
            AND order_method = \$2
        """

        result = Euphemia.sql2df_with_retry(sql, [target_date, string(order_method)])
        existing_zones = Set(result.bidding_zone)

        if !isempty(existing_zones)
            println("📊 Found existing data for $(length(existing_zones)) zones:")
            for zone in sort(collect(existing_zones))
                println("   ✅ $zone")
            end
            println()
        end

        return existing_zones
    catch e
        @warn "Failed to check existing zones: $e"
        println("⚠️  Could not check existing zones - will process all zones")
        return Set{String}()
    end
end

function get_available_zones()
    println("🔍 Discovering available bidding zones...")

    # Use the function from the Euphemia package
    try
        zones = Euphemia.get_available_zones(TEST_DATE)
        println("✅ Found $(length(zones)) zones from ENTSO-E database:")
        for (i, zone) in enumerate(zones)
            println("   $(@sprintf("%2d", i)). $zone")
        end
        println()
        return zones
    catch e
        println("❌ Error discovering zones: $e")
        # Return empty array to trigger fallback in main function
        return String[]
    end
end

function test_zone_with_retry(zone::String, max_retries::Int=MAX_RETRIES)
    for attempt in 1:max_retries
        try
            start_time = time()

            # Add attempt info for retries
            retry_msg = attempt > 1 ? " (retry $attempt/$max_retries)" : ""
            println("🔄 Processing: $zone$retry_msg")

            prices = generate_energy_prices(zone, TEST_DATE;
                order_method=ORDER_METHOD,
                model=MODEL,
                optimizer=OPTIMIZER,
                save_to_db=SAVE_TO_DB,
                silent=true)

            elapsed = round(time() - start_time, digits=2)

            if length(prices) > 0
                min_price = round(minimum(values(prices)), digits=2)
                max_price = round(maximum(values(prices)), digits=2)
                avg_price = round(sum(values(prices)) / length(prices), digits=2)

                println("✅ SUCCESS: $zone ($(elapsed)s)")
                println("   💰 $(length(prices)) periods: €$min_price - €$max_price/MWh (avg: €$avg_price)")

                return (success=true, error=nothing, elapsed=elapsed, periods=length(prices),
                    min_price=min_price, max_price=max_price, avg_price=avg_price)
            else
                println("⚠️  WARNING: $zone - No prices generated")
                return (success=false, error="No prices generated", elapsed=elapsed, periods=0,
                    min_price=0.0, max_price=0.0, avg_price=0.0)
            end

        catch e
            elapsed = round(time() - start_time, digits=2)
            error_msg = string(e)

            if attempt < max_retries
                println("❌ ATTEMPT $attempt FAILED: $zone ($(elapsed)s)")
                println("   📝 Error: $(first(split(error_msg, '\n')))")
                println("   🔄 Retrying in $(RETRY_DELAY)s...")
                sleep(RETRY_DELAY)
            else
                println("❌ FINAL FAILURE: $zone ($(elapsed)s after $max_retries attempts)")
                println("   📝 Error: $(first(split(error_msg, '\n')))")
                return (success=false, error=error_msg, elapsed=elapsed, periods=0,
                    min_price=0.0, max_price=0.0, avg_price=0.0)
            end
        end
    end
end

function run_all_zones(zones::Vector{String})
    results = []
    success_count = 0
    failure_count = 0
    total_time = 0.0

    println("📊 Starting batch processing for $(length(zones)) zones...")
    println("-"^60)

    for (i, zone) in enumerate(zones)
        println("\n🏃 [$i/$(length(zones))] Zone: $zone")
        println("-"^40)

        zone_start = time()
        result = test_zone_with_retry(zone)
        zone_elapsed = time() - zone_start

        # Add zone info to result
        result_with_zone = merge(result, (zone=zone, total_time=zone_elapsed))
        push!(results, result_with_zone)

        if result.success
            success_count += 1
        else
            failure_count += 1
        end

        total_time += zone_elapsed

        # Progress update
        remaining = length(zones) - i
        est_remaining = remaining > 0 ? round(total_time / i * remaining / 60, digits=1) : 0
        println("   📈 Progress: $i/$(length(zones)) | Est. remaining: $(est_remaining) min")
    end

    return results, success_count, failure_count, total_time
end

function print_summary(results, success_count, failure_count, total_time)
    println("\n" * "="^60)
    println("🏁 BATCH PROCESSING COMPLETE")
    println("="^60)

    total_zones = success_count + failure_count
    success_rate = total_zones > 0 ? round(100 * success_count / total_zones, digits=1) : 0

    println("📊 Overall Statistics:")
    println("   ✅ Successful zones: $success_count")
    println("   ❌ Failed zones: $failure_count")
    println("   📈 Success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/60, digits=1)) minutes")
    println("   🕒 Average per zone: $(round(total_time/total_zones, digits=1)) seconds")

    if success_count > 0
        successful_results = filter(r -> r.success, results)
        total_periods = sum(r.periods for r in successful_results)
        avg_solve_time = round(sum(r.elapsed for r in successful_results) / success_count, digits=2)

        prices = [r.avg_price for r in successful_results if r.avg_price > 0]
        if length(prices) > 0
            overall_min = round(minimum([r.min_price for r in successful_results if r.min_price > 0]), digits=2)
            overall_max = round(maximum([r.max_price for r in successful_results if r.max_price > 0]), digits=2)
            overall_avg = round(sum(prices) / length(prices), digits=2)

            println("\n💰 Price Statistics (successful zones):")
            println("   📊 Total periods generated: $total_periods")
            println("   ⏱️  Average solve time: $(avg_solve_time)s")
            println("   💵 Price range: €$overall_min - €$overall_max/MWh")
            println("   📈 Average price: €$overall_avg/MWh")
        end
    end

    if failure_count > 0
        println("\n❌ Failed Zones:")
        failed_results = filter(r -> !r.success, results)
        for result in failed_results
            error_preview = length(result.error) > 50 ? result.error[1:50] * "..." : result.error
            println("   - $(result.zone): $error_preview")
        end
    end
end

function check_database_results()
    println("\n🗄️  Database Verification:")
    println("-"^30)

    try
        # Check optimization runs for our test date
        runs = Euphemia.sql2df("
            SELECT 
                status,
                COUNT(*) as count,
                ROUND(AVG(solve_time_seconds)::numeric, 2) as avg_time
            FROM simulations.optimization_runs 
            WHERE optimization_date = '$TEST_DATE' 
            AND order_method = '$ORDER_METHOD'
            GROUP BY status
            ORDER BY count DESC
        ")

        if nrow(runs) > 0
            println("📊 Optimization runs summary:")
            display(runs)
        else
            println("⚠️  No optimization runs found for $TEST_DATE")
        end

        # Check energy prices
        prices_count = Euphemia.sql2df("
            SELECT COUNT(*) as total_price_records
            FROM simulations.energy_prices 
            WHERE DATE(date_time_utc) = '$TEST_DATE'
        ")

        if nrow(prices_count) > 0 && prices_count[1, :total_price_records] > 0
            println("\n💰 Energy prices: $(prices_count[1, :total_price_records]) records saved")
        else
            println("\n⚠️  No energy prices found for $TEST_DATE")
        end

    catch e
        println("❌ Database verification failed: $e")
    end
end

# Main execution
function main()
    print_header()

    # Discover zones
    zones = get_available_zones()
    if isempty(zones)
        println("❌ No bidding zones available. Exiting.")
        return
    end

    # Check existing zones
    println("🔍 Checking for existing results...")
    existing_zones = check_existing_zones(TEST_DATE, ORDER_METHOD)

    # Filter out zones that already exist
    zones_to_process = filter(zone -> zone ∉ existing_zones, zones)

    if isempty(zones_to_process)
        println("✅ All zones already processed!")
        println("📊 Total zones: $(length(zones))")
        println("🎯 Already completed: $(length(existing_zones))")
        println("🆕 Remaining: 0")

        # Still show database verification
        if SAVE_TO_DB
            check_database_results()
        end
        return
    end

    println("📊 Processing plan:")
    println("   🎯 Total zones: $(length(zones))")
    println("   ✅ Already completed: $(length(existing_zones))")
    println("   🆕 To process: $(length(zones_to_process))")
    println("   📋 Zones to process: $(join(zones_to_process, ", "))")
    println()

    # Run tests
    println("🚀 Starting comprehensive test run...")
    test_start = time()

    results, success_count, failure_count, total_time = run_all_zones(zones_to_process)

    # Print summary
    print_summary(results, success_count, failure_count, total_time)

    # Database verification
    if SAVE_TO_DB
        check_database_results()
    end

    println("\n✅ Test run completed in $(round((time() - test_start)/60, digits=1)) minutes")
end

# Execute if run directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end