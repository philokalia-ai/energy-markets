struct Generator
    code::String
    name::String
    fuel_type::Symbol
    location::String
    p_max::Float64
    p_min::Float64
    bidding_zone::String
    marginal_cost::Float64
    ramp_up::Union{Float64, Nothing}      # fraction of p_max per hour (nothing = use fuel-type default)
    ramp_down::Union{Float64, Nothing}    # fraction of p_max per hour (nothing = use fuel-type default)
    min_uptime::Union{Int, Nothing}       # minimum hours unit must stay on (nothing = use fuel-type default)
    min_downtime::Union{Int, Nothing}     # minimum hours unit must stay off (nothing = use fuel-type default)

    # Constructor with optional parameters defaulting to nothing
    function Generator(code, name, fuel_type, location, p_max, p_min, bidding_zone, marginal_cost,
                       ramp_up::Union{Float64, Nothing}=nothing,
                       ramp_down::Union{Float64, Nothing}=nothing,
                       min_uptime::Union{Int, Nothing}=nothing,
                       min_downtime::Union{Int, Nothing}=nothing)
        new(code, name, fuel_type, location, p_max, p_min, bidding_zone, marginal_cost,
            ramp_up, ramp_down, min_uptime, min_downtime)
    end
end

# Define your dummy values
const DUMMY_CODE = "GEN-0000"
const DUMMY_LOCATION = "Unknown Location"  # Placeholder for location
const DUMMY_FUEL_TYPE = :UNKNOWN # Or :THERMAL, :RENEWABLE, etc. based on context
const DUMMY_BIDDING_ZONE = "GR_DEFAULT"
const DUMMY_MARGINAL_COST = 999.9 # A clearly identifiable dummy value

# Minimum data points required for ramp rate inference
const MIN_DATA_POINTS_FOR_RAMP_INFERENCE = 100

# Flexible fuel types that can operate at 0 MW (no minimum generation constraint)
# These should NOT have p_min inferred from historical data
const FLEXIBLE_FUEL_TYPES = Set([
    Symbol("Hydro Pumped Storage"),
    Symbol("Hydro Run-of-river and pondage"),
    Symbol("Hydro Water Reservoir"),
    Symbol("Battery"),
    Symbol("Other"),
])

"""
    get_historical_generation(generator_code::String, end_date::Date; months_back::Int=3)

Fetch historical actual generation data for a specific generator.

Returns a DataFrame with columns: datetime_utc, resolution_code, actual_generation_mw
"""
function get_historical_generation(generator_code::String, end_date::Dates.Date; months_back::Int=3)
    start_date = end_date - Dates.Month(months_back)
    query = """
    SELECT date_time_utc, resolution_code, actual_generation_output_mw
    FROM entsoe.actual_generation_output_per_generation_unit
    WHERE generation_unit_code = \$1
      AND date_time_utc >= \$2
      AND date_time_utc < \$3
      AND actual_generation_output_mw IS NOT NULL
    ORDER BY date_time_utc
    """
    return Euphemia.sql2df_with_retry(query, [generator_code, start_date, end_date])
end

