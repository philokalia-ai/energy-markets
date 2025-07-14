struct Generator
    code::String
    name::String
    fuel_type::Symbol
    location::String
    p_max::Float64
    p_min::Float64
    bidding_zone::String
    marginal_cost::Float64
end

# Define your dummy values
const DUMMY_CODE = "GEN-0000"
const DUMMY_LOCATION = "Unknown Location"  # Placeholder for location
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


function get_marginal_cost(day::Dates.Date, fuel_type::String, bidding_zone::String = "GR")
    # Placeholder function to fetch marginal costs
    # This should be implemented based on your data source
    return 50.0  # Example fixed value, replace with actual logic
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
        AND area_type_code IN  ('BZN', 'BZN/CTA')
        AND map_code = 'GR'
        AND DATE('$day') 
            BETWEEN DATE(valid_from) 
            AND COALESCE(
                    DATE(valid_to), 
                    DATE('$day') + INTERVAL '1 year'
                )

    """

    df = Euphemia.sql2df(query)
    return [
        Generator(
            row.generation_unit_code,                    # code
            row.generation_unit_name,                    # name
            Symbol(row.generation_unit_type),            # fuel_type (convert to Symbol)
            row.generation_unit_location,                # location
            Float64(row.generation_unit_installed_capacity_mw), # p_max
            get_min_active_capacity(
                Float64(row.generation_unit_installed_capacity_mw)
            ), # p_min
            row.map_code,                                # bidding_zone
            get_marginal_cost(
                day, 
                row.generation_unit_type,  
                row.area_display_name
            )                                           # marginal_cost
        ) for row in eachrow(df)
    ]
end