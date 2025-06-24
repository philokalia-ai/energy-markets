using Euphemia

# Πρώτα όλοι, μετά αυτοί που περιμένουμε να βγαλουν δουλειά
generators::Vector{Generator} = get_generators()

loads::Vector{Load} = get_loads()

orders::Vector{MarketOrder} = commit_units(generators, loads)

## Do we need to add orders?
prices = calculate_market_clearing_price(orders)
