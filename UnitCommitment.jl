using CSV, DataFrames, JuMP, HiGHS, Gurobi
include("Generators.jl")
include("Scenario.jl")



function solve_unit_commitment(
    units,
    scenario
    )
    
    # TODO: choose optimizer
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    N = length(units[:, "unit"])
    T = length(scenario.demand) # TBD

    # generation must be lower than maximum
    @variable(model, 0 <= g[i = 1:N, t = 1:T] <= units.p_max[i])

    # binary commitment variables 
    @variable(model, u[i = 1:N, t = 1:T], Bin)

    # binary startup variable
    #@variable(model, v[i = 1:N, t = 1:T], Bin)

    # generation of commited units must be within limits
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] <= units.p_max[i] * u[i,t])
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] >= units.p_min[i] * u[i,t])

    # conventional Supply must equal Demand minus RES production at all times
    @constraint(model, [t in 1:T], sum(g[i, t] for i in 1:N) == scenario.demand[t] - scenario.RES)

    @objective(
        model,
        Min,
        # currently random costs
        sum(units.fixed_cost[i] * u[i, t] for i in 1:N, t in 1:T) + 
        sum(units.variable_cost[i] * g[i, t] for i in 1:N, t in 1:T) 
    )

    optimize!(model)
    status = termination_status(model)
    if status != OPTIMAL
        return (status = status,)
    end
    @assert primal_status(model) == FEASIBLE_POINT
    return (
        status = status,
        g = value.(g),
        u = value.(u),
        total_cost = objective_value(model),
    )

end

units = get_generators(true)
scenario = Scenario([62000.0, 63000.0, 61000.0, 58000.0, 67000.0] , 1000.0)

solution = solve_unit_commitment(units, scenario)

println("Dispatch of Generators: ", solution.g, " MW")
println("Commitments of Generators: ", solution.u)
println("Total cost: \$", solution.total_cost)
