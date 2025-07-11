struct Generator
    name::String
    fuel_type::Symbol
    p_max::Float64
    p_min::Float64
    bidding_zone::String
    marginal_cost::Float64
end

# Define your dummy values
const DUMMY_FUEL_TYPE = :UNKNOWN # Or :THERMAL, :RENEWABLE, etc. based on context
const DUMMY_BIDDING_ZONE = "GR_DEFAULT"
const DUMMY_MARGINAL_COST = 999.9 # A clearly identifiable dummy value


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
            row.generating_unit,           # Maps to 'name'
            DUMMY_FUEL_TYPE,               # Dummy value for fuel_type
            Float64(row.p_max),            # Convert Int64 to Float64 for p_max
            Float64(row.p_min),            # Convert Int64 to Float64 for p_min
            DUMMY_BIDDING_ZONE,            # Dummy value for bidding_zone
            DUMMY_MARGINAL_COST            # Dummy value for marginal_cost
        ) for row in eachrow(units)]

    return generators
end

# pull from postgres, for now only active units of given date (I think)
function get_generators(day::Dates.Date)
    # TODO: fetch all for now, will choose to keep what needed later 
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
        map_code,
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
        AND area_type_code = 'BZN'
        AND map_code = 'GR'
        AND DATE('$day') 
            BETWEEN DATE(valid_from) 
            AND COALESCE(
                    DATE(valid_to), 
                    DATE('9999-12-31')
                )

    """

    df = Euphemia.sql2df(query)
    return [
        Generator(
        # Stuff
        ) for row in eachrow(df)
    ]
end