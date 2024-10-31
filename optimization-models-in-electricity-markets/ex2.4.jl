import Pkg
Pkg.add("JuMP")
Pkg.add("HiGHS")

using JuMP, HiGHS

model = Model(HiGHS.Optimizer)

@variable(model, 0 <= p1 <= 20)
@variable(model, 0 <= p2 <= 100)
@variable(model, 0 <= p3 <= 100)

@objective(model, Min, 500u1)


