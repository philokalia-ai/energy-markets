function Scenario(
    demand::Union{Float64, Vector{Float64}}, RES::Float64)
    return (demand = demand, RES = RES)
end