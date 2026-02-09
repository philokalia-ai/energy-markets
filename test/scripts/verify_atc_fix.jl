#!/usr/bin/env julia
# Verify ATC fix: native resolution, Day-ahead only, correct values
using Euphemia, DataFrames, Dates
using Euphemia: Network

date = Date(2025, 12, 10)

# 1. Load via our (now fixed) code
println("=" ^ 80)
println("Loading ATC via fixed create_transfer_capacity_from_entsoe()...")
println("=" ^ 80)
tc = Network.create_transfer_capacity_from_entsoe(date)

println("\n  Zones: $(length(tc.bidding_zones))")
println("  Periods: $(length(tc.time_periods))")
println("  Forward entries: $(length(tc.capacity_forward))")
println("  Backward entries: $(length(tc.capacity_backward))")
println("  Sample periods: $(tc.time_periods[1:min(4, length(tc.time_periods))])")

# 2. Verify period format is YYYYMMDD-HHMM (not hourly "1", "2", etc.)
println("\n" * "=" ^ 80)
println("Period format check")
println("=" ^ 80)
sample_period = first(tc.time_periods)
if contains(sample_period, "-") && length(sample_period) == 13
    println("  Format: YYYYMMDD-HHMM (correct, native resolution)")
else
    println("  WARNING: unexpected format: $sample_period")
end

# 3. Verify against raw Day-ahead SQL query
println("\n" * "=" ^ 80)
println("Verifying against raw Day-ahead SQL query...")
println("=" ^ 80)
correct = Euphemia.sql2df("""
    SELECT out_map_code as source, in_map_code as sink,
           to_char(date_time_utc AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MI') as period,
           capacity_mw as capacity
    FROM entsoe.offered_transfer_capacities_implicit
    WHERE DATE(date_time_utc) = '2025-12-10'
    AND contract_type = 'Day-ahead'
    ORDER BY out_map_code, in_map_code, date_time_utc
""")

mismatches = 0
for row in eachrow(correct)
    key = (row.source, row.sink, row.period)
    loaded_val = get(tc.capacity_forward, key, -999.0)
    if abs(loaded_val - row.capacity) > 0.01
        global mismatches += 1
        if mismatches <= 5
            println("  MISMATCH: $(row.source)->$(row.sink) $(row.period): loaded=$loaded_val vs correct=$(row.capacity)")
        end
    end
end
println("\nMismatches: $mismatches / $(nrow(correct))")
if mismatches == 0
    println("All values match correctly!")
end

# 4. Check no Intraday corridors leaked
println("\n" * "=" ^ 80)
println("Checking for Intraday-only corridors...")
println("=" ^ 80)
intraday_only = Euphemia.sql2df("""
    WITH da AS (
        SELECT DISTINCT out_map_code || '->' || in_map_code as corridor
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE DATE(date_time_utc) = '2025-12-10' AND contract_type = 'Day-ahead'
    ),
    id AS (
        SELECT DISTINCT out_map_code || '->' || in_map_code as corridor
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE DATE(date_time_utc) = '2025-12-10' AND contract_type = 'Intraday'
    )
    SELECT corridor FROM id LEFT JOIN da USING (corridor) WHERE da.corridor IS NULL
    ORDER BY corridor
""")
loaded_corridors = Set(["$(k[1])->$(k[2])" for k in keys(tc.capacity_forward)])
leaked = 0
for row in eachrow(intraday_only)
    if row.corridor in loaded_corridors
        global leaked += 1
        println("  LEAKED: $(row.corridor)")
    end
end
if leaked == 0
    println("No Intraday-only corridors leaked in (good)")
end

# 5. Show key corridor values at a 15-min period
println("\n" * "=" ^ 80)
println("Key corridor values (period 20251210-1200 = noon)")
println("=" ^ 80)
key_corridors = [
    ("FR", "ES"), ("ES", "FR"), ("FR", "IT"), ("IT", "FR"),
    ("GR", "BG"), ("BG", "GR"), ("PL", "PLC"), ("DK1", "DE_LU"),
    ("DE_LU", "NO2"), ("NO2", "DE_LU"), ("NL", "DK1"), ("FI", "EE"),
]
for (src, snk) in key_corridors
    fwd = get(tc.capacity_forward, (src, snk, "20251210-1200"), 0.0)
    bwd = get(tc.capacity_backward, (src, snk, "20251210-1200"), 0.0)
    println("  $src->$snk: forward=$(round(fwd, digits=1)) MW, backward=$(round(bwd, digits=1)) MW")
end

# 6. Resolution check
println("\n" * "=" ^ 80)
println("Resolution: $(length(tc.time_periods)) periods")
println("=" ^ 80)
if length(tc.time_periods) == 96
    println("  96 periods = 24h x 4 (PT15M) -- correct native resolution")
elseif length(tc.time_periods) == 24
    println("  24 periods = hourly -- WARNING: still aggregated")
else
    println("  $(length(tc.time_periods)) periods -- unexpected")
end
