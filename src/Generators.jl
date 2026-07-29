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
    normalize_fuel_type_name(fuel_type::AbstractString) -> String

Fold fuel-type spelling variants onto the canonical names used throughout
the codebase (FuelTypeParameters, FUEL_SRMC_BASE, flexible/variable type
lists). The canonical spelling is the one ENTSO-E actually publishes:
"Hydro Run-of-river and pondage" (uniform across all 34 zones in the DB).
The English-correct "poundage" appears only in older ENTSO-E documentation
and is folded back here defensively.
"""
function normalize_fuel_type_name(fuel_type::AbstractString)::String
    fuel_type == "Hydro Run-of-river and poundage" && return "Hydro Run-of-river and pondage"
    return String(fuel_type)
end

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
include("generators/fuel_costs.jl")           # TTF / EUA lookups and SRMC marginal-cost model
include("generators/registry.jl")             # day-level outage cache + get_generators (the unit registry query)
