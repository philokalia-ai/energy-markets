function get_generators(source::Bool = nothing)
    if source == true
        units = DataFrame(CSV.File("data/" * "productionunit_202406181240.csv"))
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
        units = DataFrame(CSV.File("mpm-lab/" * "generating_units.csv"))
    end
    return units
end