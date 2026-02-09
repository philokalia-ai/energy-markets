#!/usr/bin/env julia
# Sanity check for ATC data loading
using Euphemia, DataFrames, Dates

# 1. Are Day-ahead capacities constant within an hour?
println("=" ^ 80)
println("DAY-AHEAD: Are capacities constant within each hour?")
println("=" ^ 80)
da_variation = Euphemia.sql2df("""
    SELECT out_map_code, in_map_code,
           EXTRACT(HOUR FROM date_time_utc) as hour,
           COUNT(*) as records_per_hour,
           MIN(capacity_mw) as min_cap, MAX(capacity_mw) as max_cap,
           MAX(capacity_mw) - MIN(capacity_mw) as variation
    FROM entsoe.offered_transfer_capacities_implicit
    WHERE DATE(date_time_utc) = '2025-12-10'
    AND contract_type = 'Day-ahead'
    GROUP BY out_map_code, in_map_code, EXTRACT(HOUR FROM date_time_utc)
    HAVING MAX(capacity_mw) - MIN(capacity_mw) > 0.01
    LIMIT 10
""")
if nrow(da_variation) == 0
    println("  Day-ahead capacities are constant within each hour (good)")
else
    println("  WARNING: Day-ahead capacity varies within hour:")
    for row in eachrow(da_variation)
        println("  $(row.out_map_code)->$(row.in_map_code) h$(row.hour): $(row.min_cap)-$(row.max_cap) MW")
    end
end

# 2. Corridors: Day-ahead vs Intraday vs both
println("\n" * "=" ^ 80)
println("CORRIDORS: Day-ahead vs Intraday coverage")
println("=" ^ 80)
corridors = Euphemia.sql2df("""
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
    SELECT
        (SELECT COUNT(*) FROM da) as da_corridors,
        (SELECT COUNT(*) FROM id) as id_corridors,
        (SELECT COUNT(*) FROM da INNER JOIN id USING (corridor)) as both_corridors,
        (SELECT COUNT(*) FROM da LEFT JOIN id USING (corridor) WHERE id.corridor IS NULL) as da_only,
        (SELECT COUNT(*) FROM id LEFT JOIN da USING (corridor) WHERE da.corridor IS NULL) as id_only
""")
println("  Day-ahead corridors: $(corridors[1,:da_corridors])")
println("  Intraday corridors: $(corridors[1,:id_corridors])")
println("  Both: $(corridors[1,:both_corridors])")
println("  Day-ahead only: $(corridors[1,:da_only])")
println("  Intraday only: $(corridors[1,:id_only])")

# 3. What does our code ACTUALLY load? (compare with correct Day-ahead values)
println("\n" * "=" ^ 80)
println("IMPACT: What our code loads vs correct Day-ahead (sample corridors)")
println("=" ^ 80)

# Simulate what our code does (no contract_type filter, last-row-wins)
all_data = Euphemia.sql2df("""
    SELECT out_map_code as source_zone, in_map_code as sink_zone,
           EXTRACT(HOUR FROM date_time_utc) + 1 as time_period,
           capacity_mw as capacity
    FROM entsoe.offered_transfer_capacities_implicit
    WHERE DATE(date_time_utc) = '2025-12-10'
    ORDER BY out_map_code, in_map_code, date_time_utc
""")

# Last-row-wins simulation (matches our dict assignment behavior)
loaded = Dict{Tuple{String,String,Int},Float64}()
for row in eachrow(all_data)
    loaded[(row.source_zone, row.sink_zone, Int(row.time_period))] = row.capacity
end

# Correct Day-ahead values
da_data = Euphemia.sql2df("""
    SELECT out_map_code as source_zone, in_map_code as sink_zone,
           EXTRACT(HOUR FROM date_time_utc) + 1 as time_period,
           capacity_mw as capacity
    FROM entsoe.offered_transfer_capacities_implicit
    WHERE DATE(date_time_utc) = '2025-12-10'
    AND contract_type = 'Day-ahead'
    ORDER BY out_map_code, in_map_code, date_time_utc
""")
correct = Dict{Tuple{String,String,Int},Float64}()
for row in eachrow(da_data)
    correct[(row.source_zone, row.sink_zone, Int(row.time_period))] = row.capacity
end

# Compare
mismatches = 0
total_compared = 0
worst_corridors = Dict{String,Tuple{Float64,Float64,Float64}}()  # corridor => (max_diff, loaded, correct)
for (key, da_val) in correct
    global total_compared += 1
    loaded_val = get(loaded, key, NaN)
    diff = abs(loaded_val - da_val)
    if diff > 0.01
        global mismatches += 1
        corridor = "$(key[1])->$(key[2])"
        prev = get(worst_corridors, corridor, (0.0, 0.0, 0.0))
        if diff > prev[1]
            worst_corridors[corridor] = (diff, loaded_val, da_val)
        end
    end
end

println("  Total Day-ahead entries: $total_compared")
println("  Mismatches (loaded differs from Day-ahead): $mismatches")
if mismatches > 0
    pct = round(100*mismatches/total_compared, digits=1)
    println("  Mismatch rate: $pct%")
    println("\n  Worst corridors (max MW difference):")
    sorted = sort(collect(worst_corridors), by=x->x[2][1], rev=true)
    for (corr, (diff, loaded_v, correct_v)) in sorted[1:min(20, length(sorted))]
        println("    $corr: loaded=$(round(loaded_v, digits=1)) MW vs DA=$(round(correct_v, digits=1)) MW (off by $(round(diff, digits=1)) MW)")
    end
end

# 4. Corridors only in Intraday (loaded by our code but not Day-ahead)
println("\n" * "=" ^ 80)
println("EXTRA CORRIDORS: In loaded data but not in Day-ahead")
println("=" ^ 80)
loaded_corridors = Set(["$(k[1])->$(k[2])" for k in keys(loaded)])
da_corridors_set = Set(["$(k[1])->$(k[2])" for k in keys(correct)])
extra = setdiff(loaded_corridors, da_corridors_set)
missing_from_loaded = setdiff(da_corridors_set, loaded_corridors)
println("  Extra corridors (Intraday-only, loaded but not DA): $(length(extra))")
if length(extra) > 0
    for c in sort(collect(extra))
        println("    $c")
    end
end
println("  Missing corridors (DA exists but not loaded): $(length(missing_from_loaded))")
