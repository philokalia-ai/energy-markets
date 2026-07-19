# parameter_inference.jl — Infer plant-specific ramp rates, p_min and min up/down-time from historical ENTSO-E output.
# Included by ../Generators.jl inside `module Euphemia` (definition order preserved).

"""
    get_historical_generation(generator_code::String, end_date::Date; months_back::Int=12)

Fetch historical actual generation data for a specific generator.

Returns a DataFrame with columns: datetime_utc, resolution_code, actual_generation_mw
"""
function get_historical_generation(generator_code::String, end_date::Dates.Date; months_back::Int=12)
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

