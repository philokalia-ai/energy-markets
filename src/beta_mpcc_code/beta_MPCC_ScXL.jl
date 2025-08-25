#------------------------------------------------------------------------------------------#
# MPCC-based Euphemia Market Clearing Implementation
# 
# Solver Requirements (install at least one):
# - HiGHS.jl (recommended, open-source): ] add HiGHS
# - Gurobi.jl (commercial, requires license): ] add Gurobi
# - CPLEX.jl (commercial, requires license): ] add CPLEX
#
# The script will automatically detect and use the first available solver.
#------------------------------------------------------------------------------------------#
using JuMP, Dates, DataFrames, CSV, DotEnv

# Load environment variables first, before importing any database modules
DotEnv.load!(".")

# Import solvers with error handling
try
    using HiGHS
    global HIGHS_AVAILABLE = true
catch
    global HIGHS_AVAILABLE = false
    println("Warning: HiGHS.jl not available")
end

try
    using Gurobi
    global GUROBI_AVAILABLE = true
catch
    global GUROBI_AVAILABLE = false
    println("Warning: Gurobi.jl not available")
end

try
    using CPLEX
    global CPLEX_AVAILABLE = true
catch
    global CPLEX_AVAILABLE = false
    println("Warning: CPLEX.jl not available")
end

ENV["TICKTOCK_MESSAGES"] = false
#------------------------------------------------------------------------------------------#

# Load real ENTSO-E market data modules
include("../dbutils.jl")
# Make sql2df available in Main scope so modules can reference Euphemia.sql2df
const Euphemia = (sql2df=sql2df,)  # Create minimal Euphemia namespace

include("../MarketOrders.jl")
using .MarketOrders: MarketOrder, SimpleOrder

include("../Generators.jl")
include("../FuelTypeParameters.jl")
include("../Loads.jl")
include("../Renewables.jl")
include("../UnitCommitment.jl")
include("../BiddingStrategy.jl")
using .BiddingStrategy: generate_market_orders_from_uc, UCToBidsResult# Market data configuration
const TARGET_DATE = Date(2025, 6, 24)  # Can be made configurable
const BIDDING_ZONE = "GR"  # Can be made configurable
const MARKUP_FACTOR = 1.1  # 10% markup for supply bids

"""
    create_order_book_from_uc(bidding_zone::String, day::Date)

Creates an MPCC-compatible order book from real ENTSO-E unit commitment results and load data.
"""
function create_order_book_from_uc(bidding_zone::String, day::Date)
    # Generate market orders from real unit commitment
    println("Running unit commitment optimization for $bidding_zone on $day...")
    try
        # Convert UC results to market orders using real bidding strategy
        uc_to_bids = generate_market_orders_from_uc(bidding_zone, day; markup_factor=MARKUP_FACTOR)

        if !uc_to_bids.success
            error("Failed to generate market orders: $(uc_to_bids.message)")
        end

        # Get real hourly demand data from ENTSO-E database
        loads = get_loads(bidding_zone, day)
        println("Retrieved $(length(loads)) load data points for $bidding_zone on $day from ENTSO-E database")

        # Convert to MPCC format
        order_book = Dict{String,Any}()

        # Initialize structure
        order_book["Orders"] = Dict{String,Any}()
        order_book["ComplexOrders"] = Dict{String,Any}()
        order_book["Nodes"] = [bidding_zone]  # Single node for now
        order_book["Periods"] = [string(h) for h in 1:24]  # 24 hourly periods for day-ahead market

        # Convert supply orders (stepwise by default) - extend to all 24 hours
        order_id = 1
        for supply_order in uc_to_bids.supply_orders
            # Create quantity dictionary for all 24 hours
            qtity_dict = Dict{String,Float64}()
            for hour in 1:24
                qtity_dict[string(hour)] = -supply_order.quantity  # Negative for supply
            end

            order_book["Orders"][string(order_id)] = Dict(
                "type" => "stepwise",
                "node" => string(supply_order.zone),
                "price" => Dict("p0" => supply_order.price),
                "qtity" => qtity_dict,
                "mar" => 1.0  # Full acceptance for stepwise
            )
            order_id += 1
        end

        # Add real hourly load data from ENTSO-E
        for (hour_idx, load) in enumerate(loads)
            if hour_idx <= 24  # Ensure we don't exceed 24 hours
                # Create a demand order for this hour's load
                qtity_dict = Dict{String,Float64}()
                # Only add quantity for the specific hour, zero for others
                for h in 1:24
                    qtity_dict[string(h)] = (h == hour_idx) ? load.value : 0.0
                end

                order_book["Orders"][string(order_id)] = Dict(
                    "type" => "stepwise",
                    "node" => load.bidding_zone,
                    "price" => Dict("p0" => 3000.0),  # High price for must-serve load
                    "qtity" => qtity_dict,
                    "mar" => 1.0
                )
                order_id += 1
            end
        end

        # Add ATC structure (simplified single node)
        order_book["ATC"] = Dict{String,Any}()
        order_book["ATC"]["Flows"] = Dict{String,Any}()  # No transmission for single node

        # Add price range if needed
        order_book["Price_range"] = Dict("lower" => -500.0, "upper" => 3000.0)

        # Display market structure summary
        println("Market structure created:")
        println("  - $(length(uc_to_bids.supply_orders)) supply orders from unit commitment")
        println("  - $(length(uc_to_bids.demand_orders)) demand orders from unit commitment")
        println("  - $(length(loads)) hourly load data points from ENTSO-E")
        println("  - Total orders in book: $(length(order_book["Orders"]))")
        println("  - Time periods: $(length(order_book["Periods"])) hours")
        println("  - Bidding zones: $(order_book["Nodes"])")

        return order_book

    catch e
        println("Error accessing real data, falling back to mock data...")
        println("Error details: $(e)")

        # Fallback to simplified mock data if real modules fail
        return create_mock_order_book(bidding_zone, day)
    end
