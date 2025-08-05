#------------------------------------------------------------------------------------------#
using JuMP, CPLEX

ENV["TICKTOCK_MESSAGES"] = false
#------------------------------------------------------------------------------------------#

include(".//examples//beta_order_book_cexl.jl")

# Rename the main data structure for clarity
order_book = Obk  # Original was "Obk" - now "order_book"

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
euphemia_model = Model(CPLEX.Optimizer)
#MOI.set(euphemia_model, MOI.Silent(), true)

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
println(euphemia_model)
optimize!(euphemia_model)
#------------------------------------------------------------------------------------------#


#------------------------------------------------------------------------------------------#
println()
println("Total Market Welfare:", round(JuMP.objective_value(euphemia_model), digits=3))


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
