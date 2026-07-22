# initial_conditions.jl — Generator state at t=0 (on/off, output, hours on/off, thermal state) for unit-commitment coupling.
# Included by ../Generators.jl inside `module Euphemia` (definition order preserved).

"""
    InitialConditions

Initial state of a generator at the start of the optimization horizon (t=0).
Used to properly constrain the first periods of unit commitment optimization.

Fields:
- `is_on::Bool`: Whether generator was running at t=0
- `output::Float64`: Generation level at t=0 (MW), 0 if off
- `hours_on::Int`: Consecutive hours unit has been on (0 if currently off)
- `hours_off::Int`: Consecutive hours unit has been off (0 if currently on)
- `thermal_state::Symbol`: Temperature state (:hot, :warm, :cold) based on hours_off
"""
struct InitialConditions
    is_on::Bool
    output::Float64
    hours_on::Int
    hours_off::Int
    thermal_state::Symbol
end

# Thresholds for thermal state determination (hours since shutdown)
# These are defaults - fuel-specific thresholds come from FuelTypeParameters
const DEFAULT_WARM_THRESHOLD_HOURS = 8   # < 8 hours = hot start
const DEFAULT_COLD_THRESHOLD_HOURS = 48  # > 48 hours = cold start

"""
    determine_thermal_state(hours_off::Int; warm_threshold::Int=8, cold_threshold::Int=48) -> Symbol

Determine the thermal state of a generator based on how long it has been off.

Returns:
- `:hot` if hours_off <= warm_threshold (quick restart, lowest cost)
- `:warm` if warm_threshold < hours_off <= cold_threshold
- `:cold` if hours_off > cold_threshold (full cold start required)
"""
function determine_thermal_state(hours_off::Int; warm_threshold::Int=DEFAULT_WARM_THRESHOLD_HOURS,
                                  cold_threshold::Int=DEFAULT_COLD_THRESHOLD_HOURS)
    if hours_off <= warm_threshold
        return :hot
    elseif hours_off <= cold_threshold
        return :warm
    else
        return :cold
    end
end

"""
    get_recent_generation(generator_code::String, end_datetime::DateTime; hours_back::Int=72)

Fetch recent actual generation data for determining initial conditions.
Returns data for the specified hours before end_datetime.
"""
function get_recent_generation(generator_code::String, end_datetime::DateTime; hours_back::Int=72)
    start_datetime = end_datetime - Dates.Hour(hours_back)

    query = """
    SELECT date_time_utc, resolution_code, actual_generation_output_mw
    FROM entsoe.actual_generation_output_per_generation_unit
    WHERE generation_unit_code = \$1
      AND date_time_utc >= \$2
      AND date_time_utc < \$3
      AND actual_generation_output_mw IS NOT NULL
    ORDER BY date_time_utc DESC
    """
    return Euphemia.sql2df_with_retry(query, [generator_code, start_datetime, end_datetime])
end

"""
    get_recent_generation_batch(generator_codes::Vector{String}, end_datetime::DateTime; hours_back::Int=72)

Fetch recent actual generation data for multiple generators in a single query.
This is much faster than calling get_recent_generation() for each generator separately.

Returns a DataFrame with columns: generation_unit_code, date_time_utc, resolution_code, actual_generation_output_mw
"""
function get_recent_generation_batch(generator_codes::Vector{String}, end_datetime::DateTime; hours_back::Int=72)
    if isempty(generator_codes)
        return DataFrame(
            generation_unit_code=String[],
            date_time_utc=DateTime[],
            resolution_code=String[],
            actual_generation_output_mw=Float64[]
        )
    end

    start_datetime = end_datetime - Dates.Hour(hours_back)

    query = """
    SELECT generation_unit_code, date_time_utc, resolution_code, actual_generation_output_mw
    FROM entsoe.actual_generation_output_per_generation_unit
    WHERE generation_unit_code = ANY(\$1)
      AND date_time_utc >= \$2
      AND date_time_utc < \$3
      AND actual_generation_output_mw IS NOT NULL
    ORDER BY generation_unit_code, date_time_utc DESC
    """
    return Euphemia.sql2df_with_retry(query, [generator_codes, start_datetime, end_datetime])
end

