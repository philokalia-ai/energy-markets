using JuMP, HiGHS, Gurobi

# Define the model
model = Model(HiGHS.Optimizer)

# Objective: Global Economic surplus Maximization
@objective(
    model,
    Max,
    #=TODO: check euphemia public description annex C1 =#
    -sum(step_orders.ACCEPT[z, t, s, o] * step_orders.q[z, t, s, o] * step_orders.p_0[z, t, s, o] * res(o)
         for z in 1:2, t in 1:2, s in 1:2, o in 1:2)
    -
    sum(interpolated_orders.ACCEPT[z, t, s, o] * interpolated_orders.q[z, t, s, o] * (interpolated_orders.p_0[z, t, s, o] + interpolated_orders.ACCEPT[z, t, s, o] * (interpolated_orders.p_1[z, t, s, o] - interpolated_orders.p_0) / 2) * res(o) for z in 1:2, t in 1:2, s in 1:2, o in 1:2)
    -
    sum()
)

# Solve the model
optimize!(model)

