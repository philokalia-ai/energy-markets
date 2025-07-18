using Euphemia
using Dates

# Test individual components
println("=== Testing Generators ===")
generators::Vector{Generator} = get_generators(Date("2018-06-24"))
println("Number of generators: ", length(generators))
for (i, generator) in enumerate(generators[1:min(3, end)])
    println("Generator $i: $(generator.name) - $(generator.p_max) MW")
end

println("\n=== Testing Loads ===")
loads::Vector{Load} = get_loads("GR", Date("2025-06-24"))
println("Number of load points: ", length(loads))
for (i, load) in enumerate(loads[1:min(3, end)])
    println("Load $i: $(load.timeslot) - $(load.value) MW")
end

println("\n=== Testing Renewables ===")
renewables_generation::Vector{RenewablesGenerationForecast} =
    get_generation_forecast_for_wind_and_solar("BE", Date("2014-12-03"))
println("Number of renewables generation forecasts: ", length(renewables_generation))
for (i, renewable) in enumerate(renewables_generation[1:min(3, end)])
    println("Renewable $i: $(renewable.date_time) - $(renewable.aggregated_generation_forecast) MW")
end

println("\n=== Testing Unit Commitment ===")
solution = test_unit_commitment()