end

"""
    create_mock_order_book(bidding_zone::String, day::Date)

Fallback function to create mock order book if real data is unavailable.
"""
function create_mock_order_book(bidding_zone::String, day::Date)
    # Mock supply orders - typical Greek generation mix
    mock_supply_orders = [
        (type=:supply, price=25.0, quantity=500.0, zone=Symbol(bidding_zone)),  # Nuclear/Hydro baseload  
        (type=:supply, price=45.0, quantity=300.0, zone=Symbol(bidding_zone)),  # Lignite
        (type=:supply, price=65.0, quantity=200.0, zone=Symbol(bidding_zone)),  # Gas CCGT
        (type=:supply, price=85.0, quantity=150.0, zone=Symbol(bidding_zone)),  # Gas Peaker
        (type=:supply, price=105.0, quantity=100.0, zone=Symbol(bidding_zone)), # Oil/Emergency
    ]

    # Mock 24-hour load profile for Greece
    base_load = 4000.0  # MW
    hourly_factors = [0.7, 0.65, 0.6, 0.58, 0.6, 0.65, 0.75, 0.85, 0.9, 0.95, 1.0, 1.05, 1.1, 1.08, 1.05, 1.0, 0.95, 1.0, 1.05, 1.0, 0.95, 0.9, 0.85, 0.75]
    mock_loads = [(timeslot="$(day)-$(lpad(h,2,'0'))", resolution_code="60", bidding_zone=bidding_zone, value=base_load * factor) for (h, factor) in enumerate(hourly_factors)]

    # Convert to MPCC format
    order_book = Dict{String,Any}()
    order_book["Orders"] = Dict{String,Any}()
    order_book["ComplexOrders"] = Dict{String,Any}()
    order_book["Nodes"] = [bidding_zone]
    order_book["Periods"] = [string(h) for h in 1:24]

    # Add supply orders
    order_id = 1
    for supply_order in mock_supply_orders
        qtity_dict = Dict{String,Float64}()
        for hour in 1:24
            qtity_dict[string(hour)] = -supply_order.quantity  # Negative for supply
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

    # Add hourly load data  
    for (hour_idx, load) in enumerate(mock_loads)
        if hour_idx <= 24
            qtity_dict = Dict{String,Float64}()
            for h in 1:24
                qtity_dict[string(h)] = (h == hour_idx) ? load.value : 0.0
            end

            order_book["Orders"][string(order_id)] = Dict(
                "type" => "stepwise",
                "node" => load.bidding_zone,
                "price" => Dict("p0" => 3000.0),
                "qtity" => qtity_dict,
                "mar" => 1.0
            )
            order_id += 1
        end
    end

    order_book["ATC"] = Dict{String,Any}()
    order_book["ATC"]["Flows"] = Dict{String,Any}()
    order_book["Price_range"] = Dict("lower" => -500.0, "upper" => 3000.0)

    println("Mock market structure created:")
    println("  - $(length(mock_supply_orders)) mock supply orders")
    println("  - $(length(mock_loads)) mock demand orders (from load data)")
    println("  - $(length(mock_loads)) mock hourly load data points")
    println("  - Total orders in book: $(length(order_book["Orders"]))")
    println("  - Time periods: $(length(order_book["Periods"])) hours")
    println("  - Bidding zones: $(order_book["Nodes"])")

    return order_book
end

# Create order book from real ENTSO-E data
println("Creating order book from real ENTSO-E data for $BIDDING_ZONE on $TARGET_DATE...")
println("Attempting to use real unit commitment and load data from database...")
order_book = create_order_book_from_uc(BIDDING_ZONE, TARGET_DATE)

#-- Data organization with readable names -----------------------------------------#
stepwise_orders = filter((k, v)::Pair -> v["type"] == "stepwise", order_book["Orders"]) |> keys

block_orders = filter((k, v)::Pair -> (v["type"] == "block" || v["type"] == "exclusive" || v["type"] == "linked"), order_book["Orders"]) |> keys

