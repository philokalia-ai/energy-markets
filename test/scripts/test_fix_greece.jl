#!/usr/bin/env julia

# Test script to verify the fix works - regenerate Greece prices with save_to_db=true

using Pkg
Pkg.activate(".")

using Dates
using Euphemia
using DataFrames
include("src/dbutils.jl")

println("=" ^ 70)
println("Testing Database Save Fix for Greece")
println("=" ^ 70)

# Test with 2025-12-16 which currently has only 71 prices
bidding_zone = "GR"
test_date = Date(2025, 12, 16)

println("\n📍 Bidding Zone: $bidding_zone")
println("📅 Date: $test_date")
println("💾 Save to DB: true")
println()

# Check current state in database
println("🔍 Checking current database state...")
check_query = """
SELECT COUNT(*) as count, MIN(date_time_utc) as first, MAX(date_time_utc) as last
FROM simulations.energy_prices
WHERE bidding_zone = 'GR'
  AND DATE(date_time_utc) = '2025-12-16'
  AND order_method = 'alternative'
"""

try
    before_df = sql2df_with_retry(check_query)
    if nrow(before_df) > 0 && before_df[1, :count] > 0
        println("   ⚠️  BEFORE: $(before_df[1, :count]) existing records")
        println("   First: $(before_df[1, :first])")
        println("   Last:  $(before_df[1, :last])")
    else
        println("   ℹ️  BEFORE: No existing records")
    end
catch e
    println("   Error checking database: $e")
end

println("\n" * "=" ^ 70)
println("Regenerating prices with save_to_db=true...")
println("=" ^ 70)

try
    # Generate prices with save_to_db=true
    result = Euphemia.run_independent_market_clearing(
        bidding_zone,
        test_date;
        order_method=:alternative,
        model=:mpcc,
        optimizer="highs",
        markup_factor=1.1,
        silent=true,  # Less verbose for this test
        save_to_db=true  # KEY: Save to database
    )

    println("\n✅ Price generation completed!")
    println("   Generated $(length(result)) price periods")

    # Wait a moment for database commit
    sleep(1)

    # Check database again
    println("\n🔍 Checking database after save...")
    after_df = sql2df_with_retry(check_query)

    if nrow(after_df) > 0 && after_df[1, :count] > 0
        count = after_df[1, :count]
        println("   ✅ AFTER: $count records in database")
        println("   First: $(after_df[1, :first])")
        println("   Last:  $(after_df[1, :last])")

        if count == 96
            println("\n" * "=" ^ 70)
            println("🎉 SUCCESS! Fix works correctly!")
            println("=" ^ 70)
            println("   ✅ All 96 periods saved to database")
            println("   ✅ Incomplete data was replaced")
        elseif count == 24
            println("\n✅ All 24 periods saved (60-minute resolution)")
        else
            println("\n⚠️  WARNING: Expected 96 or 24, got $count")
        end
    else
        println("   ❌ ERROR: No records found in database after save!")
    end

    # Also verify no gaps
    println("\n🔍 Checking for gaps in saved data...")
    gap_query = """
    SELECT date_time_utc
    FROM simulations.energy_prices
    WHERE bidding_zone = 'GR'
      AND DATE(date_time_utc) = '2025-12-16'
      AND order_method = 'alternative'
    ORDER BY date_time_utc
    """

    periods_df = sql2df_with_retry(gap_query)
    gaps_found = false

    if nrow(periods_df) > 1
        for i in 1:(nrow(periods_df)-1)
            t1 = periods_df[i, :date_time_utc]
            t2 = periods_df[i+1, :date_time_utc]
            diff = t2 - t1

            if diff > Minute(15)
                if !gaps_found
                    println("   ⚠️  GAPS DETECTED:")
                    gaps_found = true
                end
                println("      Between $(Dates.format(t1, "HH:MM")) and $(Dates.format(t2, "HH:MM"))")
            end
        end
    end

    if !gaps_found
        println("   ✅ No gaps detected - continuous time series")
    end

catch e
    println("\n" * "=" ^ 70)
    println("❌ Test failed with error:")
    println("=" ^ 70)
    println()
    showerror(stdout, e, catch_backtrace())
    println()
    exit(1)
end
