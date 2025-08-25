module MPCC

using JuMP, Dates, DataFrames, CSV, DotEnv

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
import ..Euphemia.MarketOrders: MarketOrder, SimpleOrder
import ..Euphemia: get_loads, get_generators, get_generation_forecast_for_wind_and_solar
import ..Euphemia.BiddingStrategy: generate_market_orders_from_uc, UCToBidsResult

# Export main functions
export MPCCResult, solve_mpcc_market_clearing, create_order_book_from_uc, select_solver

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

# Configuration constants
const DEFAULT_MARKUP_FACTOR = 1.1
const BIG_M_PARAMETER = 4000000.0

"""
    validate_order_book(order_book::Dict{String,Any})

Validates order book consistency and balance, provides warnings for potential issues.
"""
function validate_order_book(order_book::Dict{String,Any})
    println("\n=== Order Book Validation ===")
    
    total_orders = length(order_book["Orders"])
    println("Total orders: $total_orders")
    
    # Check supply/demand balance by hour
    for period in order_book["Periods"]
        supply_total = 0.0
        demand_total = 0.0
        supply_orders = 0
        demand_orders = 0
        
        for (order_id, order) in order_book["Orders"]
            if haskey(order["qtity"], period)
                quantity = order["qtity"][period]
                if quantity < 0  # Supply order
                    supply_total += abs(quantity)
                    supply_orders += (quantity != 0) ? 1 : 0
                elseif quantity > 0  # Demand order
                    demand_total += quantity
                    demand_orders += 1
                end
            end
        end
        
        balance = supply_total - demand_total
        balance_pct = (abs(balance) / max(demand_total, 1.0)) * 100
        
        if balance_pct > 5.0  # More than 5% imbalance
            if balance > 0
                @warn "Period $period: Oversupply of $(round(balance, digits=1)) MW ($(round(balance_pct, digits=1))%)"
            else
                @warn "Period $period: Undersupply of $(round(abs(balance), digits=1)) MW ($(round(balance_pct, digits=1))%)"
            end
        else
            println("Period $period: Balanced - Supply: $(round(supply_total, digits=1)) MW ($(supply_orders) orders), Demand: $(round(demand_total, digits=1)) MW ($(demand_orders) orders)")
        end
    end
    
    # Check price bounds
    min_price = minimum(order["price"]["p0"] for (_, order) in order_book["Orders"])
    max_price = maximum(order["price"]["p0"] for (_, order) in order_book["Orders"])
    
    println("Price range in orders: €$(round(min_price, digits=2)) - €$(round(max_price, digits=2))/MWh")
    
    if max_price > order_book["Price_range"]["upper"]
        @warn "Some order prices (€$max_price) exceed upper bound (€$(order_book["Price_range"]["upper"]))"
    end
    
    if min_price < order_book["Price_range"]["lower"]
        @warn "Some order prices (€$min_price) below lower bound (€$(order_book["Price_range"]["lower"]))"
    end
    
    println("=== Validation Complete ===\n")
end

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
    create_order_book_from_uc(bidding_zone::String, day::Date; markup_factor::Float64=$DEFAULT_MARKUP_FACTOR)

Creates an MPCC-compatible order book from real ENTSO-E unit commitment results and load data.

# Arguments
- `bidding_zone::String`: Bidding zone identifier (e.g., "GR")
- `day::Date`: Target date for market data
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost

