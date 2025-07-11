using Euphemia

# Πρώτα όλοι, μετά αυτοί που περιμένουμε να βγαλουν δουλειά
generators::Vector{Generator} = get_generators()

loads::Vector{Load} = get_loads()

orders::Vector{MarketOrder} = commit_units(generators, loads)

# Do we need to add orders?
prices = calculate_market_clearing_price(orders)

println("hello")

using Dates

loads::Vector{Load} = get_loads("GR", Date("2025-06-24"))

for load in loads
    println(load)
end

generators::Vector{Generator} = get_generators(Date("2025-06-24"))

for generator in generators
    println(generator)
end