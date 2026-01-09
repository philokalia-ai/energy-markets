#!/usr/bin/env julia

# Quick verification script to check database state after fix

using Pkg
Pkg.activate(".")

using DataFrames
include("src/dbutils.jl")

println("=" ^ 70)
println("Verifying Database State After Fix")
println("=" ^ 70)

# Check Greece for recent dates
gr_query = """
SELECT
    DATE(date_time_utc) as date,
    COUNT(*) as price_count,
    MIN(date_time_utc) as first_period,
    MAX(date_time_utc) as last_period
FROM simulations.energy_prices
WHERE bidding_zone = 'GR'
  AND date_time_utc >= '2025-12-10'
  AND order_method = 'alternative'
GROUP BY DATE(date_time_utc)
ORDER BY date DESC
LIMIT 10;
"""

println("\n📊 Recent Greece (GR) records (alternative method):\n")
gr_df = sql2df_with_retry(gr_query)
println(gr_df)

# Count how many have full 96 prices
full_count = count(row -> row.price_count == 96, eachrow(gr_df))
incomplete_count = count(row -> row.price_count < 96 && row.price_count != 24, eachrow(gr_df))

println("\n📈 Summary:")
println("   ✅ Complete (96 prices): $full_count")
if incomplete_count > 0
    println("   ⚠️  Incomplete: $incomplete_count")
else
    println("   ✅ No incomplete records")
end