"""
    infer_ramp_rates(historical_data::DataFrame, p_max::Float64; percentile::Float64=0.95)

Infer ramp-up and ramp-down rates from historical generation data.

Returns a NamedTuple (ramp_up, ramp_down) with rates as fraction of p_max per hour.
Returns (nothing, nothing) if insufficient data.

Example: ramp_up = 0.20 means the generator can ramp up 20% of its capacity per hour.
"""
function infer_ramp_rates(historical_data::DataFrame, p_max::Float64; percentile::Float64=0.95)
    if nrow(historical_data) < MIN_DATA_POINTS_FOR_RAMP_INFERENCE
        return (ramp_up=nothing, ramp_down=nothing)
    end

    if p_max <= 0
        return (ramp_up=nothing, ramp_down=nothing)
    end

    # Sort by time and calculate deltas
    sort!(historical_data, :date_time_utc)
    gen_values = historical_data.actual_generation_output_mw
    deltas = diff(gen_values)

    # Separate ramp-up (positive) and ramp-down (negative)
    ramp_ups = filter(x -> x > 0, deltas)
    ramp_downs = map(abs, filter(x -> x < 0, deltas))

    # Normalize to hourly rate based on resolution
    resolution_code = historical_data.resolution_code[1]
    resolution_minutes = parse_resolution_to_minutes(resolution_code)
    hourly_factor = 60.0 / resolution_minutes

    # Calculate percentile (default 95th) and convert to fraction of p_max per hour
    ramp_up_rate = if isempty(ramp_ups)
        nothing
    else
        (Statistics.quantile(ramp_ups, percentile) * hourly_factor) / p_max
    end

    ramp_down_rate = if isempty(ramp_downs)
        nothing
    else
        (Statistics.quantile(ramp_downs, percentile) * hourly_factor) / p_max
    end

    return (ramp_up=ramp_up_rate, ramp_down=ramp_down_rate)
end

# Sanity check bounds for p_min by fuel type category (fraction of p_max)
# Lower bounds aligned with FuelTypeParameters.min_load_factor
# Format: fuel_type => (min_bound, max_bound)
const P_MIN_BOUNDS = Dict(
    :coal => (0.45, 0.65),      # Coal/Lignite: high minimum load (FuelTypeParams: 0.45-0.50)
    :gas_ccgt => (0.35, 0.55),  # Combined cycle gas: moderate minimum (FuelTypeParams: 0.35)
    :gas_ocgt => (0.20, 0.45),  # Open cycle gas turbine: more flexible
    :default => (0.30, 0.60),   # Default for unknown thermal
)

"""
Map fuel type symbol to p_min bounds category.
"""
function get_p_min_bounds_category(fuel_type::Symbol)::Symbol
    fuel_str = string(fuel_type)
    if occursin("Lignite", fuel_str) || occursin("coal", lowercase(fuel_str))
        return :coal
    elseif occursin("Gas", fuel_str)
        # Heuristic: larger gas plants tend to be CCGT
        return :gas_ccgt
    else
        return :default
    end
end

"""
    infer_p_min(historical_data::DataFrame, p_max::Float64, fuel_type::Symbol; percentile::Float64=0.05)

Infer minimum stable generation (p_min) from historical generation data.

Strategy:
1. Filter out zeros (plant off)
2. Filter out transients (values during startup/shutdown ramps)
3. Take low percentile (default 5th) of remaining stable values
4. Clamp to fuel-type-specific reasonable range

Returns the inferred p_min in MW, or nothing if insufficient data.
"""
function infer_p_min(historical_data::DataFrame, p_max::Float64, fuel_type::Symbol; percentile::Float64=0.05)
    if nrow(historical_data) < MIN_DATA_POINTS_FOR_RAMP_INFERENCE
        return nothing
    end

    if p_max <= 0
        return nothing
    end

    # Sort by time
    sort!(historical_data, :date_time_utc)
    gen_values = historical_data.actual_generation_output_mw

    # Calculate deltas to identify transients
    deltas = diff(gen_values)

    # Define ramp threshold: if |delta| > 5% of p_max, consider it a transient
    ramp_threshold = 0.05 * p_max

    # Collect stable non-zero values
    # A value is "stable" if both adjacent deltas are small (not ramping)
    stable_values = Float64[]
    for i in 2:(length(gen_values) - 1)
        value = gen_values[i]
        delta_before = abs(deltas[i-1])
        delta_after = abs(deltas[i])

        # Include if: non-zero AND not ramping (stable operation)
        if value > 0 && delta_before < ramp_threshold && delta_after < ramp_threshold
            push!(stable_values, value)
        end
    end

    # Need enough stable values for meaningful inference
    if length(stable_values) < 50
        return nothing
    end

    # Take the specified percentile (default 5th) of stable values
    inferred_p_min = Statistics.quantile(stable_values, percentile)

    # Sanity check: clamp to fuel-type-specific reasonable range
    bounds_category = get_p_min_bounds_category(fuel_type)
    (min_frac, max_frac) = get(P_MIN_BOUNDS, bounds_category, P_MIN_BOUNDS[:default])
    min_bound = min_frac * p_max
    max_bound = max_frac * p_max

    return clamp(inferred_p_min, min_bound, max_bound)
