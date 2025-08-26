module MPCC

using JuMP, Dates, DataFrames, CSV, DotEnv
using JuMP: AffExpr

# Import solvers with error handling
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

# Import required modules from parent Euphemia package
import ..Euphemia.MarketOrders: MarketOrder, SimpleOrder, AggregatedPeriodicOrder
import ..Euphemia.Network: NetworkTopology
import ..Euphemia: get_loads, get_generators, get_generation_forecast_for_wind_and_solar
import ..Euphemia.BiddingStrategy: generate_market_orders_from_uc, UCToBidsResult

# Export main functions
export MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, create_typed_order_book, select_solver

# Result structure
struct MPCCResult
    status::Symbol
    objective_value::Float64
    market_prices::Dict{String,Dict{String,Float64}}
    stepwise_acceptance::Dict{String,Float64}
    block_acceptance::Dict{String,Float64}
    block_activation::Dict{String,Float64}
    transmission_flows::Dict{String,Dict{String,Float64}}
    solve_time::Float64
    solver_name::String
    message::String
end

# Typed order book structure using existing MarketOrder types
struct MPCCOrderBook
    orders::Vector{MarketOrder}                # All market orders using existing types
    nodes::Vector{String}                      # Bidding zone identifiers  
    periods::Vector{String}                    # Time period identifiers (e.g., "1", "2", ..., "24")
    price_limits::Tuple{Float64,Float64}       # (min_price, max_price) bounds
    network_topology::Union{Nothing,NetworkTopology}  # Optional network constraints
end

# Configuration constants
const DEFAULT_MARKUP_FACTOR = 1.1
const BIG_M_PARAMETER = 4000000.0


"""
    select_solver(preferred_solver::String="auto")

Automatically selects the best available optimization solver for MPCC problems.
Returns the optimizer constructor for use with JuMP.

# Arguments
- `preferred_solver::String`: "auto" (default), "highs", "gurobi", or "cplex"

# Returns
- Optimizer constructor function
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
        [("HiGHS", HiGHS.Optimizer)] + filter(x -> x[1] != "HiGHS", available_solvers)
    elseif lowercase(preferred_solver) == "gurobi" && GUROBI_AVAILABLE
        [("Gurobi", Gurobi.Optimizer)] + filter(x -> x[1] != "Gurobi", available_solvers)
    elseif lowercase(preferred_solver) == "cplex" && CPLEX_AVAILABLE
        [("CPLEX", CPLEX.Optimizer)] + filter(x -> x[1] != "CPLEX", available_solvers)
    elseif preferred_solver != "auto"
        @warn "Preferred solver '$preferred_solver' not available. Using auto-selection."
        available_solvers
    else
        available_solvers
    end

    # Try solvers in order
    for (solver_name, optimizer) in solvers_to_try
        try
            # Test if solver is functional by creating a test model
            _ = Model(optimizer)
            return (optimizer, solver_name)
        catch e
            @warn "$solver_name failed to initialize: $(typeof(e))"
        end
    end

    error("All available solvers failed to initialize!")
end


"""
    create_typed_order_book(bidding_zone::String, day::Date; markup_factor::Float64=DEFAULT_MARKUP_FACTOR)

Creates a typed market order book from Unit Commitment results using existing MarketOrder types.

# Arguments
- `bidding_zone::String`: Target bidding zone (e.g., "GR")  
- `day::Date`: Day for which to create the order book
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1 = 10% markup)

# Returns  
- `MPCCOrderBook`: Typed order book structure using existing MarketOrder types
"""
function create_typed_order_book(bidding_zone::String, day::Date; markup_factor::Float64=DEFAULT_MARKUP_FACTOR)
    try
        # Generate market orders from real unit commitment
        uc_to_bids = generate_market_orders_from_uc(bidding_zone, day; markup_factor=markup_factor)
        
        if !uc_to_bids.success
            error("Failed to generate market orders: $(uc_to_bids.message)")
        end

        # Create typed order book using existing SimpleOrder types
        all_orders = Vector{MarketOrder}()
        
        # Add all supply orders (already SimpleOrder types)
        append!(all_orders, uc_to_bids.supply_orders)
        
        # Add all demand orders (already SimpleOrder types) 
        append!(all_orders, uc_to_bids.demand_orders)
        
        # Create the typed order book
        return MPCCOrderBook(
            all_orders,                                    # All orders as MarketOrder types
            [bidding_zone],                               # Single bidding zone
            [string(h) for h in 1:24],                   # 24 hourly periods
            (0.0, 500.0),                                 # Price limits (€/MWh)
            nothing                                       # No network topology for single zone
        )
        
    catch e
        error("Failed to create typed order book from UC: $e")
    end
end


"""
    solve_mpcc_market_clearing(order_book::MPCCOrderBook; 
                              preferred_solver::String="auto", 
                              silent::Bool=true,
                              big_m::Float64=BIG_M_PARAMETER)