# Returns
- `Dict{String,Any}`: Order book structure compatible with MPCC solver
"""
function create_order_book_from_uc(bidding_zone::String, day::Date; markup_factor::Float64=DEFAULT_MARKUP_FACTOR)
    try
        # Generate market orders from real unit commitment
        uc_to_bids = generate_market_orders_from_uc(bidding_zone, day; markup_factor=markup_factor)

        if !uc_to_bids.success
            error("Failed to generate market orders: $(uc_to_bids.message)")
        end

        # Get real hourly demand data from ENTSO-E database
        loads = get_loads(bidding_zone, day)

        # Convert to MPCC format
        order_book = Dict{String,Any}()

        # Initialize structure
        order_book["Orders"] = Dict{String,Any}()
        order_book["ComplexOrders"] = Dict{String,Any}()
        order_book["Nodes"] = [bidding_zone]
        order_book["Periods"] = [string(h) for h in 1:24]

        # Convert supply orders (stepwise by default) - only for committed hours
        order_id = 1
        for supply_order in uc_to_bids.supply_orders
            # Extract hour from the DateTime
            hour_of_day = Dates.hour(supply_order.date_time) + 1  # Convert 0-23 to 1-24
            
            # Only create order for the specific hour this supply order is for
            qtity_dict = Dict{String,Float64}()
            for hour in 1:24
                if hour == hour_of_day
                    qtity_dict[string(hour)] = -supply_order.quantity  # Negative for supply in this hour only
                else
                    qtity_dict[string(hour)] = 0.0  # Zero for all other hours
                end
            end

            order_book["Orders"][string(order_id)] = Dict(
                "type" => "stepwise",
                "node" => string(supply_order.zone),
                "price" => Dict("p0" => supply_order.price),
                "qtity" => qtity_dict,
                "mar" => 1.0
            )
            order_id += 1
        end

        # Add demand orders using net_demand from UC solution (load - renewables)
        # This ensures supply-demand balance matches the UC optimization
        if !isempty(uc_to_bids.demand_orders)
            for demand_order in uc_to_bids.demand_orders
                # Extract hour from the DateTime
                hour_of_day = Dates.hour(demand_order.date_time) + 1  # Convert 0-23 to 1-24
                
                # Only create demand order for the specific hour
                qtity_dict = Dict{String,Float64}()
                for hour in 1:24
                    if hour == hour_of_day
                        qtity_dict[string(hour)] = demand_order.quantity  # Positive for demand
                    else
                        qtity_dict[string(hour)] = 0.0  # Zero for all other hours
                    end
                end

                order_book["Orders"][string(order_id)] = Dict(
                    "type" => "stepwise",
                    "node" => string(demand_order.zone),
                    "price" => Dict("p0" => demand_order.price),  # Use the actual demand price
                    "qtity" => qtity_dict,
                    "mar" => 1.0
                )
                order_id += 1
            end
        else
            # Fallback: if no demand orders from UC, use net load data but warn
            @warn "No demand orders from UC solution, falling back to raw load data"
            for (hour_idx, load) in enumerate(loads)
                if hour_idx <= 24
                    qtity_dict = Dict{String,Float64}()
                    for h in 1:24
                        qtity_dict[string(h)] = (h == hour_idx) ? load.value : 0.0
                    end

                    order_book["Orders"][string(order_id)] = Dict(
                        "type" => "stepwise",
                        "node" => load.bidding_zone,
                        "price" => Dict("p0" => 500.0),
                        "qtity" => qtity_dict,
                        "mar" => 1.0
                    )
                    order_id += 1
                end
            end
        end

        # Add ATC structure (simplified single node)
        order_book["ATC"] = Dict{String,Any}()
        order_book["ATC"]["Flows"] = Dict{String,Any}()

        # Add price range (realistic bounds: 0-500 €/MWh typical for European markets)
        order_book["Price_range"] = Dict("lower" => 0.0, "upper" => 500.0)

        # Validate order book consistency
        validate_order_book(order_book)

        return order_book

    catch e
        error("Failed to create order book from unit commitment data: $e")
    end
end

"""
    solve_mpcc_market_clearing(order_book::Dict{String,Any}; 
                              preferred_solver::String="auto", 
                              silent::Bool=true,
                              big_m::Float64=BIG_M_PARAMETER)

Solves the MPCC-based market clearing problem using the Euphemia algorithm.