end

# Sanity check bounds for uptime/downtime by fuel type category (hours)
# Format: fuel_type => (min_uptime_bounds, min_downtime_bounds) where each is (min, max)
const UPTIME_DOWNTIME_BOUNDS = Dict(
    :coal => ((8, 48), (4, 24)),       # Coal: long cycles, high min uptime/downtime
    :gas_ccgt => ((2, 12), (1, 8)),    # CCGT: moderate flexibility
    :gas_ocgt => ((1, 4), (1, 4)),     # OCGT: very flexible, short cycles
    :default => ((2, 24), (1, 12)),    # Default: moderate bounds
)

"""
    infer_uptime_downtime(historical_data::DataFrame, fuel_type::Symbol; percentile::Float64=0.05)

Infer minimum uptime and downtime from historical generation data.

Strategy:
1. Identify "on" periods (consecutive non-zero output) → min uptime
2. Identify "off" periods (consecutive zero output) → min downtime
3. Take low percentile of durations (excluding very short blips)
4. Clamp to fuel-type-specific reasonable ranges

Returns (min_uptime, min_downtime) in hours, or (nothing, nothing) if insufficient data.
"""
function infer_uptime_downtime(historical_data::DataFrame, fuel_type::Symbol; percentile::Float64=0.05)
    if nrow(historical_data) < MIN_DATA_POINTS_FOR_RAMP_INFERENCE
        return (nothing, nothing)
    end

    # Sort by time
    sort!(historical_data, :date_time_utc)
    gen_values = historical_data.actual_generation_output_mw

    # Determine resolution in hours
    resolution_code = historical_data.resolution_code[1]
    resolution_minutes = parse_resolution_to_minutes(resolution_code)
    period_hours = resolution_minutes / 60.0

    # Identify on/off states (threshold: > 1 MW considered "on")
    is_on = gen_values .> 1.0

    # Find durations of consecutive on/off periods
    on_durations = Float64[]
    off_durations = Float64[]

    current_state = is_on[1]
    current_duration = 1

    for i in 2:length(is_on)
        if is_on[i] == current_state
            current_duration += 1
        else
            # State changed, record duration
            duration_hours = current_duration * period_hours
            if current_state  # was ON
                push!(on_durations, duration_hours)
            else  # was OFF
                push!(off_durations, duration_hours)
            end
            current_state = is_on[i]
            current_duration = 1
        end
    end
    # Don't forget the last period
    duration_hours = current_duration * period_hours
    if current_state
        push!(on_durations, duration_hours)
    else
        push!(off_durations, duration_hours)
    end

    # Filter out very short periods (likely data glitches)
    # Minimum 2 periods to count as a real on/off event
    min_duration = 2 * period_hours
    on_durations = filter(d -> d >= min_duration, on_durations)
    off_durations = filter(d -> d >= min_duration, off_durations)

    # Need enough cycles for meaningful inference
    min_cycles = 5
    min_uptime = nothing
    min_downtime = nothing

    # Get bounds for this fuel type
    bounds_category = get_p_min_bounds_category(fuel_type)
    bounds = get(UPTIME_DOWNTIME_BOUNDS, bounds_category, UPTIME_DOWNTIME_BOUNDS[:default])
    (uptime_min, uptime_max) = bounds[1]
    (downtime_min, downtime_max) = bounds[2]

    if length(on_durations) >= min_cycles
        inferred_uptime = Statistics.quantile(on_durations, percentile)
        min_uptime = round(Int, clamp(inferred_uptime, uptime_min, uptime_max))
    end

    if length(off_durations) >= min_cycles
        inferred_downtime = Statistics.quantile(off_durations, percentile)
        min_downtime = round(Int, clamp(inferred_downtime, downtime_min, downtime_max))
    end

    return (min_uptime, min_downtime)