exclusive_block_orders = filter((k, v)::Pair -> v["type"] == "exclusive", order_book["Orders"]) |> keys
linked_block_orders = filter((k, v)::Pair -> v["type"] == "linked", order_book["Orders"]) |> keys

exclusive_order_groups = filter((k, v)::Pair -> v["type"] == "exclusive", order_book["ComplexOrders"]) |> keys
linked_order_groups = filter((k, v)::Pair -> v["type"] == "linked", order_book["ComplexOrders"]) |> keys

parent_orders = String[]
child_orders = String[]
for group_id in linked_order_groups
    push!(parent_orders, order_book["ComplexOrders"][group_id]["parent"])
    for child_id in order_book["ComplexOrders"][group_id]["children"]
        push!(child_orders, child_id)
    end
end

orders_by_node = Dict{String,Any}()
for node_id in order_book["Nodes"]

    orders_by_node[node_id] = Dict{String,Any}()
    orders_by_node[node_id]["stepwise_orders"] = Dict{String,Any}()
    for time_period in order_book["Periods"]
        orders_by_node[node_id]["stepwise_orders"][time_period] = filter((k, v)::Pair -> v["type"] == "stepwise" && v["node"] == node_id && haskey(v["qtity"], time_period), order_book["Orders"]) |> keys
    end

    orders_by_node[node_id]["block_orders"] = Dict{String,Any}()
    for time_period in order_book["Periods"]
        orders_by_node[node_id]["block_orders"][time_period] = filter((k, v)::Pair -> (v["type"] == "block" || v["type"] == "exclusive" || v["type"] == "linked") && v["node"] == node_id && haskey(v["qtity"], time_period), order_book["Orders"]) |> keys
    end


    if haskey(order_book["ATC"], "Flows")
        orders_by_node[node_id]["flows_from"] = filter((k, v)::Pair -> v["from"] == node_id, order_book["ATC"]["Flows"]) |> keys
        orders_by_node[node_id]["flows_to"] = filter((k, v)::Pair -> v["to"] == node_id, order_book["ATC"]["Flows"]) |> keys
    end
end



if haskey(order_book["ATC"], "LmTs")
    transmission_limits_by_time = Dict{String,Any}()
    for time_period in order_book["Periods"]
        transmission_limits_by_time[time_period] = filter((k, v)::Pair -> haskey(v["value"], time_period), order_book["ATC"]["LmTs"]) |> keys
    end
end
#------------------------------------------------------------------------------------------#


#-- MPCC Model with readable variable names ---------------------------------------------#

# Solver selection with fallback options
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
        # Default priority: HiGHS (open-source) -> Gurobi -> CPLEX
        available_solvers
    elseif lowercase(preferred_solver) == "highs" && HIGHS_AVAILABLE
        [("HiGHS", HiGHS.Optimizer)] + filter(x -> x[1] != "HiGHS", available_solvers)
    elseif lowercase(preferred_solver) == "gurobi" && GUROBI_AVAILABLE
        [("Gurobi", Gurobi.Optimizer)] + filter(x -> x[1] != "Gurobi", available_solvers)
    elseif lowercase(preferred_solver) == "cplex" && CPLEX_AVAILABLE
        [("CPLEX", CPLEX.Optimizer)] + filter(x -> x[1] != "CPLEX", available_solvers)
    elseif preferred_solver != "auto"
        println("Warning: Preferred solver '$preferred_solver' not available. Using auto-selection.")
        available_solvers
    else
        available_solvers
    end

    # Try solvers in order
    for (solver_name, optimizer) in solvers_to_try
        try
            println("Trying $solver_name solver...")
            # Test if solver is functional by creating a test model
            test_model = Model(optimizer)
            println("✓ Using $solver_name solver")
            return optimizer
        catch e
            println("✗ $solver_name failed to initialize: $(typeof(e))")
        end
    end

    error("All available solvers failed to initialize!")
end

# Create model with selected solver
# You can change "auto" to "highs", "gurobi", or "cplex" to force a specific solver
selected_optimizer = select_solver("auto")
euphemia_model = Model(selected_optimizer)

# Configure solver settings (silent mode and performance tuning)
solver_name = string(selected_optimizer)
if occursin("HiGHS", solver_name)
    set_silent(euphemia_model)
    println("HiGHS solver configured with default settings")
    # HiGHS-specific settings for mixed-integer problems
    # set_attribute(euphemia_model, "presolve", "on")
    # set_attribute(euphemia_model, "parallel", "on")
elseif occursin("Gurobi", solver_name)
    set_silent(euphemia_model)
    println("Gurobi solver configured with default settings")
    # Gurobi-specific settings for MPCC problems
    # set_attribute(euphemia_model, "MIPGap", 0.01)
    # set_attribute(euphemia_model, "TimeLimit", 3600)