# Arguments
- `order_book::Dict{String,Any}`: Market order book structure
- `preferred_solver::String`: Preferred solver ("auto", "highs", "gurobi", or "cplex")
- `silent::Bool`: Whether to suppress solver output
- `big_m::Float64`: Big-M parameter for complementarity constraints

# Returns
- `MPCCResult`: Complete solution results including prices and quantities
"""
function solve_mpcc_market_clearing(order_book::Dict{String,Any}; 
                                   preferred_solver::String="auto", 
                                   silent::Bool=true,
                                   big_m::Float64=BIG_M_PARAMETER)
    
    # Data organization
    stepwise_orders = filter((k, v)::Pair -> v["type"] == "stepwise", order_book["Orders"]) |> keys |> collect
    block_orders = filter((k, v)::Pair -> (v["type"] == "block" || v["type"] == "exclusive" || v["type"] == "linked"), order_book["Orders"]) |> keys |> collect
    exclusive_block_orders = filter((k, v)::Pair -> v["type"] == "exclusive", order_book["Orders"]) |> keys |> collect

    exclusive_order_groups = filter((k, v)::Pair -> v["type"] == "exclusive", order_book["ComplexOrders"]) |> keys |> collect
    linked_order_groups = filter((k, v)::Pair -> v["type"] == "linked", order_book["ComplexOrders"]) |> keys |> collect

    parent_orders = String[]
    child_orders = String[]
    for group_id in linked_order_groups
        push!(parent_orders, order_book["ComplexOrders"][group_id]["parent"])
        for child_id in order_book["ComplexOrders"][group_id]["children"]
            push!(child_orders, child_id)
        end
    end

    # Create orders by node mapping
    orders_by_node = Dict{String,Any}()
    for node_id in order_book["Nodes"]
        orders_by_node[node_id] = Dict{String,Any}()
        orders_by_node[node_id]["stepwise_orders"] = Dict{String,Any}()
        for time_period in order_book["Periods"]
            orders_by_node[node_id]["stepwise_orders"][time_period] = filter((k, v)::Pair -> 
                v["type"] == "stepwise" && v["node"] == node_id && haskey(v["qtity"], time_period), 
                order_book["Orders"]) |> keys |> collect
        end

        orders_by_node[node_id]["block_orders"] = Dict{String,Any}()
        for time_period in order_book["Periods"]
            orders_by_node[node_id]["block_orders"][time_period] = filter((k, v)::Pair -> 
                (v["type"] == "block" || v["type"] == "exclusive" || v["type"] == "linked") && 
                v["node"] == node_id && haskey(v["qtity"], time_period), 
                order_book["Orders"]) |> keys |> collect
        end

        if haskey(order_book["ATC"], "Flows")
            orders_by_node[node_id]["flows_from"] = filter((k, v)::Pair -> v["from"] == node_id, order_book["ATC"]["Flows"]) |> keys |> collect
            orders_by_node[node_id]["flows_to"] = filter((k, v)::Pair -> v["to"] == node_id, order_book["ATC"]["Flows"]) |> keys |> collect
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
        # Decision Variables
        @variable(model, 0 <= stepwise_acceptance[order_id in stepwise_orders])
        @variable(model, 0 <= stepwise_dual[order_id in stepwise_orders])

        @variable(model, 0 <= block_activation[order_id in block_orders], Bin)
        @variable(model, 0 <= block_acceptance[order_id in block_orders])
        @variable(model, 0 <= block_acceptance_lower_dual[order_id in block_orders])
        @variable(model, 0 <= block_acceptance_upper_dual[order_id in block_orders])

        # Load shedding variables for market robustness (high penalty cost)
        @variable(model, load_shed[node_id in order_book["Nodes"], time_period in order_book["Periods"]] >= 0)

        @variable(model, 0 <= block_activation_dual[order_id in block_orders; (!(order_id in exclusive_block_orders) && !(order_id in child_orders))])
        @variable(model, 0 <= exclusive_group_dual[group_id in exclusive_order_groups])
        @variable(model, 0 <= linked_group_dual[group_id in linked_order_groups, child_id in order_book["ComplexOrders"][group_id]["children"]])

        if haskey(order_book["ATC"], "Flows")
            @variable(model, transmission_flow[flow_id in keys(order_book["ATC"]["Flows"]), time_period in order_book["Periods"]])
        end

        @variable(model, market_price[node_id in order_book["Nodes"], time_period in order_book["Periods"]])

        # Stepwise order constraints
        @constraint(model, stepwise_upper_bound[order_id in stepwise_orders],
            stepwise_acceptance[order_id] <= 1
        )

        @expression(model, stepwise_dual_rhs[order_id in stepwise_orders],
            stepwise_dual[order_id] +
            sum(order_book["Orders"][order_id]["qtity"][time_period] *
                market_price[order_book["Orders"][order_id]["node"], time_period]
                for time_period in keys(order_book["Orders"][order_id]["qtity"])) -
            sum(order_book["Orders"][order_id]["qtity"][time_period] *
                order_book["Orders"][order_id]["price"]["p0"]
                for time_period in keys(order_book["Orders"][order_id]["qtity"]))
        )

        @constraint(model, stepwise_dual_constraint[order_id in stepwise_orders],
            0 <= stepwise_dual_rhs[order_id]
        )

        # Block order constraints
        if !isempty(block_orders)
            @constraint(model, block_activation_upper_bound[order_id in block_orders; (!(order_id in exclusive_block_orders) && !(order_id in child_orders))],
                block_activation[order_id] <= 1
            )

            @constraint(model, block_acceptance_upper_bound[order_id in block_orders],
                block_acceptance[order_id] <= block_activation[order_id]
            )

            @constraint(model, block_acceptance_lower_bound[order_id in block_orders],
                order_book["Orders"][order_id]["mar"] * block_activation[order_id] <= block_acceptance[order_id]
            )
        end

        # Power balance constraints
        if haskey(order_book["ATC"], "Flows") && !isempty(order_book["ATC"]["Flows"])
            @constraint(model, nodal_power_balance[node_id in order_book["Nodes"], time_period in order_book["Periods"]],
                sum(stepwise_acceptance[order_id] * order_book["Orders"][order_id]["qtity"][time_period] 
                    for order_id in orders_by_node[node_id]["stepwise_orders"][time_period]) +
                sum(block_acceptance[order_id] * order_book["Orders"][order_id]["qtity"][time_period] 
                    for order_id in orders_by_node[node_id]["block_orders"][time_period]) + 
                load_shed[node_id, time_period] ==
                sum(transmission_flow[flow_id, time_period] 
                    for flow_id in orders_by_node[node_id]["flows_to"]) -
                sum(transmission_flow[flow_id, time_period] 
                    for flow_id in orders_by_node[node_id]["flows_from"])
            )
        else
            @constraint(model, nodal_power_balance[node_id in order_book["Nodes"], time_period in order_book["Periods"]],
                sum(stepwise_acceptance[order_id] * order_book["Orders"][order_id]["qtity"][time_period] 
                    for order_id in orders_by_node[node_id]["stepwise_orders"][time_period]) +
                sum(block_acceptance[order_id] * order_book["Orders"][order_id]["qtity"][time_period] 
                    for order_id in orders_by_node[node_id]["block_orders"][time_period]) + 
                load_shed[node_id, time_period] == 0
            )
        end

        # Complementarity constraints (simplified version for demonstration)
        @variable(model, stepwise_acceptance_complementarity_aux[order_id in stepwise_orders], Bin)
        @constraint(model, stepwise_acceptance_complementarity_ineq1[order_id in stepwise_orders], 
            stepwise_acceptance[order_id] <= stepwise_acceptance_complementarity_aux[order_id] * big_m)
        @constraint(model, stepwise_acceptance_complementarity_ineq2[order_id in stepwise_orders], 
            stepwise_dual_rhs[order_id] <= (1 - stepwise_acceptance_complementarity_aux[order_id]) * big_m)

        # Price range constraints
        if haskey(order_book, "Price_range")
            @constraint(model, minimum_price[node_id in order_book["Nodes"], time_period in order_book["Periods"]], 
                market_price[node_id, time_period] >= order_book["Price_range"]["lower"])
            @constraint(model, maximum_price[node_id in order_book["Nodes"], time_period in order_book["Periods"]], 
                market_price[node_id, time_period] <= order_book["Price_range"]["upper"])
        end

        # Objective function (maximize social welfare minus load shedding penalty)
        load_shed_penalty = 10000.0  # High penalty for load shedding (€/MWh)
        @objective(model, Max,
            sum(stepwise_acceptance[order_id] * 
                (sum(order_book["Orders"][order_id]["qtity"][time_period] for time_period in order_book["Periods"] 
                     if haskey(order_book["Orders"][order_id]["qtity"], time_period))) * 
                order_book["Orders"][order_id]["price"]["p0"] for order_id in stepwise_orders) +
            sum(block_acceptance[order_id] * 
                (sum(order_book["Orders"][order_id]["qtity"][time_period] for time_period in order_book["Periods"] 
                     if haskey(order_book["Orders"][order_id]["qtity"], time_period))) * 
                order_book["Orders"][order_id]["price"]["p0"] for order_id in block_orders) -
            load_shed_penalty * sum(load_shed[node_id, time_period] 
                for node_id in order_book["Nodes"], time_period in order_book["Periods"])
        )

        # Solve the model
        optimize!(model)
        solve_time = time() - start_time

        # Extract results
        if has_values(model)
            market_prices = Dict{String,Dict{String,Float64}}()
            for node_id in order_book["Nodes"]
                market_prices[node_id] = Dict{String,Float64}()
                for time_period in order_book["Periods"]
                    market_prices[node_id][time_period] = value(market_price[node_id, time_period])
                end
            end

            stepwise_acceptance_values = Dict{String,Float64}()
            for order_id in stepwise_orders
                stepwise_acceptance_values[order_id] = value(stepwise_acceptance[order_id])
            end

            block_acceptance_values = Dict{String,Float64}()
            block_activation_values = Dict{String,Float64}()
            for order_id in block_orders
                block_acceptance_values[order_id] = value(block_acceptance[order_id])
                block_activation_values[order_id] = value(block_activation[order_id])
            end

            transmission_flows = Dict{String,Dict{String,Float64}}()
            if haskey(order_book["ATC"], "Flows") && !isempty(order_book["ATC"]["Flows"])
                for flow_id in keys(order_book["ATC"]["Flows"])
                    transmission_flows[flow_id] = Dict{String,Float64}()
                    for time_period in order_book["Periods"]
                        transmission_flows[flow_id][time_period] = value(transmission_flow[flow_id, time_period])
                    end
                end
            end

            # Calculate total load shedding for reporting
            total_load_shed = sum(value(load_shed[node_id, time_period]) 
                for node_id in order_book["Nodes"], time_period in order_book["Periods"])
            
            result_message = if total_load_shed > 0.01
                "Successfully solved MPCC market clearing problem (Load shed: $(round(total_load_shed, digits=1)) MW)"
            else
                "Successfully solved MPCC market clearing problem"
            end
            
            return MPCCResult(
                :optimal,
                objective_value(model),
                market_prices,
                stepwise_acceptance_values,
                block_acceptance_values,
                block_activation_values,
                transmission_flows,
                solve_time,
                solver_name,
                result_message
            )
        else
            return MPCCResult(
                Symbol(termination_status(model)),
                0.0,
                Dict{String,Dict{String,Float64}}(),
                Dict{String,Float64}(),
                Dict{String,Float64}(),
                Dict{String,Float64}(),
                Dict{String,Dict{String,Float64}}(),
                solve_time,
                solver_name,
                "No solution found: $(termination_status(model))"
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
            "Error during optimization: $e"
        )
    end
end

end  # module MPCC