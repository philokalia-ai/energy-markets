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
# - OPTIMIZER: Optimizer to use (highs; the only solver)
# - ORDER_METHOD: Order generation method (uc_based/alternative)
# - FORCE_RERUN: Force UC re-solve, bypassing cache (true/false)
# - MARKUP_FACTOR: Price markup factor for supply bids (default: 1.1)

using Euphemia, Dates

# Parse inputs
start_date = Date(ENV["START_DATE"])
end_date = Date(ENV["END_DATE"])
optimizer = ENV["OPTIMIZER"]
order_method = Symbol(ENV["ORDER_METHOD"])
force_rerun = parse(Bool, get(ENV, "FORCE_RERUN", "false"))
markup_factor = parse(Float64, get(ENV, "MARKUP_FACTOR", "1.1"))
# Comma-separated zone list; empty = auto-discover from transfer capacity
# data. Auto-discovery misses RS (no implicit-coupling borders, so it never
# appears in ATC data) and pulls in zones without validated order books, so
# production runs pin the zone set explicitly.
zones = [String(strip(z)) for z in split(get(ENV, "ZONES", ""), ",") if !isempty(strip(z))]

println("🌍 Starting multi-zone market clearing")
println("📅 Date range: $start_date to $end_date")
println("⚖️ Optimizer: $optimizer")
println("📋 Order method: $order_method")
println("🔄 Force rerun: $force_rerun")
println("💹 Markup factor: $markup_factor")
println()

try
    # Run multi-zone market clearing for date range
    result = run_multi_zone_for_date_range(
        start_date, end_date;
        zones=zones,
        order_method=order_method,
        optimizer=optimizer,
        save_to_db=true,
        skip_existing=true,
        force_rerun=force_rerun,
        markup_factor=markup_factor,
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

        # Under a run-local fill (fill → run → transfer) every date must clear: a failed date
        # would otherwise be dropped from the transfer while the job ends green.
        if Euphemia.DATA_STORE[] == :duckdb && Euphemia._in_fill()
            println("❌ Run-local fill: $failed_dates date(s) failed — failing the job")
            use_parallel && rmprocs(filter(id -> id > 1, workers()))
            exit(1)
        end
        # Still exit successfully if we got some results
        if successful_dates > 0
            println("✅ Continuing as $successful_dates dates were processed successfully")
            exit(0)
        else
            println("❌ All dates failed - marking as failure")
            exit(1)
        end
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

    exit(1)
end