end

# TODO: Make get_generators return Vector{Generator}

# TODO: 1o pass: static list
# TODO: 2o pass: with renewables somehow

function get_generators(source::Bool=false)
    if source == true
        units = DataFrame(CSV.File(joinpath(@__DIR__, "..", "data", "productionunit_202406181240.csv")))
        select!(
            units,
            :GenerationUnitEIC => :unit,
            :InstalledGenCapacity => :p_max,
            :MinActive => :p_min
        )
        # not sure how to infer costs yet
        units.fixed_cost = rand(30:40, size(units, 1))  # Generate a random number for each row
        units.variable_cost = rand(50:80, size(units, 1))  # Generate a random number for each row
    else
        units = DataFrame(CSV.File(joinpath(@__DIR__, "..", "mpm-lab/" * "generating_units.csv")))
    end

    generators = [
        Generator(
            DUMMY_CODE,                    # Placeholder for code
            row.generating_unit,           # Maps to 'name'
            DUMMY_FUEL_TYPE,               # Dummy value for fuel_type
            DUMMY_LOCATION,                # Dummy value for location
            Float64(row.p_max),            # Convert Int64 to Float64 for p_max
            Float64(row.p_min),            # Convert Int64 to Float64 for p_min
            DUMMY_BIDDING_ZONE,            # Dummy value for bidding_zone
            DUMMY_MARGINAL_COST            # Dummy value for marginal_cost
        ) for row in eachrow(units)]

    return generators
end

function get_min_active_capacity(max_capacity::Float64)
    return 0.1 * max_capacity  # Example: 10% of max capacity
end


function get_marginal_cost(day::Dates.Date, fuel_type::String, bidding_zone::String="GR")
    # Realistic marginal costs based on fuel type and market conditions
    # Updated for 2025 European energy crisis and carbon pricing

    # Base fuel costs (€/MWh) - post-Ukraine war pricing with carbon costs
    fuel_costs = Dict(
        "Hydro Water Reservoir" => 12.0,           # Low but includes O&M + opportunity cost
        "Hydro Run-of-river and poundage" => 8.0,  # Low but includes O&M
        "Hydro Pumped Storage" => 25.0,            # Higher due to pumping costs
        "Fossil Brown coal/Lignite" => 95.0,       # High due to carbon pricing (€80/tonne CO₂)
        "Fossil Gas" => 140.0,                     # High gas prices + carbon costs
        "Nuclear" => 35.0,                         # Low fuel but high fixed costs
        "Fossil Oil" => 180.0,                     # Very expensive fuel + carbon
        "Fossil Hard coal" => 110.0,               # Coal price + carbon pricing
        "Wind Onshore" => 5.0,                     # Very low - no fuel cost, just O&M
        "Wind Offshore" => 8.0,                    # Very low - no fuel cost, higher O&M
        "Solar" => 3.0,                           # Very low - no fuel cost
        "Biomass" => 85.0,                        # Biomass fuel cost + carbon neutral benefit
        "Waste" => 65.0,                          # Waste processing costs
        "Geothermal" => 25.0,                     # Low - geothermal energy + O&M
        "Other" => 120.0                          # Default fallback - assume gas-like
    )

    # Market bid markup (generators don't bid marginal cost in real markets)
    bid_markup_multiplier = 2.2  # Generators typically bid 1.5-3x marginal cost

    # Add seasonal/temporal variations (summer 2025)
    summer_multiplier = 1.15  # Higher costs in summer due to cooling demand + tight supply

    # Get base cost for fuel type
    base_cost = get(fuel_costs, fuel_type, 120.0)  # Default to gas-like if not found

    # Apply market markup and seasonal adjustment
    market_cost = base_cost * bid_markup_multiplier * summer_multiplier

    # Add some daily variation based on day of year (simple sine wave)
    day_of_year = Dates.dayofyear(day)
    daily_variation = 1.0 + 0.15 * sin(2π * day_of_year / 365)  # ±15% variation

    return market_cost * daily_variation
