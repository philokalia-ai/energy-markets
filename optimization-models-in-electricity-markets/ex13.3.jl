import Pkg
Pkg.add("JuMP")
Pkg.add("HiGHS")

using JuMP, HiGHS

model = Model(HiGHS.Optimizer)

@variable(model, 0 <= p1 <= 60)
@variable(model, 0 <= p2 <= 80)

@objective(model, Min, 20p1 + 50p2)

@constraint(model, c, p1 + p2 >= 100)

println(model)

optimize!(model)

println("termination Status: ", termination_status(model))

println("primal status ", primal_status(model))

println("dual status: ", dual_status(model))

println("objective value: ", objective_value(model))

println("value of p1: ", value(p1))

println("value of p2: ", value(p2))

println("shadow price of constraint: ", shadow_price(c))