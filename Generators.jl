function get_generators()
    units = DataFrame(CSV.File("mpm-lab/" * "generating_units.csv"))  
end