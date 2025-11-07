module Euphemia

# Core dependencies
using JuMP
using DataFrames, CSV
using DotEnv
using Dates

# Import optimization solvers with error handling
try
    using HiGHS
    global HIGHS_AVAILABLE = true
catch
    global HIGHS_AVAILABLE = false
end

try
    using Gurobi
    global GUROBI_AVAILABLE = true
catch
    global GUROBI_AVAILABLE = false
end

try
    using CPLEX
    global CPLEX_AVAILABLE = true
catch
    global CPLEX_AVAILABLE = false
end

include("dbutils.jl")

function __init__()
    DotEnv.load!(".")
    preinit_pool()
    @info "Initialization done"
end

"""
    select_solver(preferred_solver::String="auto")

Automatically selects the best available optimization solver for energy market problems.
Returns the optimizer constructor for use with JuMP.

# Arguments
- `preferred_solver::String`: "auto" (default), "highs", "gurobi", or "cplex"

# Returns
- Tuple of (optimizer_constructor, solver_name)

# Examples
```julia
optimizer, name = select_solver("highs")
model = Model(optimizer)
```
"""
function select_solver(preferred_solver::String="auto")
    available_solvers = []

    # Check which solvers are available
    if HIGHS_AVAILABLE
        push!(available_solvers, ("HiGHS", HiGHS.Optimizer))
    end
    if GUROBI_AVAILABLE
        push!(available_solvers, ("Gurobi", Gurobi.Optimizer))
    end
    if CPLEX_AVAILABLE
        push!(available_solvers, ("CPLEX", CPLEX.Optimizer))
    end

    if isempty(available_solvers)
        error("No solvers available! Please install at least one of: HiGHS.jl (recommended), Gurobi.jl, or CPLEX.jl")
    end

    # Determine priority order based on preference
    solvers_to_try = if preferred_solver == "auto"
        available_solvers
    elseif lowercase(preferred_solver) == "highs" && HIGHS_AVAILABLE
        vcat([("HiGHS", HiGHS.Optimizer)], filter(x -> x[1] != "HiGHS", available_solvers))
    elseif lowercase(preferred_solver) == "gurobi" && GUROBI_AVAILABLE
        vcat([("Gurobi", Gurobi.Optimizer)], filter(x -> x[1] != "Gurobi", available_solvers))
    elseif lowercase(preferred_solver) == "cplex" && CPLEX_AVAILABLE
        vcat([("CPLEX", CPLEX.Optimizer)], filter(x -> x[1] != "CPLEX", available_solvers))
    elseif preferred_solver != "auto"
        @warn "Preferred solver '$preferred_solver' not available. Using auto-selection."
        available_solvers
    else
        available_solvers
    end

    # Try solvers in order
    for (i, (solver_name, optimizer)) in enumerate(solvers_to_try)
        try
            # Test if solver is functional by creating a test model
            _ = Model(optimizer)

            # If this isn't the first solver tried, announce the successful fallback
            if i > 1
                @info "✅ Using $solver_name solver as fallback"
            end

            return (optimizer, solver_name)
        catch e
            @warn "$solver_name failed to initialize: $(typeof(e))"
        end
    end

    error("All available solvers failed to initialize!")
end

include("MarketOrders.jl")
using .MarketOrders: MarketOrder, SimpleOrder, BlockOrder, LinkedBlockOrder, ExclusiveBlockOrder,
    FlexibleOrder, AggregatedPeriodicOrder, MICOrder, LoadGradientOrder, MeritOrder, PUNOrder

include("Generators.jl")
include("FuelTypeParameters.jl")
include("Loads.jl")
include("Renewables.jl")

include("TemporalResolutionUtilities.jl")

include("UnitCommitment.jl")

include("BiddingStrategy.jl")
using .BiddingStrategy: generate_market_orders_from_uc, apply_bidding_strategy_to_uc, UCToBidsResult

include("Network.jl")
using .Network: NetworkTopology, create_example_network, add_atc_constraints!
using .Network: TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!, create_example_transfer_capacity
using .Network: create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
using .Network: get_bidding_zones, get_outgoing_lines, get_incoming_lines, create_greek_transfer_capacity_from_entsoe

include("MPCC.jl")
using .MPCC: MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, create_typed_order_book, select_solver

include("AlternativeOrderBook.jl")
using .AlternativeOrderBook: create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary

# ===== EXPORTS =====
# All module exports are centralized here following Julia best practices
# Exports come after includes so all symbols are defined before being exported

# Core market clearing functionality
export calculate_market_clearing_price, commit_units

