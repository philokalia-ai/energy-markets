using Euphemia
using Dates
using JuMP  # Import JuMP to access OPTIMAL status

bidding_zone = "GR"  # Example bidding zone

# Define date range for testing (just a few dates to verify the fix)
start_date = Date("2025-06-24")
end_date = Date("2025-06-26")
dates_to_test = collect(start_date:Day(1):end_date)

println("Testing Euphemia for bidding zone: $bidding_zone")
println("Testing dates: $(length(dates_to_test)) days from $start_date to $end_date")

# Test a single date first for data validation
test_date = Date("2025-06-24")
println("\n=== Testing Data Components for $(test_date) ===")

println("=== Testing Generators ===")
generators::Vector{Generator} = get_generators(test_date)
println("Number of generators: ", length(generators))
for (i, generator) in enumerate(generators[1:min(3, end)])
    println("Generator $i: $(generator.name) - $(generator.p_max) MW")
end

println("\n=== Testing Loads ===")
loads::Vector{Load} = get_loads(bidding_zone, test_date)
println("Number of load points: ", length(loads))
for (i, load) in enumerate(loads[1:min(3, end)])
    println("Load $i: $(load.timeslot) - $(load.value) MW")
end

println("\n=== Testing Renewables ===")
renewables_generation::Vector{RenewablesGenerationForecast} =
    get_generation_forecast_for_wind_and_solar(bidding_zone, test_date)
println("Number of renewables generation forecasts: ", length(renewables_generation))
for (i, renewable) in enumerate(renewables_generation[1:min(3, end)])
    println("Renewable $i: $(renewable.date_time) - $(renewable.aggregated_generation_forecast) MW")
end

println("\n" * "="^80)
println("=== Testing Unit Commitment for Multiple Dates ===")
println("="^80)

# Store results for analysis
results = Dict{Date,Any}()

for (i, date) in enumerate(dates_to_test)
    println("\n[$i/$(length(dates_to_test))] Testing Unit Commitment for $date...")
    
    try
        solution = test_unit_commitment(bidding_zone, date)
        
        if solution.status == OPTIMAL
            results[date] = (
                status = :optimal,
                cost = solution.total_cost,
                generators = length(solution.generators),
                net_demand = sum(solution.net_demand),
                renewable_total = sum(values(solution.renewable_generation))
            )
            
            println("  ✅ SUCCESS: Total cost = €$(round(solution.total_cost/1e6, digits=2))M, Net demand = $(round(sum(solution.net_demand))) MW")
        else
            results[date] = (status = :failed, reason = solution.status)
            println("  ❌ FAILED: Optimization status = $(solution.status)")
        end
        
    catch e
        results[date] = (status = :error, reason = string(e))
        println("  ❌ ERROR: $e")
    end
end

println("\n" * "="^80)
println("=== Summary of Results ===")
println("="^80)

successful_dates = [date for (date, result) in results if haskey(result, :status) && result.status == :optimal]
failed_dates = [date for (date, result) in results if haskey(result, :status) && result.status != :optimal]

println("Successful optimizations: $(length(successful_dates))/$(length(dates_to_test))")
println("Failed optimizations: $(length(failed_dates))")

if !isempty(successful_dates)
    costs = [results[date].cost for date in successful_dates]
    demands = [results[date].net_demand for date in successful_dates]
    
    println("\nCost Statistics:")
    println("  Average daily cost: €$(round(sum(costs)/length(costs)/1e6, digits=2))M")
    println("  Minimum daily cost: €$(round(minimum(costs)/1e6, digits=2))M on $(successful_dates[argmin(costs)])")
    println("  Maximum daily cost: €$(round(maximum(costs)/1e6, digits=2))M on $(successful_dates[argmax(costs)])")
    
    println("\nDemand Statistics:")
    println("  Average daily net demand: $(round(sum(demands)/length(demands))) MW")
    println("  Minimum daily net demand: $(round(minimum(demands))) MW on $(successful_dates[argmin(demands)])")
    println("  Maximum daily net demand: $(round(maximum(demands))) MW on $(successful_dates[argmax(demands)])")
end

if !isempty(failed_dates)
    println("\nFailed dates:")
    for date in failed_dates[1:min(5, end)]  # Show first 5 failures
        println("  $date: $(results[date].reason)")
    end
    if length(failed_dates) > 5
        println("  ... and $(length(failed_dates) - 5) more")
    end
end