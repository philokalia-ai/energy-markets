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
    Symbol("Energy storage"),  # BESS and other storage technologies
    Symbol("Other"),
])

# Variable renewable types that should be excluded from Unit Commitment
# Their generation is handled via forecasts subtracted from load (net demand)
const VARIABLE_RENEWABLE_TYPES = Set([
    Symbol("Wind Onshore"),
    Symbol("Wind Offshore"),
    Symbol("Solar"),
])

"""
    infer_fuel_type_from_name(name::String, declared_type::Symbol) -> Symbol

Attempt to infer the actual fuel type from the generator name when the declared
type is ambiguous (e.g., "Other"). This handles cases where BESS units are
miscategorized in the ENTSO-E database.

Returns the inferred fuel type, or the original declared_type if no inference is possible.
"""
function infer_fuel_type_from_name(name::String, declared_type::Symbol)::Symbol
    # Only attempt inference for "Other" fuel type
    if declared_type != Symbol("Other")
        return declared_type
    end

    name_upper = uppercase(name)

    # Battery Energy Storage Systems
    if occursin("BESS", name_upper) ||
       occursin("BATTERY", name_upper) ||
       occursin("BATTERIE", name_upper) ||  # German/French
       occursin("BATTERI", name_upper)      # Nordic
        return Symbol("Energy storage")
    end

    # Could add more patterns here in the future:
    # - VPP patterns for virtual power plants
    # - Interconnector patterns
    # - etc.

    # No inference possible, return original type
    return declared_type
end

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

"""
    get_min_active_capacity(max_capacity::Float64, fuel_type::Symbol)

Calculate minimum active capacity based on fuel type.
Uses min_load_factor from FuelTypeParameters for thermal plants,
returns 0 for flexible resources (hydro, storage).
"""
function get_min_active_capacity(max_capacity::Float64, fuel_type::Symbol)
    if fuel_type in FLEXIBLE_FUEL_TYPES
        return 0.0
    else
        params = get_fuel_type_parameters(fuel_type)
        return params.min_load_factor * max_capacity
    end
end


# TTF gas price lookup (yfinance.ttf_f, populated by the ceres yfinance ETL).
# Cached per day because get_generators() calls get_marginal_cost once per generator.
const TTF_PRICE_CACHE = Dict{Dates.Date,Union{Float64,Nothing}}()

# Gas plant cost model constants
const GAS_PLANT_EFFICIENCY = 0.55   # CCGT-dominated fleet efficiency (LHV basis)
const GAS_EMISSION_FACTOR = 0.202   # tCO₂ per MWh of gas burned
const EUA_PRICE = 70.0              # €/tCO₂ carbon price (no EUA feed in DB yet)
const GAS_VOM_COST = 2.0            # €/MWh variable O&M

"""
    get_ttf_price(day::Dates.Date) -> Union{Float64,Nothing}

Most recent TTF front-month futures close (€/MWh) at or before `day`, from
`yfinance.ttf_f`. Looks back up to 10 days to bridge weekends and holidays.
Returns `nothing` when no data exists near `day` (e.g., before the table's
history starts), in which case callers should fall back to stylized costs.

For a market date D this returns the close of the last trading day before D,
which is the price information available at day-ahead auction time.
"""
function get_ttf_price(day::Dates.Date)
    haskey(TTF_PRICE_CACHE, day) && return TTF_PRICE_CACHE[day]

    # Strictly before the delivery day: the day-ahead auction for D clears
    # around noon on D-1, when D's own close does not exist yet. Using
    # `date <= day` would leak future information into backtests.
    df = try
        Euphemia.sql2df_with_retry(
            """
            SELECT close
            FROM yfinance.ttf_f
            WHERE date < \$1 AND date > \$1::date - INTERVAL '10 days'
            ORDER BY date DESC
            LIMIT 1
            """,
            [day]
        )
    catch e
        # Transient DB failure: warn and fall back WITHOUT caching, so the
        # next call retries instead of pinning this date to the fallback
        @warn "TTF price lookup failed for $day, falling back to stylized gas cost: $e"
        return nothing
    end

    price = isempty(df) ? nothing : Float64(df.close[1])
    if price === nothing
        @warn "No TTF price within 10 days before $day; using stylized gas cost"
    end

    # Cache both hits and genuine data absence (but never transient errors)
    TTF_PRICE_CACHE[day] = price
    return price
