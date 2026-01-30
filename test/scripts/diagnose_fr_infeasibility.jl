#!/usr/bin/env julia
# Diagnostic script for FR Unit Commitment Infeasibility
# Run with: julia --project=. test/scripts/diagnose_fr_infeasibility.jl
#
# Historical note (2026-01-30): This script was created to diagnose infeasibility
# in the FR zone on 2025-12-10. The root causes were identified as:
# 1. Data quality issues - initial outputs outside valid [p_min, p_max] range
# 2. Inappropriate min_load_factor being applied to flexible resources (BESS)
# 3. Startup profile constraints not being applied for early periods
#
# Fixes were implemented in:
# - src/Generators.jl: Clamp initial outputs to valid range
# - src/UnitCommitment.jl: Don't apply min_load_factor to flexible resources
# - src/UnitCommitment.jl: Apply u_SU constraints for all periods
# - src/FuelTypeParameters.jl: Make "Other" fuel type more flexible

using Euphemia
using Dates, DataFrames, Printf
using Statistics

# Configuration
const ZONE = "FR"
const DATE = Date(2025, 12, 10)

println("=" ^ 70)
println("FR UNIT COMMITMENT INFEASIBILITY DIAGNOSIS")
println("Zone: $ZONE, Date: $DATE")
println("=" ^ 70)

# =============================================================================
# 1. Load generators with inferred parameters
# =============================================================================
println("\n[1] Loading generators...")
generators = get_generators_with_inferred_params(ZONE, DATE)
println("   Total generators: $(length(generators))")
println("   Total P_max: $(round(sum(g.p_max for g in generators), digits=0)) MW")
println("   Total P_min: $(round(sum(g.p_min for g in generators), digits=0)) MW")

# Breakdown by fuel type
println("\n   Generators by fuel type:")
fuel_counts = Dict{Symbol, Tuple{Int, Float64, Float64}}()  # (count, p_max, p_min)
for g in generators
    if haskey(fuel_counts, g.fuel_type)
        (count, pmax, pmin) = fuel_counts[g.fuel_type]
        fuel_counts[g.fuel_type] = (count + 1, pmax + g.p_max, pmin + g.p_min)
    else
        fuel_counts[g.fuel_type] = (1, g.p_max, g.p_min)
    end
end
for (fuel, (count, pmax, pmin)) in sort(collect(fuel_counts), by=x->x[2][2], rev=true)
    println("      $fuel: $count units, $(round(pmax, digits=0)) MW P_max, $(round(pmin, digits=0)) MW P_min")
end

# =============================================================================
# 2. Load initial conditions
# =============================================================================
println("\n[2] Loading initial conditions...")
initial_conditions = get_initial_conditions(generators, DATE; use_historical=true)

# =============================================================================
# 3. Analyze capacity by ON/OFF status
# =============================================================================
on_generators = [(g, initial_conditions[g.code]) for g in generators if initial_conditions[g.code].is_on]
off_generators = [(g, initial_conditions[g.code]) for g in generators if !initial_conditions[g.code].is_on]

on_capacity = sum(g.p_max for (g, _) in on_generators; init=0.0)
off_capacity = sum(g.p_max for (g, _) in off_generators; init=0.0)
on_p_min = sum(g.p_min for (g, _) in on_generators; init=0.0)

println("\n[3] Capacity by status:")
println("   ON capacity:  $(round(on_capacity, digits=0)) MW ($(length(on_generators)) units)")
println("   ON sum(P_min): $(round(on_p_min, digits=0)) MW")
println("   OFF capacity: $(round(off_capacity, digits=0)) MW ($(length(off_generators)) units)")

# =============================================================================
# 4. Analyze OFF generators by thermal state
# =============================================================================
println("\n[4] OFF generators by thermal state:")
for state in [:hot, :warm, :cold]
    units = [(g, ic) for (g, ic) in off_generators if ic.thermal_state == state]
    cap = isempty(units) ? 0.0 : sum(g.p_max for (g, _) in units)
    println("   $state: $(round(cap, digits=0)) MW ($(length(units)) units)")
