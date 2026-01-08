using Euphemia
using Dates

# Include the fuel type parameters
include("../src/FuelTypeParameters.jl")

# Test date
test_date = Date("2025-06-24")

println("=== Exploring Generator Fuel Types ===")
println("Date: $test_date")

# Get generators from database (this uses the actual ENTSO-E data)
generators = get_generators("GR", test_date)  # Use GR as default for this exploration

println("\nTotal generators: $(length(generators))")

# Extract unique fuel types
fuel_types = unique([gen.fuel_type for gen in generators])
println("\nUnique fuel types found:")
for (i, fuel_type) in enumerate(sort(fuel_types))
    count = sum(gen.fuel_type == fuel_type for gen in generators)
    total_capacity = sum(gen.p_max for gen in generators if gen.fuel_type == fuel_type)
    println("  $i. $fuel_type: $count units, $(round(total_capacity, digits=1)) MW total capacity")
end

# Show detailed breakdown
println("\n=== Detailed Generator Breakdown ===")
for fuel_type in sort(fuel_types)
    println("\n$fuel_type generators:")
    fuel_generators = filter(gen -> gen.fuel_type == fuel_type, generators)

    # Sort by capacity (descending)
    sort!(fuel_generators, by=gen -> gen.p_max, rev=true)

    for (i, gen) in enumerate(fuel_generators[1:min(5, end)])  # Show top 5
        println("  $(gen.name): $(gen.p_max) MW (min: $(gen.p_min) MW)")
    end

    if length(fuel_generators) > 5
        println("  ... and $(length(fuel_generators) - 5) more generators")
    end
end

println("\n=== Capacity Summary by Fuel Type ===")
total_capacity = sum(gen.p_max for gen in generators)
for fuel_type in sort(fuel_types)
    fuel_capacity = sum(gen.p_max for gen in generators if gen.fuel_type == fuel_type)
    percentage = round(fuel_capacity / total_capacity * 100, digits=1)
    println("  $fuel_type: $(round(fuel_capacity, digits=1)) MW ($percentage%)")
end

println("\nTotal system capacity: $(round(total_capacity, digits=1)) MW")

println("\n" * "="^80)
println("=== Fuel-Type-Specific Operational Constraints ===")
println("="^80)

# Show how different fuel types should be constrained differently
for fuel_type in sort(fuel_types)
    params = get_fuel_type_parameters(fuel_type)
    fuel_generators = filter(gen -> gen.fuel_type == fuel_type, generators)
    fuel_capacity = sum(gen.p_max for gen in fuel_generators)

    println("\n🏭 $fuel_type ($(length(fuel_generators)) units, $(round(fuel_capacity, digits=1)) MW)")
    println("   Operational Characteristics:")
    println("     • Startup Times: $(params.hot_startup_time)h (hot) → $(params.warm_startup_time)h (warm) → $(params.cold_startup_time)h (cold)")
    println("     • Min Runtime: $(params.min_uptime)h continuous operation required")
    println("     • Min Downtime: $(params.min_downtime)h offline before restart")
    println("     • Ramping: $(round(params.ramp_up_rate*100, digits=1))% capacity/hour up, $(round(params.ramp_down_rate*100, digits=1))% capacity/hour down")
    println("     • Operating Range: $(round(params.min_load_factor*100, digits=1))% - 100% of rated capacity")
    println("     • Flexibility Rating: $(params.ramp_up_rate >= 0.5 ? "Very High" : params.ramp_up_rate >= 0.2 ? "High" : params.ramp_up_rate >= 0.1 ? "Medium" : "Low")")

    # Show economic implications
    if params.startup_cost_multiplier > 1.5
        println("     • Economic: High startup costs - suited for baseload operation")
    elseif params.startup_cost_multiplier < 0.5
        println("     • Economic: Low/no startup costs - ideal for cycling and reserves")
    else
        println("     • Economic: Moderate startup costs - suitable for intermediate operation")
    end
end

println("\n" * "="^80)
println("=== Unit Commitment Model Implications ===")
println("="^80)

println("\nCurrent Model Issues:")
println("❌ All generators use same startup times (1 period)")
println("❌ All generators use same min uptime/downtime (2/4 periods)")
println("❌ All generators use same ramp rates (30% capacity/hour)")
println("❌ No fuel-type-specific operational constraints")

println("\nRequired Model Enhancements:")
println("✅ Fuel-type-specific startup times and costs")
println("✅ Different minimum uptime/downtime by technology")
println("✅ Technology-appropriate ramp rate limits")
println("✅ Minimum load constraints varying by fuel type")
println("✅ Part-load efficiency considerations")
println("✅ Temperature-dependent startup characteristics")

println("\nOperational Dispatch Priority (Economic Merit Order):")
dispatch_order = [
    ("Hydro (all types)", "€0-5/MWh", "No fuel costs, highest priority"),
    ("Lignite/Coal", "€30-50/MWh", "Baseload, slow response"),
    ("Natural Gas CCGT", "€50-80/MWh", "Load following, flexible"),
    ("Natural Gas Peaking", "€80-150/MWh", "Peak demand, very flexible")
]

for (i, (tech, cost, role)) in enumerate(dispatch_order)
    println("  $i. $tech: $cost - $role")
end