end

# pull from postgres, for now only active units of given date (I think)
# exclude_unavailable: if true, excludes generators with active outages and reduces capacity for partial outages
# infer_ramp_rates: if true, infer ramp rates from historical generation data (3 months)
function get_generators(map_code::String, day::Dates.Date;
                       exclude_unavailable::Bool=true,
                       infer_ramp_rates_flag::Bool=false)
    if exclude_unavailable
        # Query with unavailability filtering:
        # - Excludes generators with complete outages (available_capacity_mw = 0)
        # - Reduces p_max for partial outages (available_capacity_mw > 0)
        # - Only considers 'Active' status outages (ignores Cancelled/Withdrawn)
        # - Uses MIN available capacity when multiple outage records exist (conservative)
        query = """
        WITH active_outages AS (
            SELECT
                asset_code,
                MIN(available_capacity_mw) AS available_capacity_mw
            FROM entsoe.unavailability_of_production_and_generation_units
            WHERE status = 'Active'
              AND area_map_code = \$1
              AND \$2::timestamp >= start_outage_utc::timestamp
              AND \$2::timestamp < end_outage_utc::timestamp
            GROUP BY asset_code
        )
        SELECT
            g.valid_from,
            g.valid_to,
            g.production_unit_code,
            g.production_unit_name,
            g.production_unit_status,
            g.production_unit_type,
            g.production_unit_location,
            g.production_unit_installed_capacity_mw,
            g.production_unit_voltage_kv,
            g.area_code,
            g.area_display_name,
            g.area_type_code,
            g.area_map_code,
            g.generation_unit_code,
            g.generation_unit_name,
            g.generation_unit_status,
            g.generation_unit_type,
            g.generation_unit_location,
            -- Use available capacity if partial outage, otherwise installed capacity
            COALESCE(
                CASE
                    WHEN o.available_capacity_mw > 0 THEN o.available_capacity_mw
                    ELSE NULL
                END,
                g.generation_unit_installed_capacity_mw
            ) AS generation_unit_installed_capacity_mw,
            g.update_time_utc,
            g.source,
            -- Include outage info for debugging/logging
            o.available_capacity_mw AS outage_available_capacity
        FROM
            entsoe.production_and_generation_units g
        LEFT JOIN active_outages o ON g.generation_unit_code = o.asset_code
        WHERE
            g.production_unit_status = 'COMMISSIONED'
            AND g.generation_unit_status = 'COMMISSIONED'
            AND g.area_type_code IN ('BZN', 'BZN/CTA')
            AND g.area_map_code = \$1
            AND DATE(\$2)
                BETWEEN DATE(g.valid_from)
                AND COALESCE(
                        DATE(g.valid_to),
                        DATE(\$2) + INTERVAL '1 year'
                    )
            -- Exclude complete outages (available_capacity = 0)
            AND (o.asset_code IS NULL OR o.available_capacity_mw > 0)
        """
    else
        # Original query without unavailability filtering
        query = """
        SELECT
            valid_from,
            valid_to,
            production_unit_code,
            production_unit_name,
            production_unit_status,
            production_unit_type,
            production_unit_location,
            production_unit_installed_capacity_mw,
            production_unit_voltage_kv,
            area_code,
            area_display_name,
            area_type_code,
            area_map_code,
            generation_unit_code,
            generation_unit_name,
            generation_unit_status,
            generation_unit_type,
            generation_unit_location,
            generation_unit_installed_capacity_mw,
            update_time_utc,
            source

        FROM
            entsoe.production_and_generation_units
        WHERE
            production_unit_status = 'COMMISSIONED'
            AND generation_unit_status = 'COMMISSIONED'
            AND area_type_code IN  ('BZN', 'BZN/CTA')
            AND area_map_code = \$1
            AND DATE(\$2)
                BETWEEN DATE(valid_from)
                AND COALESCE(
                        DATE(valid_to),
                        DATE(\$2) + INTERVAL '1 year'
                    )
        """
    end

    df = Euphemia.sql2df_with_retry(query, [map_code, day])

    # Build generators (without ramp rates initially)
    generators = Generator[]
    for row in eachrow(df)
        gen = Generator(
            row.generation_unit_code,                    # code
            row.generation_unit_name,                    # name
            Symbol(row.generation_unit_type),            # fuel_type (convert to Symbol)
            row.generation_unit_location,                # location
            Float64(row.generation_unit_installed_capacity_mw), # p_max
            get_min_active_capacity(
                Float64(row.generation_unit_installed_capacity_mw)
            ), # p_min
            row.area_map_code,                           # bidding_zone
            get_marginal_cost(
                day,
                row.generation_unit_type,
                row.area_display_name
            )                                           # marginal_cost
        )
        push!(generators, gen)
    end

    # Optionally infer ramp rates from historical data
    if infer_ramp_rates_flag
        generators = infer_ramp_rates_for_generators(generators, day)
    end

    return generators