elseif occursin("CPLEX", solver_name)
    set_silent(euphemia_model)
    println("CPLEX solver configured with default settings")
    # CPLEX-specific settings
    # set_attribute(euphemia_model, "CPXPARAM_MIP_Tolerances_MIPGap", 0.01)
else
    set_silent(euphemia_model)
    println("Unknown solver type - using generic settings")
end

println("Model ready for optimization.")
println("Note: Uncomment solver-specific settings above for performance tuning if needed.")

big_m_parameter = 4000000  # Large number for Big-M constraints

#-- Decision Variables with clear names --#

# Stepwise order acceptance variables (0-1 continuous)
@variable(euphemia_model, 0 <= stepwise_acceptance[order_id in stepwise_orders])
@variable(euphemia_model, 0 <= stepwise_dual[order_id in stepwise_orders])

# Block order variables
@variable(euphemia_model, 0 <= block_activation[order_id in block_orders], Bin)  # Binary: activate block or not
@variable(euphemia_model, 0 <= block_acceptance[order_id in block_orders])       # Continuous: how much to accept
@variable(euphemia_model, 0 <= block_acceptance_lower_dual[order_id in block_orders])
@variable(euphemia_model, 0 <= block_acceptance_upper_dual[order_id in block_orders])

# Dual variables for different constraint types
@variable(euphemia_model, 0 <= block_activation_dual[order_id in block_orders; (!(order_id in exclusive_block_orders) && !(order_id in child_orders))])
@variable(euphemia_model, 0 <= exclusive_group_dual[group_id in exclusive_order_groups])
@variable(euphemia_model, 0 <= linked_group_dual[group_id in linked_order_groups, child_id in order_book["ComplexOrders"][group_id]["children"]])

# Network flow variables (if transmission network exists)
if haskey(order_book["ATC"], "Flows")
    @variable(euphemia_model, transmission_flow[flow_id in keys(order_book["ATC"]["Flows"]), time_period in order_book["Periods"]])
end

# Market clearing prices (dual variables of power balance constraints)
@variable(euphemia_model, market_price[node_id in order_book["Nodes"], time_period in order_book["Periods"]])
#-- Constraints with readable names --#

# Stepwise order constraints
@constraint(euphemia_model, stepwise_upper_bound[order_id in stepwise_orders],
    stepwise_acceptance[order_id] <= 1
)

# Calculate the dual constraint right-hand side for stepwise orders
@expression(euphemia_model, stepwise_dual_rhs[order_id in stepwise_orders],
    stepwise_dual[order_id]
    +
    sum(order_book["Orders"][order_id]["qtity"][time_period] *
        market_price[order_book["Orders"][order_id]["node"], time_period]
        for time_period in keys(order_book["Orders"][order_id]["qtity"]))
    -
    sum(order_book["Orders"][order_id]["qtity"][time_period] *
        order_book["Orders"][order_id]["price"]["p0"]
        for time_period in keys(order_book["Orders"][order_id]["qtity"]))
)

@constraint(euphemia_model, stepwise_dual_constraint[order_id in stepwise_orders],
    0 <= stepwise_dual_rhs[order_id]
)
# Block order activation constraints
@constraint(euphemia_model, block_activation_upper_bound[order_id in block_orders; (!(order_id in exclusive_block_orders) && !(order_id in child_orders))],
    block_activation[order_id] <= 1
)

# Block order acceptance constraints
@constraint(euphemia_model, block_acceptance_upper_bound[order_id in block_orders],
    block_acceptance[order_id] <= block_activation[order_id]
)

@constraint(euphemia_model, block_acceptance_lower_bound[order_id in block_orders],
    order_book["Orders"][order_id]["mar"] * block_activation[order_id] <= block_acceptance[order_id]
)
# Exclusive group constraints (only one block in group can be activated)
@constraint(euphemia_model, exclusive_group_constraint[group_id in exclusive_order_groups],
    sum(block_activation[order_id] for order_id in order_book["ComplexOrders"][group_id]["members"]) <= 1
)

# Linked group constraints (child blocks depend on parent activation)
@constraint(euphemia_model, linked_group_constraint[group_id in linked_order_groups, child_id in order_book["ComplexOrders"][group_id]["children"]],
    block_activation[child_id] <= block_activation[order_book["ComplexOrders"][group_id]["parent"]]
)
#--

# Block order acceptance dual constraint (M4C)
@expression(euphemia_model, block_acceptance_dual_rhs[order_idx in block_orders],
    block_acceptance_upper_dual[order_idx] - block_acceptance_lower_dual[order_idx]
    +
    sum(order_book["Orders"][order_idx]["qtity"][time_period] * market_price[order_book["Orders"][order_idx]["node"], time_period] for time_period in keys(order_book["Orders"][order_idx]["qtity"]))
    -
    sum(order_book["Orders"][order_idx]["qtity"][time_period] * order_book["Orders"][order_idx]["price"]["p0"] for time_period in keys(order_book["Orders"][order_idx]["qtity"]))
)
@constraint(euphemia_model, block_acceptance_dual_constraint[order_idx in block_orders],        #(M4C)
    0 <=
    block_acceptance_dual_rhs[order_idx]
)
#--