end

function get_marginal_cost(day::Dates.Date, fuel_type::String, bidding_zone::String="GR")
    # Gas-fired units: use real TTF fuel prices when available.
    # marginal cost = fuel cost / efficiency + carbon cost + variable O&M
    # No bid markup here — the bidding layer applies its own markup_factor.
    if fuel_type == "Fossil Gas"
        ttf = get_ttf_price(day)
        if ttf !== nothing
            fuel_cost = ttf / GAS_PLANT_EFFICIENCY
            carbon_cost = GAS_EMISSION_FACTOR / GAS_PLANT_EFFICIENCY * EUA_PRICE
            return fuel_cost + carbon_cost + GAS_VOM_COST
        end
    end

    return get(FUEL_SRMC, fuel_type, 110.0)
end

# Short-run marginal costs (SRMC, €/MWh electric) including carbon at
# EUA_PRICE and variable O&M. No bid markup — bidding strategy is applied
# in the order book layer, not here (the UC objective also uses these
# costs and should see true costs, not bids).
#
# Thermal SRMC = fuel/efficiency + emission_factor(el) × EUA + VOM, e.g.:
#   Lignite (GR): fuel+VOM ≈ €25, EF ≈ 1.25 tCO₂/MWh_el → 25 + 1.25×70 ≈ 112
#   Hard coal:    ~€14/MWh_th at η=0.40 → 36 + 0.9×70 + 3 ≈ 100
#   Oil (HFO):    ~€40/MWh_th at η=0.38 → 105 + 0.75×70 ≈ 155
const FUEL_SRMC = Dict(
    "Hydro Water Reservoir" => 12.0,           # O&M only; water value applied in bidding layer
    "Hydro Run-of-river and poundage" => 3.0,  # Must-run, near-zero variable cost
    "Hydro Pumped Storage" => 60.0,            # Pumping energy cost at off-peak prices
    "Fossil Brown coal/Lignite" => 112.0,      # Mostly carbon (EF ~1.25 tCO₂/MWh for GR lignite)
    "Fossil Gas" => 105.0,                     # Fallback only — TTF path is preferred
    "Nuclear" => 10.0,                         # Fuel cycle cost
    "Fossil Oil" => 155.0,                     # HFO/diesel fuel + carbon
    "Fossil Hard coal" => 100.0,               # API2-level coal + carbon
    "Fossil Coal-derived gas" => 110.0,
    "Wind Onshore" => 1.0,
    "Wind Offshore" => 2.0,
    "Solar" => 1.0,
    "Biomass" => 60.0,                         # Fuel cost, no carbon
    "Waste" => 25.0,                           # Gate fees offset fuel cost
    "Geothermal" => 20.0,
    "Energy storage" => 90.0,                  # Charging-cost opportunity proxy
    "Other" => 110.0                           # Assume gas-like when unknown
)

