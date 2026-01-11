# Fuel-Type-Specific Generator Parameters for Unit Commitment
# 
# This file defines operational characteristics that vary significantly by fuel type
# Based on real-world power plant operations and engineering constraints

"""
    FuelTypeParameters

Struct containing fuel-type-specific operational parameters for unit commitment modeling.

IMPORTANT: All time-based parameters are in HOURS (not periods).
The UnitCommitment solver converts these to periods based on the actual
time resolution (15min, 30min, 60min) of the input data.
"""
struct FuelTypeParameters
    # Startup characteristics (all in HOURS)
    cold_startup_time::Int          # Hours required for cold startup
    warm_startup_time::Int          # Hours required for warm startup
    hot_startup_time::Int           # Hours required for hot startup

    # Minimum operating constraints (all in HOURS)
    min_uptime::Int                 # Minimum hours unit must stay on after startup
    min_downtime::Int               # Minimum hours unit must stay off after shutdown

    # Ramp rate constraints (as fraction of capacity per HOUR)
    ramp_up_rate::Float64          # Maximum ramp up rate (fraction/hour)
    ramp_down_rate::Float64        # Maximum ramp down rate (fraction/hour)

    # Operating flexibility
    min_load_factor::Float64       # Minimum load as fraction of capacity
    part_load_efficiency::Float64  # Efficiency penalty at minimum load

    # Temperature transition thresholds (in HOURS offline)
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

    elseif fuel_type == Symbol("Fossil Hard coal")
        # Hard Coal - Baseload technology, slow startup, less flexible than gas
        return FuelTypeParameters(
            12,     # cold_startup_time: 12 hours for cold start
            8,      # warm_startup_time: 8 hours for warm start
            4,      # hot_startup_time: 4 hours for hot start
            8,      # min_uptime: 8 hours minimum run time
            4,      # min_downtime: 4 hours minimum off time
            0.10,   # ramp_up_rate: 10% per hour - moderately inflexible
            0.10,   # ramp_down_rate: 10% per hour
            0.45,   # min_load_factor: Cannot operate below 45% efficiently
            0.80,   # part_load_efficiency: 80% efficiency at minimum load
            12,     # warm_threshold: Warm after 12 hours offline
            48,     # cold_threshold: Cold after 48 hours offline
            2.0,    # startup_cost_multiplier: High startup costs
            0.20    # no_load_cost_fraction: Moderate no-load costs
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
            0.45,   # min_load_factor: Cannot operate below 45% efficiently
            0.75,   # part_load_efficiency: 75% efficiency at minimum load
            12,     # warm_threshold: Warm after 12 hours offline
            72,     # cold_threshold: Cold after 72 hours offline
            2.5,    # startup_cost_multiplier: High startup costs
            0.25    # no_load_cost_fraction: High no-load costs
        )

    elseif fuel_type == Symbol("Fossil Peat")
        # Peat - Similar to lignite but less efficient, primarily used in Nordic countries
        return FuelTypeParameters(
            18,     # cold_startup_time: 18 hours for cold start
            10,     # warm_startup_time: 10 hours for warm start
            5,      # hot_startup_time: 5 hours for hot start
            12,     # min_uptime: 12 hours minimum run time
            6,      # min_downtime: 6 hours minimum off time
            0.06,   # ramp_up_rate: 6% per hour - very inflexible
            0.06,   # ramp_down_rate: 6% per hour
            0.55,   # min_load_factor: Cannot operate below 55% efficiently
            0.70,   # part_load_efficiency: 70% efficiency at minimum load
            12,     # warm_threshold: Warm after 12 hours offline
            72,     # cold_threshold: Cold after 72 hours offline
            2.2,    # startup_cost_multiplier: High startup costs
            0.30    # no_load_cost_fraction: High no-load costs
        )

    elseif fuel_type == Symbol("Fossil Coal-derived gas")
        # Coal-derived gas (syngas) - Similar to coal but slightly more flexible
        return FuelTypeParameters(
            10,     # cold_startup_time: 10 hours for cold start
            6,      # warm_startup_time: 6 hours for warm start
            3,      # hot_startup_time: 3 hours for hot start
            6,      # min_uptime: 6 hours minimum run time
            3,      # min_downtime: 3 hours minimum off time
            0.12,   # ramp_up_rate: 12% per hour - moderately flexible
            0.12,   # ramp_down_rate: 12% per hour
            0.40,   # min_load_factor: Can operate down to 40% capacity
            0.82,   # part_load_efficiency: 82% efficiency at minimum load
            10,     # warm_threshold: Warm after 10 hours offline
            36,     # cold_threshold: Cold after 36 hours offline
            1.8,    # startup_cost_multiplier: High startup costs
            0.18    # no_load_cost_fraction: Moderate no-load costs
        )

    elseif fuel_type == Symbol("Fossil Oil")
        # Oil-fired plants - Fast startup, expensive fuel, used for peaking
        return FuelTypeParameters(
            4,      # cold_startup_time: 4 hours for cold start
            2,      # warm_startup_time: 2 hours for warm start
            1,      # hot_startup_time: 1 hour for hot start
            2,      # min_uptime: 2 hours minimum run time
            1,      # min_downtime: 1 hour minimum off time
            0.30,   # ramp_up_rate: 30% per hour - quite flexible
            0.30,   # ramp_down_rate: 30% per hour
            0.30,   # min_load_factor: Can operate down to 30% capacity
            0.85,   # part_load_efficiency: 85% efficiency at minimum load
            6,      # warm_threshold: Warm after 6 hours offline
            24,     # cold_threshold: Cold after 24 hours offline
            1.2,    # startup_cost_multiplier: Moderate startup costs
            0.15    # no_load_cost_fraction: Moderate no-load costs
        )

    elseif fuel_type == Symbol("Fossil Oil shale")
        # Oil shale - Similar to coal but with different extraction costs
        return FuelTypeParameters(
            10,     # cold_startup_time: 10 hours for cold start
            6,      # warm_startup_time: 6 hours for warm start
            3,      # hot_startup_time: 3 hours for hot start
            6,      # min_uptime: 6 hours minimum run time
            3,      # min_downtime: 3 hours minimum off time
            0.12,   # ramp_up_rate: 12% per hour - similar to coal
            0.12,   # ramp_down_rate: 12% per hour
            0.45,   # min_load_factor: Cannot operate below 45% efficiently
            0.78,   # part_load_efficiency: 78% efficiency at minimum load
            10,     # warm_threshold: Warm after 10 hours offline
            36,     # cold_threshold: Cold after 36 hours offline
            2.2,    # startup_cost_multiplier: High startup costs
            0.22    # no_load_cost_fraction: High no-load costs
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
            0.0,    # min_load_factor: Can operate at any level (flexible resource)
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
            0.0,    # min_load_factor: Can operate at any level (flexible resource)
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
            0.0,    # min_load_factor: Can operate at any level (flexible resource)
            0.98,   # part_load_efficiency: Minimal efficiency loss
            1,      # warm_threshold: Always ready
            1,      # cold_threshold: Always ready
            0.0,    # startup_cost_multiplier: No fuel costs
            0.0     # no_load_cost_fraction: No fuel costs
        )

    elseif fuel_type == Symbol("Nuclear")
        # Nuclear - Baseload technology, very slow startup, inflexible
        return FuelTypeParameters(
            48,     # cold_startup_time: 48 hours for cold start - very slow
            24,     # warm_startup_time: 24 hours for warm start
            8,      # hot_startup_time: 8 hours for hot start
            24,     # min_uptime: 24 hours minimum run time - baseload
            12,     # min_downtime: 12 hours minimum off time
            0.05,   # ramp_up_rate: 5% per hour - very inflexible
            0.05,   # ramp_down_rate: 5% per hour
            0.60,   # min_load_factor: Cannot operate below 60% efficiently
            0.70,   # part_load_efficiency: 70% efficiency at minimum load
            24,     # warm_threshold: Warm after 24 hours offline
            96,     # cold_threshold: Cold after 96 hours offline
            5.0,    # startup_cost_multiplier: Very high startup costs
            0.30    # no_load_cost_fraction: High no-load costs
        )

    elseif fuel_type == Symbol("Solar")
        # Solar PV - No startup time, weather dependent, no fuel costs
        return FuelTypeParameters(
            1,      # cold_startup_time: Instant startup when sun available
            1,      # warm_startup_time: Instant startup
            1,      # hot_startup_time: Instant startup
            1,      # min_uptime: Very flexible
            1,      # min_downtime: Very flexible
            1.0,    # ramp_up_rate: Can ramp quickly (cloud dependent)
            1.0,    # ramp_down_rate: Can ramp quickly
            0.0,    # min_load_factor: Can operate at any level above 0
            1.0,    # part_load_efficiency: No efficiency penalty
            1,      # warm_threshold: Always ready when sun available
            1,      # cold_threshold: Always ready when sun available
            0.0,    # startup_cost_multiplier: No fuel startup costs
            0.0     # no_load_cost_fraction: No fuel costs
        )

    elseif fuel_type == Symbol("Wind Onshore")
        # Onshore Wind - No startup time, weather dependent, no fuel costs
        return FuelTypeParameters(
            1,      # cold_startup_time: Instant startup when wind available
            1,      # warm_startup_time: Instant startup
            1,      # hot_startup_time: Instant startup
            1,      # min_uptime: Very flexible
            1,      # min_downtime: Very flexible
            1.0,    # ramp_up_rate: Can ramp quickly (wind dependent)
            1.0,    # ramp_down_rate: Can ramp quickly
            0.0,    # min_load_factor: Can operate at any level above 0
            1.0,    # part_load_efficiency: No efficiency penalty
            1,      # warm_threshold: Always ready when wind available
            1,      # cold_threshold: Always ready when wind available
            0.0,    # startup_cost_multiplier: No fuel startup costs
            0.0     # no_load_cost_fraction: No fuel costs
        )

    elseif fuel_type == Symbol("Wind Offshore")
        # Offshore Wind - Similar to onshore but typically larger and more stable
        return FuelTypeParameters(
            1,      # cold_startup_time: Instant startup when wind available
            1,      # warm_startup_time: Instant startup
            1,      # hot_startup_time: Instant startup
            1,      # min_uptime: Very flexible
            1,      # min_downtime: Very flexible
            1.0,    # ramp_up_rate: Can ramp quickly (wind dependent)
            1.0,    # ramp_down_rate: Can ramp quickly
            0.0,    # min_load_factor: Can operate at any level above 0
            1.0,    # part_load_efficiency: No efficiency penalty
            1,      # warm_threshold: Always ready when wind available
            1,      # cold_threshold: Always ready when wind available
            0.0,    # startup_cost_multiplier: No fuel startup costs
            0.0     # no_load_cost_fraction: No fuel costs
        )

    elseif fuel_type == Symbol("Geothermal")
        # Geothermal - Baseload renewable, very stable, slow startup
        return FuelTypeParameters(
            8,      # cold_startup_time: 8 hours for cold start
            4,      # warm_startup_time: 4 hours for warm start
            2,      # hot_startup_time: 2 hours for hot start
            12,     # min_uptime: 12 hours minimum run time - baseload operation
            4,      # min_downtime: 4 hours minimum off time
            0.08,   # ramp_up_rate: 8% per hour - slow ramping
            0.08,   # ramp_down_rate: 8% per hour
            0.50,   # min_load_factor: Can operate down to 50% capacity
            0.90,   # part_load_efficiency: 90% efficiency at minimum load
            8,      # warm_threshold: Warm after 8 hours offline
            24,     # cold_threshold: Cold after 24 hours offline
            0.5,    # startup_cost_multiplier: Low startup costs
            0.10    # no_load_cost_fraction: Low no-load costs
        )

    elseif fuel_type == Symbol("Biomass")
        # Biomass - Similar to coal but renewable, moderate flexibility
        return FuelTypeParameters(
            6,      # cold_startup_time: 6 hours for cold start
            4,      # warm_startup_time: 4 hours for warm start
            2,      # hot_startup_time: 2 hours for hot start
            4,      # min_uptime: 4 hours minimum run time
            2,      # min_downtime: 2 hours minimum off time
            0.15,   # ramp_up_rate: 15% per hour - moderate flexibility
            0.15,   # ramp_down_rate: 15% per hour
            0.35,   # min_load_factor: Can operate down to 35% capacity
            0.85,   # part_load_efficiency: 85% efficiency at minimum load
            8,      # warm_threshold: Warm after 8 hours offline
            24,     # cold_threshold: Cold after 24 hours offline
            1.3,    # startup_cost_multiplier: Moderate startup costs
            0.16    # no_load_cost_fraction: Moderate no-load costs
        )

    elseif fuel_type == Symbol("Waste")
        # Waste-to-energy - Similar to biomass but typically smaller units
        return FuelTypeParameters(
            4,      # cold_startup_time: 4 hours for cold start
            3,      # warm_startup_time: 3 hours for warm start
            2,      # hot_startup_time: 2 hours for hot start
            3,      # min_uptime: 3 hours minimum run time
            2,      # min_downtime: 2 hours minimum off time
            0.20,   # ramp_up_rate: 20% per hour - more flexible than coal
            0.20,   # ramp_down_rate: 20% per hour
            0.40,   # min_load_factor: Can operate down to 40% capacity
            0.82,   # part_load_efficiency: 82% efficiency at minimum load
            6,      # warm_threshold: Warm after 6 hours offline
            18,     # cold_threshold: Cold after 18 hours offline
            1.1,    # startup_cost_multiplier: Low startup costs
            0.14    # no_load_cost_fraction: Low no-load costs
        )

    elseif fuel_type == Symbol("Energy storage")
        # Battery Energy Storage Systems (BESS) - Extremely flexible, fast response
        return FuelTypeParameters(
            1,      # cold_startup_time: 1 period for cold start - instant
            1,      # warm_startup_time: 1 period for warm start
            1,      # hot_startup_time: 1 period for hot start
            1,      # min_uptime: 1 period minimum run time
            1,      # min_downtime: 1 period minimum off time
            1.00,   # ramp_up_rate: 100% per period - instant ramp
            1.00,   # ramp_down_rate: 100% per period - instant ramp
            0.00,   # min_load_factor: Can operate at any level
            1.00,   # part_load_efficiency: 100% efficiency at all loads
            1,      # warm_threshold: Always warm
            1,      # cold_threshold: Never truly cold
            0.0,    # startup_cost_multiplier: No fuel-based startup costs
            0.00    # no_load_cost_fraction: No no-load costs
        )

    elseif fuel_type == Symbol("Other renewable")
        # Other renewable sources (e.g., tidal, wave) - Variable but clean
        return FuelTypeParameters(
            2,      # cold_startup_time: 2 periods for cold start
            1,      # warm_startup_time: 1 period for warm start
            1,      # hot_startup_time: 1 period for hot start
            1,      # min_uptime: 1 period minimum run time
            1,      # min_downtime: 1 period minimum off time
            0.80,   # ramp_up_rate: 80% per period - quite flexible
            0.80,   # ramp_down_rate: 80% per period
            0.00,   # min_load_factor: Can follow resource availability
            1.00,   # part_load_efficiency: 100% efficiency (no fuel)
            4,      # warm_threshold: Warm after 4 hours offline
            24,     # cold_threshold: Cold after 24 hours offline
            0.1,    # startup_cost_multiplier: Very low startup costs
            0.02    # no_load_cost_fraction: Minimal no-load costs
        )

    elseif fuel_type == Symbol("Other")
        # Other/unspecified technologies - Conservative default parameters
        @warn "Fuel type category listed as 'Other'. Using conservative default parameters."
        return FuelTypeParameters(
            8,      # cold_startup_time: 8 hours for cold start
            5,      # warm_startup_time: 5 hours for warm start
            2,      # hot_startup_time: 2 hours for hot start
            6,      # min_uptime: 6 hours minimum run time
            3,      # min_downtime: 3 hours minimum off time
            0.15,   # ramp_up_rate: 15% per hour - moderate flexibility
            0.15,   # ramp_down_rate: 15% per hour
            0.30,   # min_load_factor: 30% minimum load (aligned with P_MIN_BOUNDS default)
            0.85,   # part_load_efficiency: 85% efficiency at minimum load
            12,     # warm_threshold: Warm after 12 hours offline
            48,     # cold_threshold: Cold after 48 hours offline
            1.5,    # startup_cost_multiplier: Moderate startup costs
            0.20    # no_load_cost_fraction: Moderate no-load costs
        )

    else
        # Default parameters for unknown fuel types
        @warn "Unknown fuel type: $fuel_type. Using conservative default parameters."
        return FuelTypeParameters(
            8,      # cold_startup_time
            4,      # warm_startup_time
            2,      # hot_startup_time
            6,      # min_uptime
            3,      # min_downtime
            0.15,   # ramp_up_rate
            0.15,   # ramp_down_rate
            0.30,   # min_load_factor (aligned with P_MIN_BOUNDS default)
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
    fuel_params = Dict{Int,FuelTypeParameters}()
    for (i, gen) in enumerate(generators)
        fuel_params[i] = get_fuel_type_parameters(gen.fuel_type)
    end

    println("\n=== Fuel-Type-Specific Constraints Applied ===")

    # Count generators by fuel type for reporting
    fuel_type_counts = Dict{Symbol,Int}()
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
