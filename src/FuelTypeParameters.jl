# Fuel-Type-Specific Generator Parameters for Unit Commitment
# 
# This file defines operational characteristics that vary significantly by fuel type
# Based on real-world power plant operations and engineering constraints

"""
    FuelTypeParameters

Struct containing fuel-type-specific operational parameters for unit commitment modeling.
"""
struct FuelTypeParameters
    # Startup characteristics
    cold_startup_time::Int          # Time periods for cold startup
    warm_startup_time::Int          # Time periods for warm startup  
    hot_startup_time::Int           # Time periods for hot startup
    
    # Minimum operating constraints
    min_uptime::Int                 # Minimum time periods unit must stay on
    min_downtime::Int               # Minimum time periods unit must stay off
    
    # Ramp rate constraints (as fraction of capacity per period)
    ramp_up_rate::Float64          # Maximum ramp up rate (fraction/period)
    ramp_down_rate::Float64        # Maximum ramp down rate (fraction/period)
    
    # Operating flexibility
    min_load_factor::Float64       # Minimum load as fraction of capacity
    part_load_efficiency::Float64  # Efficiency penalty at minimum load
    
    # Temperature transition thresholds (hours offline)
    warm_threshold::Int            # Hours offline before becoming warm
    cold_threshold::Int            # Hours offline before becoming cold
    
    # Economic parameters
    startup_cost_multiplier::Float64  # Multiplier for fuel-based startup costs
    no_load_cost_fraction::Float64    # No-load cost as fraction of marginal cost
end

"""
    get_fuel_type_parameters(fuel_type::Symbol) -> FuelTypeParameters

Returns fuel-type-specific operational parameters for unit commitment modeling.
"""
function get_fuel_type_parameters(fuel_type::Symbol)::FuelTypeParameters
    
    if fuel_type == Symbol("Fossil Gas")
        # Natural Gas Combined Cycle (NGCC) - Most flexible thermal technology
        return FuelTypeParameters(
            6,      # cold_startup_time: 6 hours for cold start
            4,      # warm_startup_time: 4 hours for warm start
            2,      # hot_startup_time: 2 hours for hot start
            4,      # min_uptime: 4 hours minimum run time
            2,      # min_downtime: 2 hours minimum off time
            0.25,   # ramp_up_rate: 25% per hour - very flexible
            0.25,   # ramp_down_rate: 25% per hour
            0.35,   # min_load_factor: Can operate down to 35% capacity
            0.90,   # part_load_efficiency: 90% efficiency at minimum load
            8,      # warm_threshold: Warm after 8 hours offline
            48,     # cold_threshold: Cold after 48 hours offline
            1.0,    # startup_cost_multiplier
            0.15    # no_load_cost_fraction
        )
        
    elseif fuel_type == Symbol("Fossil Brown coal/Lignite")
        # Lignite/Coal - Baseload technology, slow and inflexible
        return FuelTypeParameters(
            24,     # cold_startup_time: 24 hours for cold start - very slow
            12,     # warm_startup_time: 12 hours for warm start
            6,      # hot_startup_time: 6 hours for hot start
            24,     # min_uptime: 24 hours minimum run time - baseload
            8,      # min_downtime: 8 hours minimum off time
            0.05,   # ramp_up_rate: 5% per hour - very inflexible
            0.05,   # ramp_down_rate: 5% per hour
            0.50,   # min_load_factor: Cannot operate below 50% efficiently
            0.75,   # part_load_efficiency: 75% efficiency at minimum load
            12,     # warm_threshold: Warm after 12 hours offline
            72,     # cold_threshold: Cold after 72 hours offline
            2.5,    # startup_cost_multiplier: High startup costs
            0.25    # no_load_cost_fraction: High no-load costs
        )
        
    elseif fuel_type == Symbol("Hydro Water Reservoir")
        # Large Hydro - Very flexible but limited by water availability
        return FuelTypeParameters(
            1,      # cold_startup_time: Almost instant startup
            1,      # warm_startup_time: Almost instant startup
            1,      # hot_startup_time: Almost instant startup
            1,      # min_uptime: Very flexible
            1,      # min_downtime: Very flexible
            1.0,    # ramp_up_rate: Can ramp to full capacity instantly
            1.0,    # ramp_down_rate: Can ramp down instantly
            0.10,   # min_load_factor: Can operate at very low loads
            1.0,    # part_load_efficiency: No efficiency penalty
            1,      # warm_threshold: Always ready
            1,      # cold_threshold: Always ready
            0.0,    # startup_cost_multiplier: No fuel startup costs
            0.0     # no_load_cost_fraction: No fuel costs when not generating
        )
        
    elseif fuel_type == Symbol("Hydro Pumped Storage")
        # Pumped Storage - Extremely flexible, designed for cycling
        return FuelTypeParameters(
            1,      # cold_startup_time: Instant startup in generation mode
            1,      # warm_startup_time: Instant startup
            1,      # hot_startup_time: Instant startup
            1,      # min_uptime: Designed for frequent cycling
            1,      # min_downtime: Can cycle frequently
            1.0,    # ramp_up_rate: Full ramp capability
            1.0,    # ramp_down_rate: Full ramp capability
            0.20,   # min_load_factor: Can operate at low loads
            0.95,   # part_load_efficiency: Slight efficiency loss at part load
            1,      # warm_threshold: Always ready
            1,      # cold_threshold: Always ready
            0.0,    # startup_cost_multiplier: No fuel costs
            0.0     # no_load_cost_fraction: No fuel costs
        )
        
    elseif fuel_type == Symbol("Hydro Run-of-river and poundage")
        # Run-of-river Hydro - Flexible but flow-dependent
        return FuelTypeParameters(
            1,      # cold_startup_time: Quick startup
            1,      # warm_startup_time: Quick startup
            1,      # hot_startup_time: Quick startup
            2,      # min_uptime: Some operational constraints
            1,      # min_downtime: Flexible
            0.8,    # ramp_up_rate: Fast but not instant (mechanical limits)
            0.8,    # ramp_down_rate: Fast ramping
            0.15,   # min_load_factor: Can operate at low flows
            0.98,   # part_load_efficiency: Minimal efficiency loss
            1,      # warm_threshold: Always ready
            1,      # cold_threshold: Always ready
            0.0,    # startup_cost_multiplier: No fuel costs
            0.0     # no_load_cost_fraction: No fuel costs
        )
        
    else
        # Default parameters for unknown fuel types
        @warn "Unknown fuel type: $fuel_type. Using default parameters."
        return FuelTypeParameters(
            8,      # cold_startup_time
            4,      # warm_startup_time
            2,      # hot_startup_time
            6,      # min_uptime
            3,      # min_downtime
            0.15,   # ramp_up_rate
            0.15,   # ramp_down_rate
            0.40,   # min_load_factor
            0.85,   # part_load_efficiency
            12,     # warm_threshold
            48,     # cold_threshold
            1.5,    # startup_cost_multiplier
            0.20    # no_load_cost_fraction
        )
    end