# pull from postgres, for now only active units of given date (I think)
# exclude_unavailable: if true, excludes generators with active outages and reduces capacity for partial outages
# infer_ramp_rates: if true, infer ramp rates from historical generation data (3 months)
function get_generators(map_code::String, day::Dates.Date;
                       exclude_unavailable::Bool=true,
                       exclude_variable_renewables::Bool=true,
                       infer_ramp_rates_flag::Bool=false)
    if exclude_unavailable
        # Query with unavailability filtering:
        # - Excludes generators with complete outages (available_capacity_mw = 0)
        # - Reduces p_max for partial outages (available_capacity_mw > 0)
        # - Only considers 'Active' status outages (ignores Cancelled/Withdrawn)
        # - Uses MIN available capacity when multiple outage records exist (conservative)
        # Note: DISTINCT ON deduplicates by generation_unit_code since ENTSO-E data
        # can have overlapping validity periods for the same generator (data quality issue).
        # We take the most recent version (by valid_from) with highest capacity as tiebreaker.
        #
        # Date validity filter relaxation:
        # ENTSO-E data has stale valid_from/valid_to dates for many operating plants.
        # Example: Spain nuclear has valid_from in 2026 (future!), Germany coal has valid_to in 2022.
        # Solution: Include plants that EITHER pass date validity OR have recent actual generation.
        # This uses hard evidence (actual_generation_output) to include operating plants.
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
        ),
        -- Find generators with recent actual generation (last 60 days)
        -- This catches plants with stale validity dates that are still operating
        recent_generation AS (
            SELECT DISTINCT generation_unit_code
            FROM entsoe.actual_generation_output_per_generation_unit
            WHERE date_time_utc >= \$2::timestamp - INTERVAL '60 days'
              AND date_time_utc < \$2::timestamp + INTERVAL '1 day'
              AND actual_generation_output_mw > 0
        )
        SELECT DISTINCT ON (g.generation_unit_code)
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
        LEFT JOIN recent_generation rg ON g.generation_unit_code = rg.generation_unit_code
        WHERE
            g.production_unit_status = 'COMMISSIONED'
            AND g.generation_unit_status = 'COMMISSIONED'
            AND g.area_type_code IN ('BZN', 'BZN/CTA')
            AND g.area_map_code = \$1
            -- Include if: passes date validity OR has recent actual generation
            AND (
                DATE(\$2)
                    BETWEEN DATE(g.valid_from)
                    AND COALESCE(
                            DATE(g.valid_to),
                            DATE(\$2) + INTERVAL '1 year'
                        )
                OR rg.generation_unit_code IS NOT NULL
            )
            -- Exclude complete outages (available_capacity = 0)
            AND (o.asset_code IS NULL OR o.available_capacity_mw > 0)
        ORDER BY g.generation_unit_code, g.valid_from DESC, g.generation_unit_installed_capacity_mw DESC
        """
    else
        # Original query without unavailability filtering
        # Note: DISTINCT ON deduplicates by generation_unit_code since ENTSO-E data
        # can have overlapping validity periods for the same generator (data quality issue).
        #
        # Date validity filter relaxation (same as above):
        # Include plants that EITHER pass date validity OR have recent actual generation.
        query = """
        WITH recent_generation AS (
            SELECT DISTINCT generation_unit_code
            FROM entsoe.actual_generation_output_per_generation_unit
            WHERE date_time_utc >= \$2::timestamp - INTERVAL '60 days'
              AND date_time_utc < \$2::timestamp + INTERVAL '1 day'
              AND actual_generation_output_mw > 0
        )
        SELECT DISTINCT ON (g.generation_unit_code)
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
            g.generation_unit_installed_capacity_mw,
            g.update_time_utc,
            g.source
        FROM
            entsoe.production_and_generation_units g
        LEFT JOIN recent_generation rg ON g.generation_unit_code = rg.generation_unit_code
        WHERE
            g.production_unit_status = 'COMMISSIONED'
            AND g.generation_unit_status = 'COMMISSIONED'
            AND g.area_type_code IN ('BZN', 'BZN/CTA')
            AND g.area_map_code = \$1
            -- Include if: passes date validity OR has recent actual generation
            AND (
                DATE(\$2)
                    BETWEEN DATE(g.valid_from)
                    AND COALESCE(
                            DATE(g.valid_to),
                            DATE(\$2) + INTERVAL '1 year'
                        )
                OR rg.generation_unit_code IS NOT NULL
            )
        ORDER BY g.generation_unit_code, g.valid_from DESC, g.generation_unit_installed_capacity_mw DESC
        """
    end

    df = Euphemia.sql2df_with_retry(query, [map_code, day])

    # Build generators (without ramp rates initially)
    generators = Generator[]
    for row in eachrow(df)
        # Infer actual fuel type from name if declared as "Other"
        declared_type = Symbol(row.generation_unit_type)
        inferred_type = infer_fuel_type_from_name(row.generation_unit_name, declared_type)

        if inferred_type != declared_type
            @info "Reclassified generator $(row.generation_unit_name) from $declared_type to $inferred_type"
        end

        gen = Generator(
            row.generation_unit_code,                    # code
            row.generation_unit_name,                    # name
            inferred_type,                               # fuel_type (possibly inferred)
            row.generation_unit_location,                # location
            Float64(row.generation_unit_installed_capacity_mw), # p_max
            get_min_active_capacity(
                Float64(row.generation_unit_installed_capacity_mw),
                inferred_type
            ), # p_min (fuel-type-specific)
            row.area_map_code,                           # bidding_zone
            get_marginal_cost(
                day,
                row.generation_unit_type,  # Use original type for cost (BESS still has storage costs)
                row.area_display_name
            )                                           # marginal_cost
        )
        push!(generators, gen)
    end

    # Filter out variable renewables (wind, solar) if requested
    # These are handled separately via renewable forecasts subtracted from load
    if exclude_variable_renewables
        pre_filter_count = length(generators)
        generators = filter(g -> g.fuel_type ∉ VARIABLE_RENEWABLE_TYPES, generators)
        filtered_count = pre_filter_count - length(generators)
        if filtered_count > 0
            @info "Filtered out $filtered_count variable renewable generators (Wind/Solar) from UC"
        end
    end

    # Optionally infer ramp rates from historical data
    if infer_ramp_rates_flag
        generators = infer_ramp_rates_for_generators(generators, day)
    end

    return generators
end

"""
    infer_parameters_for_generator(gen::Generator, day::Date) -> Generator