end

# =============================================================================
# 5. Analyze OFF generators by startup time
# =============================================================================
println("\n[5] OFF generators by startup time:")
fast_start = Tuple{Generator, InitialConditions, Float64}[]  # < 4h
medium_start = Tuple{Generator, InitialConditions, Float64}[]  # 4-12h
slow_start = Tuple{Generator, InitialConditions, Float64}[]  # > 12h

for (g, ic) in off_generators
    params = get_fuel_type_parameters(g.fuel_type)
    # Use appropriate startup time based on thermal state
    startup_hours = if ic.thermal_state == :hot
        params.hot_startup_time
    elseif ic.thermal_state == :warm
        params.warm_startup_time
    else
        params.cold_startup_time
    end

    if startup_hours < 4
        push!(fast_start, (g, ic, Float64(startup_hours)))
    elseif startup_hours <= 12
        push!(medium_start, (g, ic, Float64(startup_hours)))
    else
        push!(slow_start, (g, ic, Float64(startup_hours)))
    end
end

fast_cap = sum(g.p_max for (g, _, _) in fast_start; init=0.0)
medium_cap = sum(g.p_max for (g, _, _) in medium_start; init=0.0)
slow_cap = sum(g.p_max for (g, _, _) in slow_start; init=0.0)

println("   Fast start (<4h):  $(round(fast_cap, digits=0)) MW ($(length(fast_start)) units)")
println("   Medium (4-12h):    $(round(medium_cap, digits=0)) MW ($(length(medium_start)) units)")
println("   Slow (>12h):       $(round(slow_cap, digits=0)) MW ($(length(slow_start)) units)")

# List fast-start generators
if !isempty(fast_start)
    println("\n   Fast-start generators (<4h):")
    for (g, ic, hours) in sort(fast_start, by=x->x[1].p_max, rev=true)[1:min(10, end)]
        println("      - $(g.name): $(round(g.p_max, digits=0)) MW, $(g.fuel_type), $(ic.thermal_state), $(hours)h startup")
    end
end

# =============================================================================
# 6. Load demand data
# =============================================================================
println("\n[6] Loading demand data...")
loads = get_loads(ZONE, DATE)
renewables = get_generation_forecast_for_wind_and_solar(ZONE, DATE)

# Disaggregate to finest resolution
target_slots, load_by_time, renewable_by_time, resolution = disaggregate_temporal_data(loads, renewables)

net_demand = [load_by_time[ts] - get(renewable_by_time, ts, 0.0) for ts in target_slots]
max_net_demand = maximum(net_demand)
min_net_demand = minimum(net_demand)
max_load = maximum(values(load_by_time))
max_renewable = maximum(values(renewable_by_time); init=0.0)

println("   Resolution: $(resolution) minutes")
println("   Max load: $(round(max_load, digits=0)) MW")
println("   Max renewable: $(round(max_renewable, digits=0)) MW")
println("   Max net demand: $(round(max_net_demand, digits=0)) MW")
println("   Min net demand: $(round(min_net_demand, digits=0)) MW")
println("   ON capacity - Max demand: $(round(on_capacity - max_net_demand, digits=0)) MW")

# =============================================================================
# 7. Find periods where ON capacity < demand
# =============================================================================
println("\n[7] Periods where ON capacity < net demand:")
deficit_periods = Tuple{Int, String, Float64, Float64}[]
for (t, ts) in enumerate(target_slots)
    nd = load_by_time[ts] - get(renewable_by_time, ts, 0.0)
    if nd > on_capacity
        push!(deficit_periods, (t, ts, nd, nd - on_capacity))
    end
end

if isempty(deficit_periods)
    println("   None! ON capacity covers all periods")