# Market order types and utilities
export MarketOrder, SimpleOrder, BlockOrder
export LinkedBlockOrder, ExclusiveBlockOrder, FlexibleOrder, AggregatedPeriodicOrder
export MICOrder, LoadGradientOrder, MeritOrder, PUNOrder

# Entity types
export Generator, Load, RenewablesGenerationForecast

# Helper functions for data retrieval
export get_generators, get_loads, get_generation_forecast_for_wind_and_solar

# Unit commitment functionality
export test_unit_commitment, calculate_cost_breakdown, solve_unit_commitment

# Network topology and transfer capacity
export NetworkTopology, create_example_network, add_atc_constraints!  # Network constraints (legacy)
export TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!
export create_example_transfer_capacity, create_greek_transfer_capacity_from_entsoe
export create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
export get_bidding_zones, get_outgoing_lines, get_incoming_lines

# MPCC optimization functionality
export MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, create_typed_order_book, select_solver

# Alternative order book functionality
export create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary

# Bidding strategy functionality
export generate_market_orders_from_uc, apply_bidding_strategy_to_uc, UCToBidsResult

# Fuel type parameters
export FuelTypeParameters, get_fuel_type_parameters, apply_fuel_type_constraints!

# Temporal resolution utilities
export parse_resolution_to_minutes, determine_finest_resolution, generate_sub_slots_from_source, disaggregate_temporal_data

# Market clearing with ENTSO-E integration
export euphemia_market_clearing_with_entsoe

# Energy price generation (unified interface)
export generate_energy_prices

# Database utilities
export save_energy_prices, ensure_energy_prices_table, withdb, save_optimization_run

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

