module MPCC

using JuMP, Dates, DataFrames
using JuMP: AffExpr

# Import shared solver selection from parent module
import ..select_solver

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
    extract_time_period(order_datetime::DateTime, order_book_periods::Vector{String})

Extracts the appropriate time period identifier for an order based on the order book's period structure.
Supports both hourly (1-24) and sub-hourly (timeslot strings) periods.
"""
function extract_time_period(order_datetime::DateTime, order_book_periods::Vector{String})
    # Check if periods are timeslot strings (sub-hourly) or simple numbers (hourly)
    if !isempty(order_book_periods)
        sample_period = order_book_periods[1]

        # If periods look like timeslot strings (e.g., "20180624-0015")
        if length(sample_period) > 5 && contains(sample_period, "-")
            # Format DateTime to match timeslot format: "YYYYMMDD-HHMM"
            date_str = Dates.format(order_datetime, "yyyymmdd")
            time_str = Dates.format(order_datetime, "HHMM")
            timeslot = "$(date_str)-$(time_str)"

            # Return the timeslot if it exists in periods, otherwise find closest match
            if timeslot in order_book_periods
                return timeslot
            else
                # Fallback: find the period with matching hour
                hour = Dates.hour(order_datetime)
                minute = Dates.minute(order_datetime)
                target_time = hour * 100 + minute

                for period in order_book_periods
                    if length(period) >= 13
                        period_hour = parse(Int, period[10:11])
                        period_min = parse(Int, period[12:13])
                        period_time = period_hour * 100 + period_min

                        if period_time >= target_time
                            return period
                        end
                    end
                end

                # Ultimate fallback: return first period of the day
                return order_book_periods[1]
            end
        else
            # Periods are simple hour numbers (1-24) - use original logic
            hour_of_day = Dates.hour(order_datetime) + 1  # Convert 0-23 to 1-24
            return string(hour_of_day)
        end
    else
        # Fallback for empty periods
        hour_of_day = Dates.hour(order_datetime) + 1
        return string(hour_of_day)
    end
end


"""
    create_typed_order_book(bidding_zone::String, day::Date; markup_factor::Float64=DEFAULT_MARKUP_FACTOR, optimizer::String="auto")

Creates a typed market order book from Unit Commitment results using existing MarketOrder types.
Preserves the native temporal resolution from Unit Commitment optimization (15/30/60 minutes).

# Arguments
- `bidding_zone::String`: Target bidding zone (e.g., "GR")  
- `day::Date`: Day for which to create the order book
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1 = 10% markup)
- `optimizer::String`: Solver preference for unit commitment ("auto", "highs", "gurobi", "cplex")

# Returns  
- `MPCCOrderBook`: Typed order book structure using existing MarketOrder types with native UC temporal resolution
"""
function create_typed_order_book(bidding_zone::String, day::Date; markup_factor::Float64=DEFAULT_MARKUP_FACTOR, optimizer::String="auto")
    try
        # Generate market orders from real unit commitment
        uc_to_bids = generate_market_orders_from_uc(bidding_zone, day; markup_factor=markup_factor, optimizer=optimizer)

        if !uc_to_bids.success
            error("Failed to generate market orders: $(uc_to_bids.message)")
        end

        # Create typed order book using existing SimpleOrder types
        all_orders = Vector{MarketOrder}()

        # Add all supply orders (already SimpleOrder types)
        append!(all_orders, uc_to_bids.supply_orders)

        # Add all demand orders (already SimpleOrder types) 
        append!(all_orders, uc_to_bids.demand_orders)

        # Extract unique time periods from the actual orders to preserve UC's native resolution
        time_periods = Set{String}()
        for order in all_orders
            if isa(order, SimpleOrder)
                # Format DateTime to timeslot string: "YYYYMMDD-HHMM"
                date_str = Dates.format(order.date_time, "yyyymmdd")
                time_str = Dates.format(order.date_time, "HHMM")
                timeslot = "$(date_str)-$(time_str)"
                push!(time_periods, timeslot)
            end
        end

        # Convert to sorted vector for consistent ordering
        periods_vector = sort(collect(time_periods))

        # Log the detected resolution
        if length(periods_vector) > 1
            println("   📊 Detected $(length(periods_vector)) time periods from UC orders")
            if length(periods_vector) == 24
                println("   ⏰ Resolution: Hourly (24 periods)")
            elseif length(periods_vector) == 48
                println("   ⏰ Resolution: 30-minute (48 periods)")
            elseif length(periods_vector) == 96
                println("   ⏰ Resolution: 15-minute (96 periods)")
            else
                println("   ⏰ Resolution: Custom ($(length(periods_vector)) periods)")
            end
        else
            # Fallback to hourly if no orders found
            periods_vector = [string(h) for h in 1:24]
            println("   ⚠️  No orders found, defaulting to 24 hourly periods")
        end

        # Create the typed order book with native UC resolution
        return MPCCOrderBook(
            all_orders,                                    # All orders as MarketOrder types
            [bidding_zone],                               # Single bidding zone
            periods_vector,                               # Preserve UC's native temporal resolution
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
        time_period = extract_time_period(order.date_time, order_book.periods)

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
            # Create a unique ID based on order properties and index, with explicit field labels to avoid ambiguity
            unique_id = "order_$(i)_z$(string(order.zone))_h$(Dates.hour(order.date_time))_q$(round(Int, order.quantity))_p$(round(Int, order.price))"
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
            time_period = extract_time_period(order.date_time, order_book.periods)

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
        orders_by_node_time = Dict{Tuple{String,String},Vector{Int}}()
        for (i, order) in enumerate(simple_orders)
            node = string(order.zone)
            # Use the extract_time_period function to get the correct period mapping
            period = extract_time_period(order.date_time, order_book.periods)
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