# Block order activation dual constraint -- REGULAR BLOCKS ONLY (M4C)
@expression(euphemia_model, regular_block_activation_dual_rhs[order_idx in block_orders; (!(order_idx in exclusive_block_orders) && !(order_idx in linked_block_orders))],
    block_activation_dual[order_idx]
    +
    order_book["Orders"][order_idx]["mar"] * block_acceptance_lower_dual[order_idx] - block_acceptance_upper_dual[order_idx]
)
@constraint(euphemia_model, regular_block_activation_dual_constraint[order_idx in block_orders; (!(order_idx in exclusive_block_orders) && !(order_idx in linked_block_orders))],
    0 <=
    regular_block_activation_dual_rhs[order_idx]
)
#--

# Block order activation dual constraint -- EXCLUSIVE BLOCKS ONLY (M4C)
@expression(euphemia_model, exclusive_block_activation_dual_rhs[order_idx in exclusive_block_orders],
    sum(exclusive_group_dual[group_idx] for group_idx in exclusive_order_groups if order_idx in order_book["ComplexOrders"][group_idx]["members"])
    +
    order_book["Orders"][order_idx]["mar"] * block_acceptance_lower_dual[order_idx] - block_acceptance_upper_dual[order_idx]
)
@constraint(euphemia_model, exclusive_block_activation_dual_constraint[order_idx in exclusive_block_orders],
    0 <=
    exclusive_block_activation_dual_rhs[order_idx]
)
#--

# Block order activation dual constraint -- PARENT BLOCKS ONLY (M4C)
@expression(euphemia_model, parent_block_activation_dual_rhs[order_idx in parent_orders],
    block_activation_dual[order_idx]
    -
    sum(sum(linked_group_dual[group_idx, child_idx] for child_idx in order_book["ComplexOrders"][group_idx]["children"]) for group_idx in linked_order_groups if order_idx == order_book["ComplexOrders"][group_idx]["parent"])
    +
    order_book["Orders"][order_idx]["mar"] * block_acceptance_lower_dual[order_idx] - block_acceptance_upper_dual[order_idx]
)
@constraint(euphemia_model, parent_block_activation_dual_constraint[order_idx in parent_orders],
    0 <=
    parent_block_activation_dual_rhs[order_idx]
)
#--

# Block order activation dual constraint -- CHILD BLOCKS ONLY (M4C)
@expression(euphemia_model, child_block_activation_dual_rhs[order_idx in child_orders],
    sum(linked_group_dual[group_idx, order_idx] for group_idx in linked_order_groups if order_idx in order_book["ComplexOrders"][group_idx]["children"])
    +
    order_book["Orders"][order_idx]["mar"] * block_acceptance_lower_dual[order_idx] - block_acceptance_upper_dual[order_idx]
)
@constraint(euphemia_model, child_block_activation_dual_constraint[order_idx in child_orders],
    0 <=
    child_block_activation_dual_rhs[order_idx]
)
#--

# Stepwise order acceptance complementarity constraints
@variable(euphemia_model, stepwise_acceptance_complementarity_aux[order_idx in stepwise_orders], Bin)
@variable(euphemia_model, stepwise_acceptance_switch_complementarity_aux[order_idx in stepwise_orders], Bin)

@constraint(euphemia_model, stepwise_acceptance_complementarity_ineq1[order_idx in stepwise_orders], stepwise_acceptance[order_idx] <= stepwise_acceptance_complementarity_aux[order_idx] * big_m_parameter)
@constraint(euphemia_model, stepwise_acceptance_complementarity_ineq2[order_idx in stepwise_orders], stepwise_dual_rhs[order_idx] <= (1 - stepwise_acceptance_complementarity_aux[order_idx]) * big_m_parameter)

@constraint(euphemia_model, stepwise_acceptance_switch_complementarity_ineq1[order_idx in stepwise_orders], stepwise_dual[order_idx] <= stepwise_acceptance_switch_complementarity_aux[order_idx] * big_m_parameter)
@constraint(euphemia_model, stepwise_acceptance_switch_complementarity_ineq2[order_idx in stepwise_orders], stepwise_acceptance[order_idx] - 1 >= (stepwise_acceptance_switch_complementarity_aux[order_idx] - 1) * big_m_parameter)
#--

# Block order activation complementarity constraints
@variable(euphemia_model, block_activation_complementarity_aux[order_idx in block_orders; (!(order_idx in exclusive_block_orders) && !(order_idx in linked_block_orders))], Bin)  # Not for blocks in complex groups
@constraint(euphemia_model, block_activation_complementarity_ineq1[order_idx in block_orders; (!(order_idx in exclusive_block_orders) && !(order_idx in linked_block_orders))], block_activation[order_idx] <= block_activation_complementarity_aux[order_idx] * big_m_parameter)
@constraint(euphemia_model, block_activation_complementarity_ineq2[order_idx in block_orders; (!(order_idx in exclusive_block_orders) && !(order_idx in linked_block_orders))], regular_block_activation_dual_rhs[order_idx] <= (1 - block_activation_complementarity_aux[order_idx]) * big_m_parameter)