Infer parameters for a single generator from historical data.
This is the core inference function that can be parallelized.

Parameters inferred:
- ramp_up, ramp_down: from 95th percentile of observed ramps (fraction/hour)
- p_min: from 5th percentile of stable non-zero operation (MW)
- min_uptime, min_downtime: from 5th percentile of on/off cycle durations (hours)
"""
function infer_parameters_for_generator(gen::Generator, day::Dates.Date)
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

    # Validate: p_min must not exceed p_max (can happen if outages reduce capacity)
    if final_p_min > gen.p_max
        @warn "Clamping inferred p_min to p_max (outage reduced capacity)" generator=gen.code inferred_p_min=final_p_min p_max=gen.p_max
        final_p_min = gen.p_max
    end

    # Create new generator with inferred parameters
    return Generator(
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
end

"""
    infer_parameters_for_generators(generators::Vector{Generator}, day::Date) -> Vector{Generator}

Infer parameters for multiple generators. Wrapper around `infer_parameters_for_generator`.
"""
function infer_parameters_for_generators(generators::Vector{Generator}, day::Dates.Date)
    return [infer_parameters_for_generator(gen, day) for gen in generators]
end

# Alias for backward compatibility
infer_ramp_rates_for_generators(generators::Vector{Generator}, day::Dates.Date) =
    infer_parameters_for_generators(generators, day)

# Convenience function for backward compatibility - defaults to GR
function get_generators(day::Dates.Date)
    return get_generators("GR", day)
end

# ============================================================================
# Cached Inferred Parameters (Database Persistence)
# ============================================================================

"""
    save_inferred_parameters(generators::Vector{Generator}, bidding_zone::String, reference_date::Date)

