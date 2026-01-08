#!/usr/bin/env julia

# Script to check database for records with missing price periods

using Pkg
Pkg.activate(".")

using Dates
using LibPQ
using DataFrames
include("src/dbutils.jl")

println("=" ^ 70)
println("Checking database for incomplete price records")
println("=" ^ 70)

try
    # Query to find records with fewer than expected prices
    query = """
    SELECT
        bidding_zone,
        DATE(date_time_utc) as date,
        COUNT(*) as price_count,
        MIN(date_time_utc) as first_period,
        MAX(date_time_utc) as last_period
    FROM simulations.energy_prices
    WHERE date_time_utc >= '2025-12-01'
    GROUP BY bidding_zone, DATE(date_time_utc)
    HAVING COUNT(*) < 96 AND COUNT(*) != 24
    ORDER BY date DESC, price_count ASC
    LIMIT 50;
    """

    println("\n🔍 Searching for records with unexpected price counts...")
    println("   (Expected: 96 for 15M or 24 for 60M resolution)\n")

    df = sql2df_with_retry(query)

    if nrow(df) == 0
        println("✅ No records found with missing prices!")
        println("   All recent records have correct number of price periods.")
    else
        println("⚠️  Found $(nrow(df)) records with missing prices:\n")
        println(df)

        # Get details for the first few problematic records
        println("\n" * "=" ^ 70)
        println("Detailed analysis of first few problematic records:")
        println("=" ^ 70)

        for i in 1:min(3, nrow(df))
            zone = df[i, :bidding_zone]
            date = df[i, :date]
            count = df[i, :price_count]

            println("\n📍 Zone: $zone, Date: $date ($(count) prices)")

            # Get the actual time periods for this record
            detail_query = """
            SELECT date_time_utc
            FROM simulations.energy_prices
            WHERE bidding_zone = '$zone'
              AND DATE(date_time_utc) = '$date'
            ORDER BY date_time_utc;
            """

            periods_df = sql2df_with_retry(detail_query)

            println("   First period: $(periods_df[1, :date_time_utc])")
            println("   Last period:  $(periods_df[end, :date_time_utc])")

            # Check for gaps
            if nrow(periods_df) > 1
                gaps = []
                for j in 1:(nrow(periods_df)-1)
                    t1 = periods_df[j, :date_time_utc]
                    t2 = periods_df[j+1, :date_time_utc]
                    diff = t2 - t1
                    if diff > Minute(15)
                        push!(gaps, (t1, t2, diff))
                    end
                end

                if length(gaps) > 0
                    println("   ⚠️  Found $(length(gaps)) gap(s):")
                    for (t1, t2, diff) in gaps[1:min(5, length(gaps))]
                        println("     - Between $t1 and $t2 ($(diff))")
                    end
                else
                    println("   ℹ️  No gaps detected - appears to be truncated at start/end")
                end
            end
        end
    end

    # Also check the most recent dates for Greece specifically
    println("\n" * "=" ^ 70)
    println("Recent Greece (GR) records:")
    println("=" ^ 70)

    gr_query = """
    SELECT
        DATE(date_time_utc) as date,
        COUNT(*) as price_count,
        MIN(date_time_utc) as first_period,
        MAX(date_time_utc) as last_period
    FROM simulations.energy_prices
    WHERE bidding_zone = 'GR'
      AND date_time_utc >= '2025-12-01'
    GROUP BY DATE(date_time_utc)
    ORDER BY date DESC
    LIMIT 20;
    """

    gr_df = sql2df_with_retry(gr_query)
    println(gr_df)

catch e
    println("\n❌ Error querying database:")
    showerror(stdout, e, catch_backtrace())
    println()
    exit(1)
end
