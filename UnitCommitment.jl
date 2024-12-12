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

    # TODO: initial coditions

    N = length(units[:, "unit"])
    T = length(scenario.demand) # TBD
    
    # uptime & downtime
    UT = 2 
    DT = 4

    # generation must be lower than maximum
    @variable(model, 0 <= g[i = 1:N, t = 1:T] <= units.p_max[i])

    # binary commitment variable 
    @variable(model, u[i = 1:N, t = 1:T], Bin)

    # binary startup & shutdown variables
    @variable(model, v[i = 1:N, t = 1:T], Bin)
    @variable(model, z[i = 1:N, t = 1:T], Bin)

    # generation of commited units must be within limits at all times
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] <= units.p_max[i] * u[i,t])
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] >= units.p_min[i] * u[i,t])

    # link commitment, startup, and shutdown
    @constraint(model, [i in 1:N, t in 2:T], u[i, t] = u[i, t-1] + v[i, t] - z[i, t])

    # startup & shutdown can't happen simultaneously (TODO: Ask prof)
    @constraint(model, [i = 1:N, t = 1:T], v[i, t] + z[i, t] <= 1)

    # minimum uptime
    @constraint(model, [i = 1:N, t = UT:T], 
        u[i, τ] >= sum(v[i, τ] for τ in t:t-(UT+1)))

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
