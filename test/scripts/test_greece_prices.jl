#!/usr/bin/env julia

# Test script to investigate missing price periods for Greece

using Pkg
Pkg.activate(".")

using Dates
using Euphemia

println("=" ^ 70)
println("Testing run_independent_market_clearing() for Greece")
println("=" ^ 70)

# Test parameters
bidding_zone = "GR"
test_date = Date(2025, 12, 16)

println("\n📍 Bidding Zone: $bidding_zone")
println("📅 Date: $test_date")
println("📋 Order Method: :alternative")
println("⚖️  Model: :mpcc")
println("🔧 Optimizer: highs")
println()

try
    # Call the function
    result = Euphemia.run_independent_market_clearing(
        bidding_zone,
        test_date;
        order_method=:alternative,
        model=:mpcc,
        optimizer="highs",
        markup_factor=1.1,
        silent=false,  # Show solver output
        save_to_db=false  # Don't save during test
    )

    println("\n" * "=" ^ 70)
    println("✅ Test completed successfully!")
    println("=" ^ 70)

    # The result IS the prices dictionary directly
    prices = result

    println("\n📊 Price Analysis:")
    println("  - Number of price periods: $(length(prices))")
    println("  - Expected for 15M resolution: 96 periods")
    println("  - Expected for 60M resolution: 24 periods")

    if length(prices) < 96 && length(prices) != 24
        println("\n⚠️  WARNING: Unexpected number of price periods!")
        println("  - Got: $(length(prices)) periods")
        println("  - Expected: 96 (15M) or 24 (60M)")
        println("\n🔍 MISSING PERIODS DETECTED!")
    elseif length(prices) == 96
        println("\n✅ Correct number of periods for 15-minute resolution")
    elseif length(prices) == 24
        println("\n✅ Correct number of periods for 60-minute resolution")
    end

    # Parse datetime strings and sort
    parsed_times = []
    for (time_str, price) in prices
        # Parse the datetime string (format: YYYYMMDD-HHMM)
        dt = DateTime(test_date) + Hour(parse(Int, time_str[10:11])) + Minute(parse(Int, time_str[12:13]))
        push!(parsed_times, (dt, price))
    end
    sort!(parsed_times, by=x->x[1])

    # Show first and last few prices
    println("\n💰 Price Details (sorted by time):")
    println("  - First 5 periods:")
    for i in 1:min(5, length(parsed_times))
        dt, price = parsed_times[i]
        println("    $(i). $(Dates.format(dt, "yyyy-mm-dd HH:MM")) => €$(round(price, digits=2))/MWh")
    end

    if length(parsed_times) > 5
        println("  - Last 5 periods:")
        for i in (length(parsed_times)-4):length(parsed_times)
            dt, price = parsed_times[i]
            println("    $(i). $(Dates.format(dt, "yyyy-mm-dd HH:MM")) => €$(round(price, digits=2))/MWh")
        end
    end

    # Check for gaps in time series
    println("\n🔍 Checking for gaps in time series...")
    gaps_found = false
    if length(parsed_times) > 1
        for i in 1:(length(parsed_times)-1)
            dt1, _ = parsed_times[i]
            dt2, _ = parsed_times[i+1]
            expected_diff = Minute(15)  # Assuming 15-minute resolution
            actual_diff = dt2 - dt1

            if actual_diff != expected_diff
                if !gaps_found
                    println("  ⚠️  GAPS DETECTED:")
                    gaps_found = true
                end
                println("    Gap between $(Dates.format(dt1, "HH:MM")) and $(Dates.format(dt2, "HH:MM"))")
                println("    Expected: $(expected_diff), Actual: $(actual_diff)")
            end
        end
    end

    if !gaps_found
        println("  ✅ No gaps detected - continuous time series")
    end

    # Price statistics
    price_values = [p for (_, p) in parsed_times]
    println("\n📈 Price Statistics:")
    println("  - Min: €$(round(minimum(price_values), digits=2))/MWh")
    println("  - Max: €$(round(maximum(price_values), digits=2))/MWh")
    println("  - Avg: €$(round(sum(price_values)/length(price_values), digits=2))/MWh")

catch e
    println("\n" * "=" ^ 70)
    println("❌ Test failed with error:")
    println("=" ^ 70)
    println()
    showerror(stdout, e, catch_backtrace())
    println()
    exit(1)
end