"""
    infer_initial_conditions_from_data(historical::DataFrame, fuel_type::Symbol)

Infer initial conditions from pre-fetched historical data.
This is the core logic used by both single-generator and batch processing.

Historical data should be ordered DESC (most recent first).
"""
function infer_initial_conditions_from_data(historical::DataFrame, fuel_type::Symbol)
    if nrow(historical) == 0
        return get_default_initial_conditions(fuel_type)
    end

    # Data is ordered DESC, so first row is most recent (closest to start time)
    latest_output = historical.actual_generation_output_mw[1]
    is_on = latest_output > 1.0  # Consider > 1 MW as "on"
    output = is_on ? latest_output : 0.0

    # Count consecutive hours on or off
    if is_on
        hours_on = count_consecutive_state(historical, true)
        hours_off = 0
        thermal_state = :hot
    else
        hours_on = 0
        hours_off = count_consecutive_state(historical, false)
        params = get_fuel_type_parameters(fuel_type)
        thermal_state = determine_thermal_state(hours_off;
                                                 warm_threshold=params.warm_threshold,
                                                 cold_threshold=params.cold_threshold)
    end

    return InitialConditions(is_on, output, hours_on, hours_off, thermal_state)
end

"""
    infer_initial_conditions(generator_code::String, market_day::Date, fuel_type::Symbol)

Infer initial conditions for a generator by analyzing generation data from the day before.

The market day optimization starts at 00:00 CET (23:00 UTC day before for winter,
22:00 UTC for summer). We look at the actual generation at that timestamp and trace
back to determine how long the unit has been on or off.

Returns InitialConditions with:
- is_on: True if generation > 1 MW at the start time
- output: Actual MW output at start time
- hours_on: How many consecutive hours the unit has been running
- hours_off: How many consecutive hours the unit has been off
- thermal_state: :hot, :warm, or :cold based on hours_off

Note: For batch processing of multiple generators, use get_initial_conditions() which
uses a single SQL query for all generators instead of one query per generator.
"""
function infer_initial_conditions(generator_code::String, market_day::Dates.Date, fuel_type::Symbol)
    # Market day starts at 00:00 CET
    # CET = UTC+1 in winter, CEST = UTC+2 in summer
    # For simplicity, assume 23:00 UTC on day before is close to 00:00 CET
    day_before = market_day - Dates.Day(1)
    start_of_market_day_utc = DateTime(day_before, Time(23, 0, 0))  # ~00:00 CET

    # Get 72 hours of data leading up to the market day start
    historical = get_recent_generation(generator_code, start_of_market_day_utc; hours_back=72)

    return infer_initial_conditions_from_data(historical, fuel_type)
end

"""
    count_consecutive_state(historical::DataFrame, looking_for_on::Bool) -> Int

Count how many consecutive hours the generator has been in the given state (on or off).
Historical data is assumed to be ordered DESC (most recent first).
"""
function count_consecutive_state(historical::DataFrame, looking_for_on::Bool)
    threshold = 1.0  # MW threshold for "on"
    consecutive_hours = 0

    for i in 1:nrow(historical)
        output = historical.actual_generation_output_mw[i]
        is_on = output > threshold

        if is_on == looking_for_on
            # Still in the same state - estimate hours based on resolution
            resolution_code = historical.resolution_code[i]
            resolution_minutes = parse_resolution_to_minutes(resolution_code)
            consecutive_hours += resolution_minutes / 60
        else
            # State changed - stop counting
            break
        end
    end

    return round(Int, consecutive_hours)
end

"""
    get_default_initial_conditions(fuel_type::Symbol) -> InitialConditions

Return default initial conditions when no historical data is available.

Heuristics:
- Baseload plants (coal, nuclear, lignite): Assume running at ~70% capacity
- Mid-merit plants (CCGT): Assume off but warm
- Peakers (OCGT): Assume off and cold
- Flexible (hydro, batteries): Assume off but ready (hot)
"""
function get_default_initial_conditions(fuel_type::Symbol)
    fuel_str = string(fuel_type)

    if occursin("coal", lowercase(fuel_str)) || occursin("lignite", lowercase(fuel_str)) ||
       occursin("nuclear", lowercase(fuel_str))
        # Baseload: assume running
        return InitialConditions(true, 0.0, 24, 0, :hot)  # output will be set by caller
    elseif occursin("gas", lowercase(fuel_str)) && occursin("ccgt", lowercase(fuel_str))
        # CCGT: often off overnight but warm
        return InitialConditions(false, 0.0, 0, 6, :hot)
    elseif occursin("gas", lowercase(fuel_str))
        # OCGT/peakers: off and potentially cold
        return InitialConditions(false, 0.0, 0, 24, :warm)
    elseif fuel_type in FLEXIBLE_FUEL_TYPES
        # Hydro/batteries: ready to start instantly
        return InitialConditions(false, 0.0, 0, 0, :hot)
    else
        # Default: assume off and warm
        return InitialConditions(false, 0.0, 0, 12, :warm)
    end
