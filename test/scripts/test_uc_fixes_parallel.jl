#!/usr/bin/env julia
#
# Test UC Infeasibility Fixes (Parallel)
#
# Tests the fixes for unit commitment infeasibility:
# 1. Variable renewables (Wind, Solar) filtered from generators
# 2. Day-ahead load forecast used instead of actual load
#
# Uses automatic worker selection: 2 for Gurobi, 50 for HiGHS
#
# Usage:
#   julia --project=. test/scripts/test_uc_fixes_parallel.jl [optimizer]
#
#   optimizer: "highs" (default) or "gurobi"

using Euphemia, Dates
using Distributed

const TEST_DATE = Date(2025, 12, 10)
const ORDER_METHOD = :uc_based

# Parse command line argument for optimizer
optimizer = length(ARGS) >= 1 ? lowercase(ARGS[1]) : "highs"
if optimizer ∉ ["highs", "gurobi"]
    println("Invalid optimizer: $optimizer. Use 'highs' or 'gurobi'")
    exit(1)
end

# Worker count based on optimizer (Gurobi WLS license limits to 2)
num_workers = optimizer == "gurobi" ? 2 : 50

println("=" ^ 70)
println("UC INFEASIBILITY FIXES TEST (PARALLEL)")
println("=" ^ 70)
println("Date: $TEST_DATE")
println("Order method: $ORDER_METHOD")
println("Optimizer: $optimizer")
println("Workers: $num_workers")
println()

# Add workers
println("Adding $num_workers workers...")
addprocs(num_workers)
@everywhere using Euphemia

println("Workers active: $(length(workers()))")
println()

# Run multi-zone market clearing with parallel UC
println("=" ^ 70)
println("Running multi-zone market clearing...")
println("=" ^ 70)
println()

start_time = time()
result = run_coupled_market_clearing(
    TEST_DATE;
    order_method=ORDER_METHOD,
    optimizer=optimizer,
    save_to_db=false,
    parallel=true,
    silent=false,
    force_rerun=true  # Force fresh UC solves to use new shortage variable
)
elapsed = time() - start_time

# Results summary
println()
println("=" ^ 70)
println("RESULTS SUMMARY")
println("=" ^ 70)
println()

println("Overall Status: $(result.status)")
println("Solve time: $(round(result.solve_time, digits=2)) seconds")
println("Total time: $(round(result.total_time, digits=2)) seconds")
println("Wall clock: $(round(elapsed, digits=2)) seconds")
println()

# Count feasible/infeasible zones
zones = collect(keys(result.market_prices))
feasible_count = 0
infeasible_zones = String[]

for zone in sort(zones)
    prices = result.market_prices[zone]
    price_values = prices isa Dict ? collect(values(prices)) : prices
    if !isempty(price_values) && all(p -> !isnan(p) && !isinf(p), price_values)
        global feasible_count += 1
    else
        push!(infeasible_zones, zone)
    end
end

println("Feasible zones: $feasible_count / $(length(zones))")
println()

if !isempty(infeasible_zones)
    println("Infeasible zones:")
    for zone in sort(infeasible_zones)
        println("  - $zone")
    end
    println()
end

# Show sample prices for a few feasible zones
println("Sample prices (first 4 periods):")
sample_zones = sort(zones)[1:min(5, length(zones))]
for zone in sample_zones
    prices = result.market_prices[zone]
    price_values = prices isa Dict ? sort(collect(values(prices))) : prices
    if !isempty(price_values) && length(price_values) >= 4
        sample = round.(price_values[1:4], digits=2)
        println("  $zone: $sample ...")
    end
end
println()

# Clean up workers
println("Cleaning up workers...")
rmprocs(workers())

println()
println("Test completed in $(round(elapsed, digits=2)) seconds")
println()