# Exclusive block order group welfare complementarity constraints
@variable(euphemia_model, exclusive_block_complementarity_aux[order_idx in exclusive_block_orders], Bin)  # Blocks in exclusive groups
@constraint(euphemia_model, exclusive_block_complementarity_ineq1[order_idx in exclusive_block_orders], block_activation[order_idx] <= exclusive_block_complementarity_aux[order_idx] * big_m_parameter)
@constraint(euphemia_model, exclusive_block_complementarity_ineq2[order_idx in exclusive_block_orders], exclusive_block_activation_dual_rhs[order_idx] <= (1 - exclusive_block_complementarity_aux[order_idx]) * big_m_parameter)

@variable(euphemia_model, exclusive_group_complementarity_aux[group_idx in exclusive_order_groups], Bin)  # Blocks in exclusive groups
@constraint(euphemia_model, exclusive_group_complementarity_ineq1[group_idx in exclusive_order_groups], exclusive_group_dual[group_idx] <= exclusive_group_complementarity_aux[group_idx] * big_m_parameter)
@constraint(euphemia_model, exclusive_group_complementarity_ineq2[group_idx in exclusive_order_groups], 1 - sum(block_activation[order_idx] for order_idx in order_book["ComplexOrders"][group_idx]["members"]) <= (1 - exclusive_group_complementarity_aux[group_idx]) * big_m_parameter)

# Linked block order group welfare complementarity constraints
@variable(euphemia_model, parent_block_complementarity_aux[order_idx in parent_orders], Bin)  # Parent blocks
@constraint(euphemia_model, parent_block_complementarity_ineq1[order_idx in parent_orders], block_activation[order_idx] <= parent_block_complementarity_aux[order_idx] * big_m_parameter)
@constraint(euphemia_model, parent_block_complementarity_ineq2[order_idx in parent_orders], parent_block_activation_dual_rhs[order_idx] <= (1 - parent_block_complementarity_aux[order_idx]) * big_m_parameter)

@variable(euphemia_model, child_block_complementarity_aux[order_idx in child_orders], Bin)  # Child blocks
@constraint(euphemia_model, child_block_complementarity_ineq1[order_idx in child_orders], block_activation[order_idx] <= child_block_complementarity_aux[order_idx] * big_m_parameter)
@constraint(euphemia_model, child_block_complementarity_ineq2[order_idx in child_orders], child_block_activation_dual_rhs[order_idx] <= (1 - child_block_complementarity_aux[order_idx]) * big_m_parameter)

@variable(euphemia_model, linked_group_complementarity_aux[group_idx in linked_order_groups, order_idx in order_book["ComplexOrders"][group_idx]["children"]], Bin)
@constraint(euphemia_model, linked_group_complementarity_ineq1[group_idx in linked_order_groups, order_idx in order_book["ComplexOrders"][group_idx]["children"]], linked_group_dual[group_idx, order_idx] <= linked_group_complementarity_aux[group_idx, order_idx] * big_m_parameter)
@constraint(euphemia_model, linked_group_complementarity_ineq2[group_idx in linked_order_groups, order_idx in order_book["ComplexOrders"][group_idx]["children"]], block_activation[order_book["ComplexOrders"][group_idx]["parent"]] - block_activation[order_idx] <= (1 - linked_group_complementarity_aux[group_idx, order_idx]) * big_m_parameter)
#--


# Block order acceptance complementarity constraints
@variable(euphemia_model, block_acceptance_complementarity_aux[order_idx in block_orders], Bin)  #(M4C)
@constraint(euphemia_model, block_acceptance_complementarity_ineq1[order_idx in block_orders], block_acceptance[order_idx] <= block_acceptance_complementarity_aux[order_idx] * big_m_parameter)   #(M4C)
@constraint(euphemia_model, block_acceptance_complementarity_ineq2[order_idx in block_orders], block_acceptance_dual_rhs[order_idx] <= (1 - block_acceptance_complementarity_aux[order_idx]) * big_m_parameter) #(M4C)

@variable(euphemia_model, block_acceptance_lower_complementarity_aux[order_idx in block_orders], Bin)  #(M4C)
@constraint(euphemia_model, block_acceptance_lower_complementarity_ineq1[order_idx in block_orders], block_acceptance_lower_dual[order_idx] <= block_acceptance_lower_complementarity_aux[order_idx] * big_m_parameter)   #(M4C)
@constraint(euphemia_model, block_acceptance_lower_complementarity_ineq2[order_idx in block_orders], block_acceptance[order_idx] - order_book["Orders"][order_idx]["mar"] * block_activation[order_idx] <= (1 - block_acceptance_lower_complementarity_aux[order_idx]) * big_m_parameter) #(M4C)