Save inferred generator parameters to the database cache.
Uses UPSERT to update existing records or insert new ones.
The inference_date is set to today (when inference was run), not the reference market day.
"""
function save_inferred_parameters(generators::Vector{Generator}, bidding_zone::String, reference_date::Dates.Date)
    sql = """
    INSERT INTO simulations.generator_inferred_parameters
    (generator_code, bidding_zone, inference_date, ramp_up, ramp_down, p_min, min_uptime, min_downtime, data_points_used, created_at)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, NOW())
    ON CONFLICT (generator_code, bidding_zone) DO UPDATE SET
        inference_date = EXCLUDED.inference_date,
        ramp_up = EXCLUDED.ramp_up,
        ramp_down = EXCLUDED.ramp_down,
        p_min = EXCLUDED.p_min,
        min_uptime = EXCLUDED.min_uptime,
        min_downtime = EXCLUDED.min_downtime,
        data_points_used = EXCLUDED.data_points_used,
        created_at = NOW()
    """

    # Helper to convert nothing to missing for PostgreSQL NULL
    to_pg(x) = x === nothing ? missing : x

    # Use today's date as the inference date (when we ran the inference)
    today = Dates.today()

    saved_count = 0
    Euphemia.withdb() do conn
        for gen in generators
            # Count data points (estimate from historical query)
            historical = get_historical_generation(gen.code, reference_date)
            data_points = nrow(historical)

            params = [
                gen.code,
                bidding_zone,
                today,  # inference_date = when we ran the inference
                to_pg(gen.ramp_up),
                to_pg(gen.ramp_down),
                gen.p_min,
                to_pg(gen.min_uptime),
                to_pg(gen.min_downtime),
                data_points
            ]
            LibPQ.execute(conn, sql, params)
            saved_count += 1
        end
    end

    @info "Saved inferred parameters for $saved_count generators in zone $bidding_zone"
    return saved_count
end

"""
    load_cached_parameters(bidding_zone::String; max_age_days::Int=30)

Load cached inferred parameters from the database.
Returns a Dict mapping generator_code => (ramp_up, ramp_down, p_min, min_uptime, min_downtime).
Only returns parameters that are not older than max_age_days.

Note: Physical parameters like ramp rates don't change frequently, so a longer cache
period (30 days) is appropriate.
"""
function load_cached_parameters(bidding_zone::String; max_age_days::Int=30)
    query = """
    SELECT generator_code, ramp_up, ramp_down, p_min, min_uptime, min_downtime, inference_date
    FROM simulations.generator_inferred_parameters
    WHERE bidding_zone = \$1
      AND inference_date >= CURRENT_DATE - INTERVAL '\$2 days'
    """

    # Replace $2 with actual value since PostgreSQL doesn't parameterize intervals well
    query = replace(query, "\$2" => string(max_age_days))
    df = Euphemia.sql2df_with_retry(query, [bidding_zone])

    cache = Dict{String, NamedTuple{(:ramp_up, :ramp_down, :p_min, :min_uptime, :min_downtime),
                                     Tuple{Union{Float64,Nothing}, Union{Float64,Nothing}, Union{Float64,Nothing}, Union{Int,Nothing}, Union{Int,Nothing}}}}()

    for row in eachrow(df)
        cache[row.generator_code] = (
            ramp_up = ismissing(row.ramp_up) ? nothing : row.ramp_up,
            ramp_down = ismissing(row.ramp_down) ? nothing : row.ramp_down,
            p_min = ismissing(row.p_min) ? nothing : row.p_min,
            min_uptime = ismissing(row.min_uptime) ? nothing : Int(row.min_uptime),
            min_downtime = ismissing(row.min_downtime) ? nothing : Int(row.min_downtime)
        )
    end

    return cache
end

"""
    get_generators_with_inferred_params(map_code::String, day::Date;
                                        use_cache::Bool=true,
                                        max_cache_age_days::Int=7,
                                        exclude_unavailable::Bool=true)

Get generators with inferred parameters, using cached values when available.

If use_cache=true (default):
1. Load cached parameters from DB
2. For generators with cached values, apply them
3. For generators without cache (or stale cache), run inference and save to DB

