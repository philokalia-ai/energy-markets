module Euphemia

using JuMP, HiGHS, Gurobi
using DataFrames, CSV
using DotEnv

using Dates

export calculate_market_clearing_price, commit_units  # Core functions
export MarketOrder, SimpleOrder, BlockOrder  # Order types
export Generator, Load, RenewablesGenerationForecast  # Entities
export get_generators, get_loads, get_generation_forecast_for_wind_and_solar  # Helper functions
export test_unit_commitment
export NetworkTopology, create_example_network, add_atc_constraints!  # Network constraints

include("dbutils.jl")

function __init__()
    DotEnv.load!(".")
    preinit_pool()
    @info "Initialization done"
end

include("MarketOrders.jl")
using .MarketOrders: MarketOrder, SimpleOrder, BlockOrder

include("Generators.jl")
include("FuelTypeParameters.jl")
include("Loads.jl")
include("Renewables.jl")

include("UnitCommitment.jl")

include("BiddingStrategy.jl")

include("Network.jl")
using .Network: NetworkTopology, create_example_network, add_atc_constraints!

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

    # Create network topology (you can replace this with real data later)
    network = create_example_network()

    # Decision Variables
    # FLOW variables for network flows [line, time_period]
    @variable(model, FLOW[l in network.lines, t in network.time_periods])

    # Add ATC constraints from Network module
    add_atc_constraints!(model, network, FLOW)

    # EUPHEMIA master problem (Economic Surplus Maximization) as described in Annex C1
    @objective(
        model,
        Max,
        # Term 1: Step Orders contribution
        -sum(ACCEPT[z, t, s, o] * q[z, t, s, o] * p[z, t, s, o] * res(o)
             for z in Z, t in T[z], s in S, o in step_orders[z, t, s])

        # Term 2: Interpolated Orders contribution  
        -
        sum(ACCEPT[z, t, s, o] * q[z, t, s, o] *
            (p[z, t, s, o] + ACCEPT[z, t, s, o] * (p1[z, t, s, o] - p[z, t, s, o]) / 2) * res(o)
            for z in Z, t in T[z], s in S, o in interpolated_orders[z, t, s])

        # Term 3: Block Orders contribution
        -
        sum(ACCEPT[bo] * q[bo, t] * p[bo] * res(o)
            for bo in block_orders, t in T_bo[bo])

        # Term 4: Complex Orders contribution
        -
        sum(ACCEPT[z, co, t, o] * q[z, co, t, o] * p[z, co, t, o] * res(co)
            for z in Z, co in complex_orders[z], t in T[z], o in suborders[z, co, t])

        # Term 5: Scalable Complex Orders contribution
        -
        sum(ACCEPT[z, sco, t, o] * q[z, sco, t, o] * p[z, sco, t, o] * res(sco)
            for z in Z, sco in scalable_complex_orders[z], t in T[z], o in suborders[z, sco, t])
        -
        sum(sign(type(sco)) * FixedTerm[sco] * B_ACCEPT[sco]
            for sco in scalable_complex_orders)

        # Term 6: Merit Orders contribution
        -
        sum(ACCEPT[mo] * q[mo] * p[mo] * res(mo)
            for mo in merit_orders)

        # Term 7: Tariffs impact
        # Note: Annex C1 uses 'u' in formula, Annex C5 defines 'uu' - documentation inconsistency
        -
        sum(Tariff[l, t] * FLOW[l, u, t]
            for l in lines, u in [0, 1], t in time_periods)

        # Term 8: Price-taking hourly orders curtailment minimization
        -
        M * sum(MAX_CURTAILMENT_RATIO[z, t, o]
                for z in Z, t in T[z], o in price_taking_hourly_orders[z, t])
    )

    # Solve the model
    optimize!(model)
end
end