"""
    generate_energy_prices(bidding_zone::String, date::Date; 
                          order_method::Symbol=:uc_based, 
                          model::Symbol=:mpcc,
                          optimizer::String="highs",
                          markup_factor::Float64=1.1,
                          random_seed::Union{Int,Nothing}=nothing,
                          silent::Bool=true)

Unified function to generate energy prices for a bidding zone on a specific date through market clearing optimization.
Supports both hourly and sub-hourly temporal resolutions depending on the order method used.

# Arguments
- `bidding_zone::String`: The bidding zone code (e.g., "GR", "DE", "FR")
- `date::Date`: The date for which to generate prices
- `order_method::Symbol`: Method for creating orders - `:uc_based` or `:alternative`
  - `:uc_based`: Creates orders preserving Unit Commitment's native temporal resolution (15/30/60 minutes)
  - `:alternative`: Creates orders at finest available resolution (15/30/60 minutes) from real load/renewable data
- `model::Symbol`: Market clearing model - `:mpcc` (more models may be added later)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
- `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
- `silent::Bool`: Whether to suppress solver output (default: true)

# Returns
- `Dict{String,Float64}`: Dictionary mapping time periods to energy price (€/MWh)
  - Keys are timeslots in format "YYYYMMDD-HHMM" (e.g., "20240618-0000", "20240618-0015")
  - Both `:uc_based` and `:alternative` methods use consistent timeslot formatting
  Returns empty dict if any step fails.

# Temporal Resolution
The output resolution depends on the order method and underlying data resolution:
- **UC-based**: Preserves the native resolution from load/renewable data (15/30/60 minutes)
- **Alternative**: Automatically detects finest resolution from load/renewable data:
  - 15-minute data → 96 periods per day
  - 30-minute data → 48 periods per day  
  - 60-minute data → 24 periods per day

Both methods now support sub-hourly resolution and will automatically use the finest temporal 
resolution available in the underlying load and renewable generation data.

# Examples
```julia
# Generate prices using UC-based orders (hourly or sub-hourly depending on data)
prices = generate_energy_prices("GR", Date(2025, 7, 24))
println("Noon price: €\$(prices["20250724-1200"])/MWh")

# Generate prices using alternative order book (auto-detects temporal resolution)
prices_alternative = generate_energy_prices("AL", Date(2024, 6, 18); order_method=:alternative)
println("Number of price periods: \$(length(prices_alternative))")  # Could be 24, 48, or 96 depending on data

# Access specific time periods by timeslot
if haskey(prices_alternative, "20240618-1200")
    println("Noon price: €\$(prices_alternative["20240618-1200"])/MWh")
end

# Convert to vectors for analysis
price_values = collect(values(prices))
avg_price = sum(price_values) / length(price_values)
```
"""
function generate_energy_prices(bidding_zone::String, date::Date;
    order_method::Symbol=:uc_based,
    model::Symbol=:mpcc,
    optimizer::String="highs",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=false)

    # Validate inputs
    if !(order_method in [:uc_based, :alternative])
        error("Invalid order_method: $order_method. Must be :uc_based or :alternative")
    end

    if !(model in [:mpcc])
        error("Invalid model: $model. Currently only :mpcc is supported")
    end

    try
        println("🔄 Generating energy prices for $bidding_zone on $date")
        println("   📋 Order method: $order_method")
        println("   ⚖️  Model: $model")

        # Step 1: Create Order Book
        println("\n📋 Step 1: Creating Order Book...")
        order_book = nothing

        if order_method == :uc_based
            println("   Using UC-based order creation")
            order_book = create_typed_order_book(bidding_zone, date; markup_factor=markup_factor, optimizer=optimizer)

        elseif order_method == :alternative
            println("   Using alternative order book creation")
            order_book_result = create_adjusted_order_book(
                bidding_zone,
                date;
                random_seed=random_seed
            )

            if !order_book_result.success
                error("Alternative order book creation failed: $(order_book_result.message)")
            end

            order_book = order_book_result.order_book
        end

        if order_book === nothing
            error("Failed to create order book")
        end

        println("   ✅ Order book created with $(length(order_book.orders)) orders")

        # Step 2: Run Market Clearing Model  
        println("\n⚖️  Step 2: Running Market Clearing ($model with $optimizer)...")

        if model == :mpcc
            optimization_start_time = time()

            try
                mpcc_result = solve_mpcc_market_clearing(order_book; preferred_solver=optimizer, silent=silent)
                solve_time_seconds = time() - optimization_start_time

                if mpcc_result.status != :optimal
                    # Save failed optimization run
                    save_optimization_run(bidding_zone, date, order_method, model, optimizer, mpcc_result.status;
                        solve_time_seconds=solve_time_seconds,
                        num_orders=length(order_book.orders),
                        error_message="MPCC optimization failed with status: $(mpcc_result.status)")

                    error("MPCC optimization failed with status: $(mpcc_result.status)")
                end

                println("   ✅ MPCC optimization successful")
                println("   📊 Objective value: $(round(mpcc_result.objective_value, digits=2))")

                # Step 3: Extract Energy Prices
                println("\n💰 Step 3: Extracting Energy Prices...")

                if isempty(mpcc_result.market_prices)
                    # Save failed optimization run (successful solve but no prices)
                    save_optimization_run(bidding_zone, date, order_method, model, optimizer, :no_prices;
                        objective_value=mpcc_result.objective_value,
                        solve_time_seconds=solve_time_seconds,
                        num_orders=length(order_book.orders),
                        error_message="No market prices found in MPCC result")

                    error("No market prices found in MPCC result")
                end

                # Get prices for the bidding zone
                if !haskey(mpcc_result.market_prices, bidding_zone)
                    # Save failed optimization run (successful solve but no prices for zone)
                    save_optimization_run(bidding_zone, date, order_method, model, optimizer, :no_zone_prices;
                        objective_value=mpcc_result.objective_value,
                        solve_time_seconds=solve_time_seconds,
                        num_orders=length(order_book.orders),
                        error_message="No prices found for bidding zone: $bidding_zone")

                    error("No prices found for bidding zone: $bidding_zone")
                end

                prices = mpcc_result.market_prices[bidding_zone]

                println("   ✅ Energy prices extracted for $(length(prices)) time periods")
                println("   📈 Price range: €$(round(minimum(values(prices)), digits=2)) - €$(round(maximum(values(prices)), digits=2))/MWh")

                # Save successful optimization run
                save_optimization_run(bidding_zone, date, order_method, model, optimizer, :optimal;
                    objective_value=mpcc_result.objective_value,
                    solve_time_seconds=solve_time_seconds,
                    num_orders=length(order_book.orders),
                    num_price_periods=length(prices))

                # Save energy prices to database if requested
                if save_to_db
                    try
                        println("   💾 Saving $(length(prices)) price records to database...")
                        records_saved = save_energy_prices(prices, bidding_zone, date, order_method)
                        println("   ✅ Successfully saved $records_saved records to database")
                    catch db_error
                        println("   ⚠️  Warning: Failed to save prices to database: $db_error")
                    end
                end

                return prices

            catch mpcc_error
                solve_time_seconds = time() - optimization_start_time

                # Save failed optimization run with error details
                save_optimization_run(bidding_zone, date, order_method, model, optimizer, :error;
                    solve_time_seconds=solve_time_seconds,
                    num_orders=length(order_book.orders),
                    error_message=string(mpcc_error))

                rethrow(mpcc_error)
            end

        else
            error("Model $model not implemented yet")
        end

    catch e
        println("❌ Error generating energy prices: $e")
        return Dict{String,Float64}()
    end
end

end