If use_cache=false: Always run fresh inference (slow but guaranteed fresh).
"""
function get_generators_with_inferred_params(map_code::String, day::Dates.Date;
                                             use_cache::Bool=true,
                                             max_cache_age_days::Int=365,
                                             exclude_unavailable::Bool=true,
                                             exclude_variable_renewables::Bool=true)
    # Get base generators
    generators = get_generators(map_code, day;
                               exclude_unavailable=exclude_unavailable,
                               exclude_variable_renewables=exclude_variable_renewables)

    if !use_cache
        # Fresh inference for all
        println("  🔄 Running fresh parameter inference for all generators...")
        inferred = infer_parameters_for_generators(generators, day)
        save_inferred_parameters(inferred, map_code, day)
        return inferred
    end

    # Load cached parameters
    cache = load_cached_parameters(map_code; max_age_days=max_cache_age_days)
    println("  📦 Found $(length(cache)) cached parameter sets for zone $map_code")

    # Separate generators into cached and uncached
    cached_gens = Generator[]
    uncached_gens = Generator[]

    for gen in generators
        if haskey(cache, gen.code)
            params = cache[gen.code]
            # Apply cached parameters with validation
            candidate_p_min = params.p_min !== nothing ? params.p_min : gen.p_min

            # Validate: p_min must not exceed p_max (can happen if outages reduce capacity)
            if candidate_p_min > gen.p_max
                @warn "Clamping cached p_min to p_max (outage reduced capacity)" generator=gen.code cached_p_min=candidate_p_min p_max=gen.p_max
                candidate_p_min = gen.p_max
            end

            updated_gen = Generator(
                gen.code,
                gen.name,
                gen.fuel_type,
                gen.location,
                gen.p_max,
                candidate_p_min,
                gen.bidding_zone,
                gen.marginal_cost,
                params.ramp_up,
                params.ramp_down,
                params.min_uptime,
                params.min_downtime
            )
            push!(cached_gens, updated_gen)
        else
            push!(uncached_gens, gen)
        end
    end

    println("  ✓ Using cached params for $(length(cached_gens)) generators")

    # Run inference for uncached generators
    if !isempty(uncached_gens)
        println("  🔄 Running inference for $(length(uncached_gens)) uncached generators...")
        newly_inferred = infer_parameters_for_generators(uncached_gens, day)
        save_inferred_parameters(newly_inferred, map_code, day)
        append!(cached_gens, newly_inferred)
    end

    return cached_gens
end

"""
    refresh_inference_cache(zones::Vector{String}, date::Date; parallel::Bool=false)

Proactively refresh the generator parameter inference cache for specified zones.

This function runs parameter inference for all generators in the given zones and
saves results to the database cache. Use this before batch UC runs to ensure
predictable solve times (avoids surprise 17+ minute inference during UC).

When parallel=true, inference is parallelized at the **generator level** (not zone level),
allowing full utilization of all available workers. Each generator's inference is
completely independent.

# Arguments
- `zones`: List of bidding zone codes (e.g., ["GR", "BG", "RO"])
- `date`: Reference date for inference (uses 12 months of historical data before this date)
- `parallel`: If true, runs inference for all generators in parallel using available workers

# Returns
A NamedTuple with:
- `successful_zones`: Number of zones successfully processed
- `failed_zones`: Number of zones that failed
- `total_generators`: Total number of generators processed
- `successful_generators`: Number of generators successfully inferred
- `failed_generators`: Number of generators that failed
- `total_time`: Total processing time in seconds
- `zone_results`: Dict mapping zone code to (success, generator_count, failed_count)