end

"""
    infer_parameters_for_generators(generators::Vector{Generator}, day::Date)

Infer technical parameters (ramp rates, p_min, uptime/downtime) for generators from historical data.
Returns a new vector of Generator objects with inferred parameters populated.

Parameters inferred:
- ramp_up, ramp_down: from 95th percentile of observed ramps (fraction/hour)
- p_min: from 5th percentile of stable non-zero operation (MW)
- min_uptime, min_downtime: from 5th percentile of on/off cycle durations (hours)
"""
function infer_parameters_for_generators(generators::Vector{Generator}, day::Dates.Date)
    updated_generators = Generator[]

    for gen in generators
        # Fetch historical generation data
        historical = get_historical_generation(gen.code, day)

        # Infer ramp rates (as fraction of p_max per hour)
        rates = infer_ramp_rates(historical, gen.p_max)

        # Determine parameters based on fuel type
        if gen.fuel_type in FLEXIBLE_FUEL_TYPES
            # Flexible resources (hydro, batteries) can operate at 0 MW
            # and have no meaningful uptime/downtime constraints
            final_p_min = 0.0
            final_uptime = nothing
            final_downtime = nothing
        else
            # Thermal plants: infer from stable operation
            inferred_p_min = infer_p_min(historical, gen.p_max, gen.fuel_type)
            final_p_min = inferred_p_min !== nothing ? inferred_p_min : gen.p_min

            # Infer uptime/downtime from on/off cycles
            (inferred_uptime, inferred_downtime) = infer_uptime_downtime(historical, gen.fuel_type)
            final_uptime = inferred_uptime
            final_downtime = inferred_downtime
        end

        # Create new generator with inferred parameters
        updated_gen = Generator(
            gen.code,
            gen.name,
            gen.fuel_type,
            gen.location,
            gen.p_max,
            final_p_min,
            gen.bidding_zone,
            gen.marginal_cost,
            rates.ramp_up,
            rates.ramp_down,
            final_uptime,
            final_downtime
        )
        push!(updated_generators, updated_gen)
    end

    return updated_generators
end

# Alias for backward compatibility
infer_ramp_rates_for_generators(generators::Vector{Generator}, day::Dates.Date) =
    infer_parameters_for_generators(generators, day)

# Convenience function for backward compatibility - defaults to GR
function get_generators(day::Dates.Date)
    return get_generators("GR", day)
end