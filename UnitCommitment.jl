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

    # generation must be lower than maximum
    @variable(model, 0 <= g[i = 1:N] <= units.p_max[i])

    # binary commitment variables 
    @variable(model, u[i = 1:N], Bin)

    # generation of commited units must be within limits
    @constraint(model, [i = 1:N], g[i] <= units.p_max[i] * u[i])
    @constraint(model, [i = 1:N], g[i] >= units.p_min[i] * u[i])

    # conventional Supply must equal Demand minus RES production
    @constraint(model, sum(g[i] for i in 1:N) == scenario.demand - scenario.RES)

    @objective(
        model,
        Min,
        # currently random costs
        sum(units.fixed_cost[i] * u[i] for i in 1:N) + 
        sum(units.variable_cost[i] * g[i] for i in 1:N) 
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
scenario = Scenario(62000.0, 1000.0)

solution = solve_unit_commitment(units, scenario)

println("Dispatch of Generators: ", solution.g, " MW")
println("Commitments of Generators: ", solution.u)
println("Total cost: \$", solution.total_cost)