end

"""
    apply_fuel_type_constraints!(model, generators, fuel_params_dict)

Apply fuel-type-specific constraints to the unit commitment model.
"""
function apply_fuel_type_constraints!(model, generators, N, T)
    # Create fuel-type parameter dictionary
    fuel_params = Dict{Int, FuelTypeParameters}()
    for (i, gen) in enumerate(generators)
        fuel_params[i] = get_fuel_type_parameters(gen.fuel_type)
    end
    
    println("\n=== Fuel-Type-Specific Constraints Applied ===")
    
    # Count generators by fuel type for reporting
    fuel_type_counts = Dict{Symbol, Int}()
    for gen in generators
        fuel_type_counts[gen.fuel_type] = get(fuel_type_counts, gen.fuel_type, 0) + 1
    end
    
    for (fuel_type, count) in fuel_type_counts
        params = get_fuel_type_parameters(fuel_type)
        println("$fuel_type ($count units):")
        println("  • Startup times: $(params.hot_startup_time)h (hot) / $(params.warm_startup_time)h (warm) / $(params.cold_startup_time)h (cold)")
        println("  • Min uptime: $(params.min_uptime)h, Min downtime: $(params.min_downtime)h")
        println("  • Ramp rates: $(round(params.ramp_up_rate*100, digits=1))% up / $(round(params.ramp_down_rate*100, digits=1))% down per hour")
        println("  • Min load: $(round(params.min_load_factor*100, digits=1))% of capacity")
    end
    
    return fuel_params
end

# Export the functions
export FuelTypeParameters, get_fuel_type_parameters, apply_fuel_type_constraints!
