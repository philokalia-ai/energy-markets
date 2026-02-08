#!/usr/bin/env julia

# Test script for run_independent_clearing_for_all_zones()

using Pkg
Pkg.activate(".")

using Dates
using Euphemia

println("=" ^ 60)
println("Testing run_independent_clearing_for_all_zones()")
println("=" ^ 60)

# Test with a recent date
test_date = Date(2025, 12, 16)

println("\nTest Date: $test_date")
println("Order Method: :alternative")
println("Model: :mpcc")
println("Optimizer: highs")
println("Parallel: false")
println("Save to DB: false")
println()

try
    # Call the function with basic parameters
    result = Euphemia.run_independent_clearing_for_all_zones(
        test_date;
        order_method=:alternative,
        model=:mpcc,
        optimizer="highs",
        markup_factor=1.1,
        silent=false,  # Show solver output for debugging
        save_to_db=false,  # Don't save during test
        parallel=false,  # Sequential processing
        skip_existing=true
    )

    println("\n" * "=" ^ 60)
    println("✅ Test completed successfully!")
    println("=" ^ 60)
    println("\nResult summary:")
    println("  - Type: $(typeof(result))")
    if isa(result, Dict)
        println("  - Zones processed: $(length(result))")
        println("  - Zones: $(keys(result))")
    end

catch e
    println("\n" * "=" ^ 60)
    println("❌ Test failed with error:")
    println("=" ^ 60)
    println()
    showerror(stdout, e, catch_backtrace())
    println()
    exit(1)
end