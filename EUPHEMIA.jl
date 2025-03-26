using JuMP, HiGHS, Gurobi

# Define the model
model = Model(HiGHS.Optimizer)

# Objective: Global Economic surplus Maximization
@objective(model, Max,) #=TODO: check euphemia public description annex C1 =#

# Solve the model
optimize!(model)

