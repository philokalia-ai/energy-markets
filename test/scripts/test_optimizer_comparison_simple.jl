#!/usr/bin/env julia

using Pkg
Pkg.activate(".")

using Euphemia
using Printf
using Statistics
using Dates

# Test configuration
const TEST_ZONE = "ES"
const TEST_DATE = Date(2025, 10, 1)
const ORDER_METHOD = :uc_based
const MODEL = :mpcc

println("OPTIMIZER PERFORMANCE COMPARISON")
println("="^50)
println("Date: ", TEST_DATE)
println("Zone: ", TEST_ZONE)
println("Order Method: ", ORDER_METHOD)
println("Model: ", MODEL)
println("="^50)

function run_test(optimizer_name)
    println("\nTesting ", optimizer_name, "...")

    start_time = time()

    try
        prices = generate_energy_prices(TEST_ZONE, TEST_DATE;
            order_method=ORDER_METHOD,
            model=MODEL,
            optimizer=optimizer_name,
            save_to_db=false,
            silent=true)

        elapsed = time() - start_time

        if length(prices) > 0
            min_price = minimum(values(prices))
            max_price = maximum(values(prices))
            println("SUCCESS: ", round(elapsed, digits=2), " seconds")
            println("Periods: ", length(prices))
            println("Price range: €", round(min_price, digits=2), " - €", round(max_price, digits=2), "/MWh")
            return elapsed, true
        else
            println("FAILED: No prices generated")
            return elapsed, false
        end

    catch e
        elapsed = time() - start_time
        println("ERROR: ", e)
        return elapsed, false
    end
end

# Test both optimizers
gurobi_time, gurobi_success = run_test("gurobi")
sleep(2)
highs_time, highs_success = run_test("highs")

# Compare results
println("\n" * "="^50)
println("COMPARISON RESULTS")
println("="^50)

if gurobi_success && highs_success
    time_diff = abs(gurobi_time - highs_time)

    if time_diff < 0.1  # Less than 0.1 second difference = tie
        println("RESULT: Both optimizers have essentially identical performance")
        println("Gurobi: ", round(gurobi_time, digits=2), "s")
        println("HiGHS: ", round(highs_time, digits=2), "s")
        println("Difference: ", round(time_diff, digits=2), "s")
    elseif gurobi_time < highs_time
        speedup = highs_time / gurobi_time
        println("Gurobi is ", round(speedup, digits=2), "x FASTER than HiGHS")
        println("Gurobi: ", round(gurobi_time, digits=2), "s")
        println("HiGHS: ", round(highs_time, digits=2), "s")
        println("Time saved: ", round(highs_time - gurobi_time, digits=2), "s")
    else
        speedup = gurobi_time / highs_time
        println("HiGHS is ", round(speedup, digits=2), "x FASTER than Gurobi")
        println("HiGHS: ", round(highs_time, digits=2), "s")
        println("Gurobi: ", round(gurobi_time, digits=2), "s")
        println("Time saved: ", round(gurobi_time - highs_time, digits=2), "s")
    end
else
    println("Cannot compare - one or both tests failed")
    println("Gurobi success: ", gurobi_success)
    println("HiGHS success: ", highs_success)
end

println("\nTest completed!")