Solves the MPCC-based market clearing problem using typed order book structure.

# Arguments
- `order_book::MPCCOrderBook`: Typed market order book structure
- `preferred_solver::String`: Preferred solver ("auto", "highs", "gurobi", or "cplex")
- `silent::Bool`: Whether to suppress solver output
- `big_m::Float64`: Big-M parameter for complementarity constraints

# Returns
- `MPCCResult`: Market clearing results including prices and order acceptance
"""
function solve_mpcc_market_clearing(order_book::MPCCOrderBook; 
                                   preferred_solver::String="auto", 
                                   silent::Bool=true,
                                   big_m::Float64=BIG_M_PARAMETER)
    
    # Analyze orders by type - currently we only handle SimpleOrder types from UC conversion
    simple_orders = filter(o -> isa(o, SimpleOrder), order_book.orders)
    
    # Create order mappings for efficient access
    orders_by_node = Dict{String,Dict{String,Vector{SimpleOrder}}}()
    for node_id in order_book.nodes
        orders_by_node[node_id] = Dict{String,Vector{SimpleOrder}}()
        for time_period in order_book.periods
            orders_by_node[node_id][time_period] = SimpleOrder[]
        end
    end
    
    # Group orders by node and time period
    for order in simple_orders
        node_id = string(order.zone)
        hour_of_day = Dates.hour(order.date_time) + 1  # Convert 0-23 to 1-24
        time_period = string(hour_of_day)
        
        if haskey(orders_by_node, node_id) && haskey(orders_by_node[node_id], time_period)
            push!(orders_by_node[node_id][time_period], order)
        end
    end
    
    # Create and configure model
    optimizer, solver_name = select_solver(preferred_solver)
    model = Model(optimizer)
    
    if silent
        set_silent(model)
    end

    start_time = time()
    
    try
        # Create unique indices for orders - use a unique string ID based on order properties
        order_indices = Dict{SimpleOrder,String}()
        order_ids = String[]
        
        for (i, order) in enumerate(simple_orders)
            # Create a unique ID based on order properties and index
            unique_id = "order_$(i)_$(string(order.zone))_$(Dates.hour(order.date_time))_$(round(Int, order.quantity))_$(round(Int, order.price))"
            order_indices[order] = unique_id
            push!(order_ids, unique_id)
        end
        
        # Decision Variables
        @variable(model, 0 <= stepwise_acceptance[order_id in order_ids])
        @variable(model, 0 <= stepwise_dual[order_id in order_ids])
        
        # Load shedding variables for market robustness (high penalty cost)
        @variable(model, load_shed[node_id in order_book.nodes, time_period in order_book.periods] >= 0)
        
        @variable(model, market_price[node_id in order_book.nodes, time_period in order_book.periods])
        
        # Stepwise order constraints
        @constraint(model, stepwise_upper_bound[order_id in order_ids],
            stepwise_acceptance[order_id] <= 1
        )
        
        # Create expressions for stepwise dual constraints - match dictionary formulation exactly
        stepwise_dual_rhs = Dict{String,AffExpr}()
        for (i, order) in enumerate(simple_orders)
            order_id = order_ids[i]
            node_id = string(order.zone)
            hour_of_day = Dates.hour(order.date_time) + 1
            time_period = string(hour_of_day)
            
            # Determine quantity sign: negative for supply, positive for demand
            quantity = order.type == :supply ? -order.quantity : order.quantity
            
            # Match dictionary formulation: sum over time periods (but SimpleOrder only has one period)
            # This should be equivalent since SimpleOrder represents single period
            stepwise_dual_rhs[order_id] = @expression(model,
                stepwise_dual[order_id] +
                quantity * market_price[node_id, time_period] -
                quantity * order.price
            )
        end
        
        @constraint(model, stepwise_dual_constraint[order_id in order_ids],
            0 <= stepwise_dual_rhs[order_id]
        )
        
        # Precompute mapping from (node_id, time_period) to relevant order indices
        orders_by_node_time = Dict{Tuple{String, String}, Vector{Int}}()
        for (i, order) in enumerate(simple_orders)
            node = string(order.zone)
            period = string(Dates.hour(order.date_time) + 1)
            key = (node, period)
            if haskey(orders_by_node_time, key)
                push!(orders_by_node_time[key], i)
            else
                orders_by_node_time[key] = [i]
            end
        end

        # Power balance constraints (single node case - no transmission flows)
        @constraint(model, nodal_power_balance[node_id in order_book.nodes, time_period in order_book.periods],
            sum(
                stepwise_acceptance[order_ids[i]] *
                (simple_orders[i].type == :supply ? -simple_orders[i].quantity : simple_orders[i].quantity)
                for i in get(orders_by_node_time, (node_id, time_period), Int[])
            ) + 
            load_shed[node_id, time_period] == 0
        )
        
        # Complementarity constraints using Big-M reformulation
        @variable(model, stepwise_acceptance_complementarity_aux[order_id in order_ids], Bin)
        @constraint(model, stepwise_acceptance_complementarity_ineq1[order_id in order_ids], 
            stepwise_acceptance[order_id] <= stepwise_acceptance_complementarity_aux[order_id] * big_m)
        @constraint(model, stepwise_acceptance_complementarity_ineq2[order_id in order_ids], 
            stepwise_dual_rhs[order_id] <= (1 - stepwise_acceptance_complementarity_aux[order_id]) * big_m)
        
        # Price range constraints
        @constraint(model, minimum_price[node_id in order_book.nodes, time_period in order_book.periods], 
            market_price[node_id, time_period] >= order_book.price_limits[1])
        @constraint(model, maximum_price[node_id in order_book.nodes, time_period in order_book.periods], 
            market_price[node_id, time_period] <= order_book.price_limits[2])
        
        # Objective function - match dictionary formulation exactly
        # Dictionary version: stepwise_acceptance[order_id] * (sum of quantities) * price
        # Need to use signed quantities: negative for supply, positive for demand
        load_shed_penalty = 10000.0  # High penalty for load shedding (€/MWh)
        @objective(model, Max,
            sum(stepwise_acceptance[order_ids[i]] * 
                (order.type == :supply ? -order.quantity : order.quantity) * order.price 
                for (i, order) in enumerate(simple_orders)) -
            load_shed_penalty * sum(load_shed[node_id, time_period] 
                for node_id in order_book.nodes, time_period in order_book.periods)
        )
        
        # Solve the model
        optimize!(model)
        solve_time = time() - start_time
        
        # Extract results
        if has_values(model)
            market_prices = Dict{String,Dict{String,Float64}}()
            for node_id in order_book.nodes
                market_prices[node_id] = Dict{String,Float64}()
                for time_period in order_book.periods
                    market_prices[node_id][time_period] = value(market_price[node_id, time_period])
                end
            end
            
            stepwise_acceptance_values = Dict{String,Float64}()
            for (i, order) in enumerate(simple_orders)
                order_id = order_ids[i]
                stepwise_acceptance_values[order_id] = value(stepwise_acceptance[order_id])
            end
            
            # Convert JuMP termination status to our expected Symbol
            status_symbol = if string(termination_status(model)) == "OPTIMAL"
                :optimal
            elseif string(termination_status(model)) == "INFEASIBLE"
                :infeasible
            elseif string(termination_status(model)) == "UNBOUNDED"
                :unbounded
            elseif string(termination_status(model)) == "TIME_LIMIT"
                :time_limit
            else
                :error
            end
            
            return MPCCResult(
                status_symbol,
                objective_value(model),
                market_prices,
                stepwise_acceptance_values,
                Dict{String,Float64}(),  # Empty block acceptance
                Dict{String,Float64}(),  # Empty block activation
                Dict{String,Dict{String,Float64}}(),  # Empty transmission flows
                solve_time,
                solver_name,
                string(termination_status(model))
            )
        else
            return MPCCResult(
                termination_status(model),
                0.0,
                Dict{String,Dict{String,Float64}}(),
                Dict{String,Float64}(),
                Dict{String,Float64}(),
                Dict{String,Float64}(),
                Dict{String,Dict{String,Float64}}(),
                solve_time,
                solver_name,
                "No solution available: $(termination_status(model))"
            )
        end
        
    catch e
        solve_time = time() - start_time
        return MPCCResult(
            :error,
            0.0,
            Dict{String,Dict{String,Float64}}(),
            Dict{String,Float64}(),
            Dict{String,Float64}(),
            Dict{String,Float64}(),
            Dict{String,Dict{String,Float64}}(),
            solve_time,
            solver_name,
            "Optimization failed: $e"
        )
    end
end

end  # module MPCC