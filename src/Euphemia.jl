module Euphemia

using JuMP, HiGHS, Gurobi
export calculate_market_clearing_price, commit_units  # Core functions

export MarketOrder, SimpleOrder, BlockOrder  # Order types
export Generator, Load  # Entities
export get_generators, get_loads  # Helper functions

include("MarketOrders.jl")
using .MarketOrders: MarketOrder, SimpleOrder, BlockOrder

include("Generators.jl")

# Αυτή η συνάρτηση πρέπει να διαβάζει τα market orders
# και να υπολογίζει το clearing price για timeslot για bidding zone
function calculate_market_clearing_price() end

# 
function commit_units() end

# Σε τι τιμή θα παράξουν τα accepted generators
function commit_units(generators::Vector{Generator}, load::Vector{Load})
    # TODO: να βγάζουμε ένα ενδιάμεσο vector με τα οριακά κόστη, ώστε 
    # να μπορούμε να πιάνουμε την στρατηγική του κάθε παίκτη
    # αντιπροσωπεύει την ελάχιστη τιμή που θα δώσουν αυτοί
    return Vector{MarketOrder}()
end

function calculate_market_clearing_price(market_orders::Vector{MarketOrder})::Array{Tuple{String,String,Float64}}
    return [
        ("Bidding Zone", "20252406T20:15:11", 5.0)
    ]
end

# Objective: Global Economic surplus Maximization
# https://www.nordpoolgroup.com/globalassets/download-center/single-day-ahead-coupling/euphemia-public-description.pdf Annex C1 - p72

function make_model()

    # Define the model
    model = Model(HiGHS.Optimizer)

    @objective(
        model,
        Max,
        -sum(step_orders.ACCEPT[z, t, s, o] * step_orders.q[z, t, s, o] * step_orders.p_0[z, t, s, o] * res(o)
             for z in 1:2, t in 1:2, s in 1:2, o in 1:2)
        -
        sum(interpolated_orders.ACCEPT[z, t, s, o] * interpolated_orders.q[z, t, s, o] * (interpolated_orders.p_0[z, t, s, o] + interpolated_orders.ACCEPT[z, t, s, o] * (interpolated_orders.p_1[z, t, s, o] - interpolated_orders.p_0) / 2) * res(o) for z in 1:2, t in 1:2, s in 1:2, o in 1:2)
        -
        sum()
    )

    # Solve the model
    optimize!(model)
end
end