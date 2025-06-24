
struct Generator
    max_capacity::Float64
    fuel_type::Symbol
    name::String
    bidding_zone::String
    marginal_cost::Floa64
end

# TODO: Make get_generators return Vector{Generator}

# TODO: 1o pass: static list
# TODO: 2o pass: with renewables somehow

function get_generators(source::Bool=nothing)
    if source == true
        units = DataFrame(CSV.File(joinpath(@__DIR__, ".. ", "data", "productionunit_202406181240.csv")))
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
        units = DataFrame(CSV.File(joinpath(@__DIR__, ".. ", "mpm-lab/" * "generating_units.csv")))
    end
    return units
end