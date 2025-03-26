using DataFrames, CSV

function create_orders(
    infer=false
)
    if infer == false
        orders = DataFrame(CSV.File("mpm-lab/" * "generating_units_orders.csv"))
    end
    return orders
end
