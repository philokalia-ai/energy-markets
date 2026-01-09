#!/usr/bin/env julia

"""
Simple debug test to isolate the hanging issue
"""

using Pkg
Pkg.activate(".")
using Dates
using Euphemia

println("🔍 DEBUGGING HANGING ISSUE")
println("="^40)

# Test individual zones and dates
test_date = Date(2024, 6, 18)  # Start with the first date that worked
problem_date = Date(2024, 6, 19)  # The date that hangs

test_zones = ["AL", "BG"]  # Skip GR for now

println("📅 Testing date $test_date (known working)...")
for zone in test_zones
    println("  🌍 Testing $zone...")
    try
        result = @timed generate_energy_prices(zone, test_date;
            order_method=:alternative,
            silent=true,
            save_to_db=false)
        prices = result.value
        elapsed = result.time

        if !isempty(prices)
            println("  ✅ $zone: $(length(prices)) prices in $(round(elapsed, digits=1))s")
        else
            println("  ❌ $zone: No prices generated in $(round(elapsed, digits=1))s")
        end
    catch e
        println("  💥 $zone: ERROR - $e")
    end
end

println("\n📅 Testing date $problem_date (problematic)...")
for zone in test_zones
    println("  🌍 Testing $zone on $problem_date...")
    try
        # Add timeout mechanism
        start_time = time()
        timeout = 120  # 2 minute timeout

        prices = Dict{String,Float64}()

        # Start a task that we can monitor
        task = @async begin
            generate_energy_prices(zone, problem_date;
                order_method=:alternative,
                silent=true,
                save_to_db=false)
        end

        # Wait with timeout
        while !istaskdone(task) && (time() - start_time) < timeout
            sleep(5)
            elapsed = time() - start_time
            println("    ⏱️  Still processing $zone... ($(round(elapsed, digits=1))s elapsed)")
        end

        if istaskdone(task)
            prices = fetch(task)
            elapsed = time() - start_time
            if !isempty(prices)
                println("  ✅ $zone: $(length(prices)) prices in $(round(elapsed, digits=1))s")
            else
                println("  ❌ $zone: No prices generated in $(round(elapsed, digits=1))s")
            end
        else
            println("  ⏰ $zone: TIMEOUT after $(round(timeout, digits=1))s - likely hanging")
            # Cancel the task
            Base.throwto(task, InterruptException())
        end

    catch e
        println("  💥 $zone: ERROR - $e")
    end
end

println("\n🏁 Debug test complete")