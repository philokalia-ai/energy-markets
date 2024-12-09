using CSV, DataFrames, JuMP, HiGHS, Gurobi
include("Orders.jl")


function solve_unit_commitment(
    units,
    scenario
    )
    
    # TODO: choose optimizer
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    N = length(units)

    # generation must be lower than maximum
    @variable(model, 0 <= g[i = 1:N] <= generators[i].p_max)

    # binary commitment variables 
    @variable(model, u[i = 1:N], Bin)

    # generation of commited units must be within limits
    @constraint(model, [i = 1:N], g[i] <= generators[i].p_max * u[i])
    @constraint(model, [i = 1:N], g[i] >= generators[i].p_min * u[i])

    # papav, implementing block orders
    # @expression(m, generation_cost, sum(P_gb[g,b] * q[g,b] for g in G,  b in B) )
    # @objective(m, Min, generation_cost)
    
    @objective(
        model,
        Min,
        # current example doesn't have costs
        sum(generators[i].variable_cost * g[i] for i in 1:N) +
        sum(generators[i].fixed_cost * u[i] for i in 1:N)
    )
    return
end