else
    println("   $(length(deficit_periods)) periods with deficit")
    for (t, ts, nd, deficit) in deficit_periods[1:min(10, end)]
        println("   Period $t ($ts): demand=$(round(nd, digits=0)) MW, deficit=$(round(deficit, digits=0)) MW")
    end
end

# =============================================================================
# 8. Identify generators locked by min_downtime
# =============================================================================
println("\n[8] Generators locked OFF by min_downtime at t=1:")

# Convert to periods based on resolution
periods_per_hour = 60 / resolution

locked_generators = Tuple{Generator, InitialConditions, Float64}[]
for (g, ic) in off_generators
    params = get_fuel_type_parameters(g.fuel_type)
    min_downtime_hours = g.min_downtime !== nothing ? g.min_downtime : params.min_downtime

    if ic.hours_off < min_downtime_hours
        remaining = min_downtime_hours - ic.hours_off
        push!(locked_generators, (g, ic, remaining))
    end
end

if isempty(locked_generators)
    println("   None - all OFF generators have completed min_downtime")
else
    locked_capacity = sum(g.p_max for (g, _, _) in locked_generators)
    println("   $(length(locked_generators)) generators locked, $(round(locked_capacity, digits=0)) MW")
    println("\n   Top locked generators:")
    for (g, ic, remaining) in sort(locked_generators, by=x->x[1].p_max, rev=true)[1:min(10, end)]
        println("      - $(g.name): $(round(g.p_max, digits=0)) MW, hours_off=$(ic.hours_off), need $(remaining) more hours")
    end
end

# =============================================================================
# 9. Identify generators locked ON by min_uptime
# =============================================================================
println("\n[9] Generators locked ON by min_uptime at t=1:")

locked_on_generators = Tuple{Generator, InitialConditions, Float64}[]
for (g, ic) in on_generators
    params = get_fuel_type_parameters(g.fuel_type)
    min_uptime_hours = g.min_uptime !== nothing ? g.min_uptime : params.min_uptime

    if ic.hours_on < min_uptime_hours
        remaining = min_uptime_hours - ic.hours_on
        push!(locked_on_generators, (g, ic, remaining))
    end
end

if isempty(locked_on_generators)
    println("   None - all ON generators have completed min_uptime")
else
    locked_on_capacity = sum(g.p_max for (g, _, _) in locked_on_generators)
    locked_on_p_min = sum(g.p_min for (g, _, _) in locked_on_generators)
    println("   $(length(locked_on_generators)) generators locked ON")
    println("   Locked ON P_max: $(round(locked_on_capacity, digits=0)) MW")
    println("   Locked ON P_min: $(round(locked_on_p_min, digits=0)) MW (must generate at least this much)")
    println("\n   Top locked ON generators:")
    for (g, ic, remaining) in sort(locked_on_generators, by=x->x[1].p_min, rev=true)[1:min(10, end)]
        println("      - $(g.name): P_min=$(round(g.p_min, digits=0)) MW, hours_on=$(ic.hours_on), need $(remaining) more hours")
    end
end

# =============================================================================
# 10. Critical Analysis: Can we meet demand?
# =============================================================================
println("\n[10] Critical Analysis - Can we meet demand?")

# Calculate maximum available capacity at each hour
periods_per_day = length(target_slots)
println("   Total periods: $periods_per_day")

# Simplified analysis: what capacity can come online by when?
println("\n   Capacity availability over 24 hours:")

