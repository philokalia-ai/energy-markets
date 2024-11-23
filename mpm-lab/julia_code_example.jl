

# Load required packages
using CSV, DataFrames, JuMP, Gurobi #, GLPK


# Set .csv files' directory
csv_directory = pwd() * "/mpm-lab/"

# Load .csv files
generating_units = DataFrame(CSV.File(csv_directory * "generating_units.csv"))
generating_units_orders = DataFrame(CSV.File(csv_directory * "generating_units_orders.csv"))
system_requirements = DataFrame(CSV.File(csv_directory * "system_requirements.csv"))

# Initialize general data
total_units = length(generating_units[:, "generating_unit"])


# Initialize Sets
G = generating_units[:, "generating_unit"]
B = Set{String}("B$(b)" for b=1:3)


# Initialize parameters
RES         = system_requirements[1, "res"]
D           = system_requirements[1, "demand"]

Q_gb = Dict{Tuple{String, String}, Float64}()
P_gb = Dict{Tuple{String, String}, Float64}()

for g = 1 : length(generating_units_orders[:, "generating_unit"])
    for b in [1, 2, 3]
        # Initialize units and blocks
        unit = generating_units_orders[g, "generating_unit"]    
        block = "B$(b)"

        # Pass values to parameters
        Q_gb[(unit, block)] = generating_units_orders[g, "block_$(b)"]
        P_gb[(unit, block)] = generating_units_orders[g, "price_$(b)"]
    end
end

Pmax_g      = Dict{String, Float64}(generating_units[g, "generating_unit"] => generating_units[g, "p_max"] for g = 1 : total_units)
Pmin_g      = Dict{String, Float64}(generating_units[g, "generating_unit"] => generating_units[g, "p_min"] for g = 1 : total_units)

# Define model
# m = Model(GLPK.Optimizer)
m = Model(Gurobi.Optimizer)



# Define variables
@variable(m, 0 <= q[G,B])
@variable(m, 0 <= p[G])
@variable(m, u[G], Bin)
#@variable(m, 0 <= u[G] <= 1)




# Define Objective function

@expression(m, generation_cost, sum(P_gb[g,b] * q[g,b] for g in G,  b in B) )

@objective(m, Min, generation_cost)

# Define COnstraints
# i. Generating units' output constraints
@constraint(m, QuantityLimit[g=G,b=B], q[g,b] <= Q_gb[g,b])
@constraint(m, PowerOutput[g=G], p[g] == sum(q[g,b] for b in B))

# ii. Generating units' limits constraints
@constraint(m, GenerationLowerLimit[g=G], Pmin_g[g] * u[g] <= p[g])
@constraint(m, GenerationUpperLimit[g=G], p[g] <= Pmax_g[g] * u[g])

# iii. Power balance constraint
@constraint(m, PowerBalance, sum(q[g,b] for g in G for b in B) + RES == D)
# @constraint(m, PowerBalance, sum(p[g] for g in G) + RES == D)


# Solve optimization problem
optimize!(m)

println("###############################################")
println(">> ")
println(">> Optimization problem executed successfully!!")
println(">>")
println("###############################################")

# Display results
println("# System Cost ###############################################")
final_generation_cost = round(value(generation_cost), digits=2)
println("Generation Cost: $(final_generation_cost) €")
println("")

println("# Power Output ##############################################")
for g in G
    power_output = round(value(p[g]), digits=2)
    println("$(g) : $(power_output) MWh")
end
println("")

#dual(PowerBalance)