@variable(euphemia_model, block_acceptance_upper_complementarity_aux[order_idx in block_orders], Bin)  #(M4C)
@constraint(euphemia_model, block_acceptance_upper_complementarity_ineq1[order_idx in block_orders], block_acceptance_upper_dual[order_idx] <= block_acceptance_upper_complementarity_aux[order_idx] * big_m_parameter)   #(M4C)
@constraint(euphemia_model, block_acceptance_upper_complementarity_ineq2[order_idx in block_orders], block_activation[order_idx] - block_acceptance[order_idx] <= (1 - block_acceptance_upper_complementarity_aux[order_idx]) * big_m_parameter) #(M4C)
#--

# Nodal power balance constraints (M4C)
if haskey(order_book["ATC"], "Flows")
    @constraint(euphemia_model, nodal_power_balance[node_idx in order_book["Nodes"], time_period in order_book["Periods"]],
        sum(stepwise_acceptance[order_idx] * order_book["Orders"][order_idx]["qtity"][time_period] for order_idx in orders_by_node[node_idx]["stepwise_orders"][time_period])
        +
        sum(block_acceptance[order_idx] * order_book["Orders"][order_idx]["qtity"][time_period] for order_idx in orders_by_node[node_idx]["block_orders"][time_period])
        ==
        sum(transmission_flow[flow_idx, time_period] for flow_idx in orders_by_node[node_idx]["flows_to"])
        -
        sum(transmission_flow[flow_idx, time_period] for flow_idx in orders_by_node[node_idx]["flows_from"])
    )
    # Note: since supply quantities are negative => inbound flows are also negative (outbound flows are positive in the from --> to direction)
else # no network
    @constraint(euphemia_model, nodal_power_balance[node_idx in order_book["Nodes"], time_period in order_book["Periods"]],
        sum(stepwise_acceptance[order_idx] * order_book["Orders"][order_idx]["qtity"][time_period] for order_idx in orders_by_node[node_idx]["stepwise_orders"][time_period])
        +
        sum(block_acceptance[order_idx] * order_book["Orders"][order_idx]["qtity"][time_period] for order_idx in orders_by_node[node_idx]["block_orders"][time_period])
        ==
        0)
end
#--

# Network security constraints
if haskey(order_book["ATC"], "LmTs")

    @expression(euphemia_model, transmission_security_lhs[security_idx in keys(order_book["ATC"]["LmTs"]), time_period in order_book["Periods"]; haskey(order_book["ATC"]["LmTs"][security_idx]["value"], time_period)],
        sum(transmission_flow[flow_idx, time_period] * order_book["ATC"]["LmTs"][security_idx]["incidence"][flow_idx] for flow_idx in keys(order_book["ATC"]["Flows"]))
    )

    @constraint(euphemia_model, transmission_security_limit[security_idx in keys(order_book["ATC"]["LmTs"]), time_period in order_book["Periods"]; haskey(order_book["ATC"]["LmTs"][security_idx]["value"], time_period)],
        transmission_security_lhs[security_idx, time_period] <= order_book["ATC"]["LmTs"][security_idx]["value"][time_period]
    )
end
#--

# Network security dual variables
if haskey(order_book["ATC"], "LmTs")
    @variable(euphemia_model, 0 <= security_constraint_dual[security_idx in keys(order_book["ATC"]["LmTs"]), time_period in keys(order_book["ATC"]["LmTs"][security_idx]["value"])]) # Security constraint dual
end
#--

# Network security complementarity constraints
if haskey(order_book["ATC"], "LmTs")
    @variable(euphemia_model, security_complementarity_aux[security_idx in keys(order_book["ATC"]["LmTs"]), time_period in keys(order_book["ATC"]["LmTs"][security_idx]["value"])], Bin)

    @constraint(euphemia_model, security_complementarity_ineq1[security_idx in keys(order_book["ATC"]["LmTs"]), time_period in keys(order_book["ATC"]["LmTs"][security_idx]["value"])],
        security_constraint_dual[security_idx, time_period] <= security_complementarity_aux[security_idx, time_period] * big_m_parameter)
    @constraint(euphemia_model, security_complementarity_ineq2[security_idx in keys(order_book["ATC"]["LmTs"]), time_period in keys(order_book["ATC"]["LmTs"][security_idx]["value"])],
        transmission_security_lhs[security_idx, time_period] - order_book["ATC"]["LmTs"][security_idx]["value"][time_period] >= (security_complementarity_aux[security_idx, time_period] - 1) * big_m_parameter)
end
#-

# ATC flow dual constraints
if haskey(order_book["ATC"], "LmTs")
    @constraint(euphemia_model, atc_flow_dual_balance[flow_idx in keys(order_book["ATC"]["Flows"]), time_period in order_book["Periods"]],
        sum(security_constraint_dual[security_idx, time_period] * order_book["ATC"]["LmTs"][security_idx]["incidence"][flow_idx] for security_idx in transmission_limits_by_time[time_period])
        +
        market_price[order_book["ATC"]["Flows"][flow_idx]["from"], time_period]
        -
        market_price[order_book["ATC"]["Flows"][flow_idx]["to"], time_period]
        ==
        0
    )