for hour in [1, 4, 8, 12, 24]
    # ON generators can provide full capacity
    avail = on_capacity

    # Add OFF generators that can start in time
    for (g, ic, startup_hours) in fast_start
        if startup_hours <= hour
            avail += g.p_max
        end
    end
    for (g, ic, startup_hours) in medium_start
        if startup_hours <= hour
            avail += g.p_max
        end
    end
    for (g, ic, startup_hours) in slow_start
        if startup_hours <= hour
            avail += g.p_max
        end
    end

    # Consider min_downtime lock
    for (g, ic, remaining) in locked_generators
        params = get_fuel_type_parameters(g.fuel_type)
        startup_hours = if ic.thermal_state == :hot
            params.hot_startup_time
        elseif ic.thermal_state == :warm
            params.warm_startup_time
        else
            params.cold_startup_time
        end
        if remaining + startup_hours > hour
            avail -= g.p_max  # Still locked or can't start in time
        end
    end

    println("   Hour $hour: ~$(round(avail, digits=0)) MW available vs max demand $(round(max_net_demand, digits=0)) MW")
end

# =============================================================================
# 11. Potential minimum generation conflicts
# =============================================================================
println("\n[11] Potential minimum generation conflicts:")

# If sum of P_min of locked-ON generators > min net demand, we have oversupply
locked_on_p_min_total = sum(g.p_min for (g, _, _) in locked_on_generators; init=0.0)
println("   Sum of locked-ON P_min: $(round(locked_on_p_min_total, digits=0)) MW")
println("   Min net demand: $(round(min_net_demand, digits=0)) MW")

if locked_on_p_min_total > min_net_demand
    oversupply = locked_on_p_min_total - min_net_demand
    println("   WARNING: Locked-ON P_min EXCEEDS min demand by $(round(oversupply, digits=0)) MW!")
    println("   This may require curtailment or excess generation slack.")
else
    println("   OK: Locked-ON P_min < min demand")
end

# Also check total committed P_min vs min demand
total_on_p_min = sum(g.p_min for (g, _) in on_generators; init=0.0)
println("\n   Total ON P_min: $(round(total_on_p_min, digits=0)) MW")
if total_on_p_min > min_net_demand
    oversupply = total_on_p_min - min_net_demand
    println("   WARNING: Total ON P_min EXCEEDS min demand by $(round(oversupply, digits=0)) MW!")
end

# =============================================================================
# 12. Summary and Diagnosis
# =============================================================================
println("\n" * "=" ^ 70)
println("DIAGNOSIS SUMMARY")
println("=" ^ 70)

has_capacity_deficit = !isempty(deficit_periods)
has_locked_generators = !isempty(locked_generators)
has_min_gen_conflict = total_on_p_min > min_net_demand

println("\nKey Findings:")
println("   - Total capacity: $(round(on_capacity + off_capacity, digits=0)) MW")
println("   - ON capacity: $(round(on_capacity, digits=0)) MW")
println("   - Max net demand: $(round(max_net_demand, digits=0)) MW")
println("   - Capacity gap (need from OFF): $(round(max(0, max_net_demand - on_capacity), digits=0)) MW")
println("   - Fast-start available: $(round(fast_cap, digits=0)) MW")
println("   - Locked by min_downtime: $(round(sum(g.p_max for (g,_,_) in locked_generators; init=0.0), digits=0)) MW")

if has_capacity_deficit
    println("\n   ISSUE: Capacity deficit in $(length(deficit_periods)) periods")
    println("   ON capacity cannot meet net demand, need to start offline generators")
end

if has_locked_generators
    println("\n   ISSUE: $(length(locked_generators)) generators locked OFF by min_downtime")
    println("   These generators cannot start immediately even if needed")
end

if has_min_gen_conflict
    println("\n   ISSUE: Minimum generation conflict")
    println("   Sum of ON P_min ($total_on_p_min MW) > min demand ($min_net_demand MW)")
    println("   May require curtailment or excess generation slack variable")
end

if !has_capacity_deficit && !has_locked_generators && !has_min_gen_conflict
    println("\n   No obvious issues found - problem may be in startup sequence constraints")
    println("   Consider running UC with detailed constraint analysis")
end

println("\n" * "=" ^ 70)
println("DIAGNOSIS COMPLETE")
println("=" ^ 70)