# Example
```julia
# Refresh cache for specific zones
result = refresh_inference_cache(["GR", "BG", "RO"], Date(2024, 6, 15))

# Refresh all available zones with parallel processing
using Distributed
addprocs(80)  # Use all cores - inference is I/O bound
@everywhere using Euphemia
zones = get_available_zones(Date(2024, 6, 15))
result = refresh_inference_cache(zones, Date(2024, 6, 15); parallel=true)
```
"""
function refresh_inference_cache(zones::Vector{String}, date::Dates.Date; parallel::Bool=false)
    start_time = time()

    println("🔄 Refreshing inference cache for $(length(zones)) zones")
    println("📅 Reference date: $date (using 12 months of historical data)")
    println()

    # Step 1: Collect all generators from all zones
    println("📋 Collecting generators from all zones...")
    all_generators = Tuple{String, Generator}[]  # (zone, generator) pairs
    zone_generator_counts = Dict{String, Int}()

    for zone in zones
        try
            gens = get_generators(zone, date)
            zone_generator_counts[zone] = length(gens)
            for gen in gens
                push!(all_generators, (zone, gen))
            end
            println("  📍 $zone: $(length(gens)) generators")
        catch e
            println("  ❌ $zone: failed to load generators - $e")
            zone_generator_counts[zone] = 0
        end
    end

    total_generators = length(all_generators)
    println()
    println("📊 Total: $total_generators generators across $(length(zones)) zones")
    println()

    if total_generators == 0
        return (
            successful_zones = 0,
            failed_zones = length(zones),
            total_generators = 0,
            successful_generators = 0,
            failed_generators = 0,
            total_time = round(time() - start_time, digits=1),
            zone_results = Dict{String, NamedTuple{(:success, :generator_count, :failed_count), Tuple{Bool, Int, Int}}}()
        )
    end

    # Step 2: Run inference for each generator (parallel or sequential)
    println("⚙️  Running inference...")

    function infer_single(zg::Tuple{String, Generator})
        zone, gen = zg
        try
            inferred = infer_parameters_for_generator(gen, date)
            return (zone, gen.code, inferred, nothing)  # (zone, code, result, error)
        catch e
            return (zone, gen.code, nothing, e)
        end
    end

    if parallel && length(workers()) > 1
        println("⚡ Using $(length(workers())) parallel workers for $total_generators generators")
        results = pmap(infer_single, all_generators; on_error=ex -> (nothing, nothing, nothing, ex))
    else
        println("🔄 Sequential processing of $total_generators generators")
        results = [infer_single(zg) for zg in all_generators]
    end

    # Step 3: Group results by zone and save to cache
    println()
    println("💾 Saving results to cache...")

    zone_generators = Dict{String, Vector{Generator}}()
    zone_failures = Dict{String, Int}()
    successful_generators = 0
    failed_generators = 0

    for (zone, code, inferred, err) in results
        if zone === nothing
            failed_generators += 1
            continue
        end

        if !haskey(zone_generators, zone)
            zone_generators[zone] = Generator[]
            zone_failures[zone] = 0
        end

        if err === nothing && inferred !== nothing
            push!(zone_generators[zone], inferred)
            successful_generators += 1
        else
            zone_failures[zone] += 1
            failed_generators += 1
            println("  ⚠️  $zone/$code: inference failed - $err")
        end
    end

    # Save each zone's inferred generators to cache
    zone_results = Dict{String, NamedTuple{(:success, :generator_count, :failed_count), Tuple{Bool, Int, Int}}}()

    for zone in zones
        gens = get(zone_generators, zone, Generator[])
        failures = get(zone_failures, zone, 0)

        if !isempty(gens)
            try
                save_inferred_parameters(gens, zone, date)
                zone_results[zone] = (success=true, generator_count=length(gens), failed_count=failures)
                println("  ✅ $zone: saved $(length(gens)) generators")
            catch e
                zone_results[zone] = (success=false, generator_count=0, failed_count=length(gens) + failures)
                println("  ❌ $zone: failed to save - $e")
            end
        else
            zone_results[zone] = (success=false, generator_count=0, failed_count=failures)
            if zone_generator_counts[zone] > 0
                println("  ❌ $zone: all $(zone_generator_counts[zone]) generators failed")
            end
        end
    end

    total_time = round(time() - start_time, digits=1)
    successful_zones = count(r -> r.success, values(zone_results))
    failed_zones = length(zones) - successful_zones

    println()
    println("="^50)
    println("📊 Inference Cache Refresh Complete")
    println("="^50)
    println("✅ Zones: $successful_zones/$(length(zones)) successful")
    println("✅ Generators: $successful_generators/$total_generators successful")
    println("❌ Failed generators: $failed_generators")
    println("⏱️  Total time: $(total_time)s")
    if parallel && length(workers()) > 1
        println("⚡ Throughput: $(round(total_generators / total_time, digits=1)) generators/sec")
    end

    return (
        successful_zones = successful_zones,
        failed_zones = failed_zones,
        total_generators = total_generators,
        successful_generators = successful_generators,
        failed_generators = failed_generators,
        total_time = total_time,
        zone_results = zone_results
    )
end

# ============================================================================
# Initial Conditions for Unit Commitment
# ============================================================================

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