else
    @constraint(euphemia_model, atc_flow_dual_balance_simple[flow_idx in keys(order_book["ATC"]["Flows"]), time_period in order_book["Periods"]],
        +market_price[order_book["ATC"]["Flows"][flow_idx]["from"], time_period]
        -
        market_price[order_book["ATC"]["Flows"][flow_idx]["to"], time_period]
        ==
        0
    )
end
#--


# Price range constraints
if haskey(order_book, "Price_range")
    @constraint(euphemia_model, minimum_price[node_idx in order_book["Nodes"], time_period in order_book["Periods"]], market_price[node_idx, time_period] >= order_book["Price_range"]["lower"])
    @constraint(euphemia_model, maximum_price[node_idx in order_book["Nodes"], time_period in order_book["Periods"]], market_price[node_idx, time_period] <= order_book["Price_range"]["upper"])
end



# MPCC objective function (Market for Complementarity)
@objective(euphemia_model, Max,
    sum(stepwise_acceptance[order_idx] * (sum(order_book["Orders"][order_idx]["qtity"][time_period] for time_period in order_book["Periods"] if haskey(order_book["Orders"][order_idx]["qtity"], time_period))) * order_book["Orders"][order_idx]["price"]["p0"] for order_idx in stepwise_orders)
    +
    sum(block_acceptance[order_idx] * (sum(order_book["Orders"][order_idx]["qtity"][time_period] for time_period in order_book["Periods"] if haskey(order_book["Orders"][order_idx]["qtity"], time_period))) * order_book["Orders"][order_idx]["price"]["p0"] for order_idx in block_orders)
)



# Solve optimization model
println("\nSolving MPCC model...")
println("Using solver: $solver_name")
optimization_time = @elapsed optimize!(euphemia_model)

# Display solver results
println("\n" * "="^80)
println("OPTIMIZATION RESULTS")
println("="^80)
println("Solver: $solver_name")
println("Solution Status: $(termination_status(euphemia_model))")
println("Solve Time: $(round(optimization_time, digits=3)) seconds")
if has_values(euphemia_model)
    println("Objective Value (Total Market Welfare): $(round(JuMP.objective_value(euphemia_model), digits=3))")
else
    println("No solution found!")
    exit()
end
println("="^80)


println()
println("Stepwise Order Acceptance")
for order_idx in stepwise_orders
    println(order_idx, ": ", round(JuMP.value(stepwise_acceptance[order_idx]), digits=3), "/", round(JuMP.value(stepwise_dual[order_idx]), digits=3))
end


println()
println("Block Order Acceptance")
for order_idx in block_orders
    try
        println(order_idx, " [", order_book["Orders"][order_idx]["type"], "] : ", round(JuMP.value(block_acceptance[order_idx]), digits=3), "<=", round(JuMP.value(block_activation[order_idx]), digits=3), "/", round(JuMP.value(block_activation_dual[order_idx]), digits=3))
    catch
        if order_idx in exclusive_block_orders
            println(order_idx, " [", order_book["Orders"][order_idx]["type"], "] : ", round(JuMP.value(block_acceptance[order_idx]), digits=3), "<=", round(JuMP.value(block_activation[order_idx]), digits=3), "/", round(JuMP.value(block_activation[order_idx] * sum(exclusive_group_dual[group_idx] for group_idx in exclusive_order_groups if order_idx in order_book["ComplexOrders"][group_idx]["members"])), digits=3))
        elseif order_idx in parent_orders
            println(order_idx, " [", order_book["Orders"][order_idx]["type"], "] : ", round(JuMP.value(block_acceptance[order_idx]), digits=3), "<=", round(JuMP.value(block_activation[order_idx]), digits=3), "/", round(JuMP.value(block_activation_dual[order_idx]), digits=3))
        else
            println(order_idx, " [", order_book["Orders"][order_idx]["type"], "] : ", round(JuMP.value(block_acceptance[order_idx]), digits=3), "<=", round(JuMP.value(block_activation[order_idx]), digits=3))
        end
    end
end




println()

println("Nodal Market Prices")
for node_idx in order_book["Nodes"]
    for time_period in order_book["Periods"]
        println("Node_$node_idx@time_$time_period: ", round(JuMP.value(market_price[node_idx, time_period]), digits=3))
    end
end

if haskey(order_book["ATC"], "Flows")
    println()
    println("ATC Transmission Flows")
    for flow_idx in keys(sort(order_book["ATC"]["Flows"]))
        for time_period in order_book["Periods"]
            println("$flow_idx@time_$time_period: ", round(JuMP.value(transmission_flow[flow_idx, time_period]), digits=3))
        end
    end

end