end

"""
    get_initial_conditions(generators::Vector{Generator}, market_day::Date;
                          use_historical::Bool=true) -> Dict{String, InitialConditions}

Get initial conditions for all generators for a given market day.

If use_historical=true (default), queries actual generation data from the day before
to determine the state of each generator at market day start. Uses a single batch SQL
query for all generators (instead of N separate queries) for much better performance.

If use_historical=false, uses fuel-type-based defaults.

Returns a Dict mapping generator_code => InitialConditions.
"""
function get_initial_conditions(generators::Vector{Generator}, market_day::Dates.Date;
                                use_historical::Bool=true)
    conditions = Dict{String, InitialConditions}()

    if use_historical && !isempty(generators)
        # Batch fetch: single SQL query for all generators (N queries → 1 query)
        day_before = market_day - Dates.Day(1)
        start_of_market_day_utc = DateTime(day_before, Time(23, 0, 0))  # ~00:00 CET

        generator_codes = [gen.code for gen in generators]
        all_historical = get_recent_generation_batch(generator_codes, start_of_market_day_utc; hours_back=72)

        # Process each generator's data from the batch result
        for gen in generators
            # Filter data for this generator
            gen_data = filter(row -> row.generation_unit_code == gen.code, all_historical)

            # Convert to DataFrame with expected columns (without generation_unit_code)
            if nrow(gen_data) > 0
                historical = select(gen_data, [:date_time_utc, :resolution_code, :actual_generation_output_mw])
            else
                historical = DataFrame(
                    date_time_utc=DateTime[],
                    resolution_code=String[],
                    actual_generation_output_mw=Float64[]
                )
            end

            ic = infer_initial_conditions_from_data(historical, gen.fuel_type)

            # Validate and adjust initial conditions for ON generators
            if ic.is_on
                # Clamp output to valid range [effective_p_min, p_max]
                # This handles data quality issues where historical data shows:
                # - output < p_min (below technical minimum)
                # - output > p_max (above capacity, possible due to capacity changes)
                #
                # IMPORTANT: The UC model uses effective_p_min = max(gen.p_min, min_load_factor × p_max)
                # for non-flexible fuel types. We must use the same effective p_min here to avoid
                # infeasibility from ramp constraints.
                if gen.fuel_type in FLEXIBLE_FUEL_TYPES
                    min_valid_output = gen.p_min > 0 ? gen.p_min : 0.0
                else
                    params = get_fuel_type_parameters(gen.fuel_type)
                    min_valid_output = max(gen.p_min, params.min_load_factor * gen.p_max)
                end
                adjusted_output = ic.output

                if ic.output > gen.p_max
                    # Output above capacity - clamp to p_max
                    adjusted_output = gen.p_max
                elseif ic.output < min_valid_output
                    # Output below minimum - use 70% of p_max as reasonable default
                    # (but at least the effective p_min)
                    adjusted_output = max(0.7 * gen.p_max, min_valid_output)
                    @warn "Initial output below effective p_min" generator=gen.name output=ic.output effective_p_min=min_valid_output adjusted_to=adjusted_output
                end

                if adjusted_output != ic.output
                    ic = InitialConditions(true, adjusted_output, ic.hours_on, ic.hours_off, ic.thermal_state)
                end
            end
            conditions[gen.code] = ic
        end
    else
        # Use defaults (no DB query)
        for gen in generators
            ic = get_default_initial_conditions(gen.fuel_type)
            if ic.is_on
                # Use 70% of p_max but ensure it's at least effective p_min
                # (same calculation as in UC model)
                if gen.fuel_type in FLEXIBLE_FUEL_TYPES
                    min_valid_output = gen.p_min > 0 ? gen.p_min : 0.0
                else
                    params = get_fuel_type_parameters(gen.fuel_type)
                    min_valid_output = max(gen.p_min, params.min_load_factor * gen.p_max)
                end
                adjusted_output = max(0.7 * gen.p_max, min_valid_output)
                ic = InitialConditions(true, adjusted_output, ic.hours_on, ic.hours_off, ic.thermal_state)
            end
            conditions[gen.code] = ic
        end
    end

    return conditions
end
