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
export NetworkTopology, create_example_network, add_atc_constraints!  # Network constraints (legacy)
export TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!  # Transfer capacity constraints
export create_example_transfer_capacity, create_greek_transfer_capacity_from_entsoe, euphemia_market_clearing_with_entsoe
export MPCCResult, solve_mpcc_market_clearing, create_typed_order_book, select_solver  # MPCC functionality
export create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary  # Alternative order book
export calculate_cost_breakdown, solve_unit_commitment

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
using .Network: TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!, create_example_transfer_capacity

include("MPCC.jl")
using .MPCC: MPCCResult, solve_mpcc_market_clearing, create_typed_order_book, select_solver

include("AlternativeOrderBook.jl")
using .AlternativeOrderBook: create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary

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

    # Create transfer capacity structure (using real ENTSO-E data when available)
    transfer_capacity = create_example_transfer_capacity()
    
    # Extract bidding zones and time periods
    zones = transfer_capacity.bidding_zones
    time_periods = transfer_capacity.time_periods

    # Decision Variables
    # TRANSFER_FLOW variables for zone-to-zone transfers [source_zone, sink_zone, time_period]
    @variable(model, TRANSFER_FLOW[source in zones, sink in zones, t in time_periods; source != sink])

    # Add transfer capacity constraints from Network module
    add_transfer_capacity_constraints!(model, transfer_capacity, TRANSFER_FLOW)

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

        # Term 7: Tariffs impact (adapted for zone-to-zone transfers)
        # Note: Original formula uses line-based tariffs, adapted for zone transfers
        # TODO: Define zone-to-zone tariff structure
        # -
        # sum(Tariff[source, sink, t] * TRANSFER_FLOW[source, sink, t]
        #     for source in zones, sink in zones, t in time_periods if source != sink)

        # Term 8: Price-taking hourly orders curtailment minimization
        -
        M * sum(MAX_CURTAILMENT_RATIO[z, t, o]
                for z in Z, t in T[z], o in price_taking_hourly_orders[z, t])
    )

    # Solve the model
    optimize!(model)
end

"""
    euphemia_market_clearing_with_entsoe(date::Date, bidding_zones::Vector{String}=String[])

Market clearing using real ENTSO-E transfer capacity data for the specified date.

# Arguments
- `date::Date`: Date for which to retrieve ENTSO-E transfer capacities
- `bidding_zones::Vector{String}`: Optional filter for specific bidding zones

# Returns
- JuMP model with transfer capacity constraints from real ENTSO-E data
"""
function euphemia_market_clearing_with_entsoe(date::Date, bidding_zones::Vector{String}=String[])
    model = Model(HiGHS.Optimizer)

    # Create transfer capacity structure using real ENTSO-E data
    transfer_capacity = create_transfer_capacity_from_entsoe(date, bidding_zones)
    
    # Extract bidding zones and time periods
    zones = transfer_capacity.bidding_zones
    time_periods = transfer_capacity.time_periods

    # Decision Variables
    # TRANSFER_FLOW variables for zone-to-zone transfers [source_zone, sink_zone, time_period]
    @variable(model, TRANSFER_FLOW[source in zones, sink in zones, t in time_periods; source != sink])

    # Add transfer capacity constraints from real ENTSO-E data
    add_transfer_capacity_constraints!(model, transfer_capacity, TRANSFER_FLOW)

    println("✅ Created EUPHEMIA model with real ENTSO-E data:")
    println("   🌍 Bidding zones: $(length(zones)) ($(join(zones, ", ")))")
    println("   🕐 Time periods: $(length(time_periods))")
    println("   🔗 Transfer variables: $(length(zones) * (length(zones)-1) * length(time_periods))")

    # TODO: Add order processing and objective function (same as main function)
    # For now, return the model with transfer capacity constraints
    return model, transfer_capacity
end
end