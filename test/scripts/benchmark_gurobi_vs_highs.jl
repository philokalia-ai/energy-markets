#!/usr/bin/env julia
#
# Benchmark: Gurobi (2 workers) vs HiGHS (50 workers)
#
# Compares runtime for multi-zone market clearing on 2025-12-10
# using uc_based order method (which runs UC for each zone).
#
# Usage:
#   julia --project=. test/scripts/benchmark_gurobi_vs_highs.jl

using Euphemia, Dates
using Distributed

const TEST_DATE = Date(2025, 12, 10)
const ORDER_METHOD = :uc_based

println("=" ^ 70)
println("BENCHMARK: Gurobi (2 workers) vs HiGHS (50 workers)")
println("=" ^ 70)
println("Date: $TEST_DATE")
println("Order method: $ORDER_METHOD")
println()

# ============================================================================
# Run 1: Gurobi with 2 workers
# ============================================================================
println("=" ^ 70)
println("RUN 1: Gurobi with 2 workers")
println("=" ^ 70)

# Add 2 workers for Gurobi
gurobi_workers = 2
println("Adding $gurobi_workers workers...")
addprocs(gurobi_workers)
@everywhere using Euphemia

println("Workers: $(workers())")
println()

gurobi_start = time()
gurobi_result = run_multi_zone_market_clearing(
    TEST_DATE;
    order_method=ORDER_METHOD,
    optimizer="gurobi",
    save_to_db=false,
    parallel=true,
    silent=true
)
gurobi_elapsed = time() - gurobi_start

println()
println("Gurobi Results:")
println("  Status: $(gurobi_result.status)")
println("  Zones: $(length(gurobi_result.market_prices))")
println("  Solve time: $(round(gurobi_result.solve_time, digits=2)) seconds")
println("  Total time: $(round(gurobi_result.total_time, digits=2)) seconds")
println("  Wall clock: $(round(gurobi_elapsed, digits=2)) seconds")

# Clean up Gurobi workers
println()
println("Cleaning up Gurobi workers...")
rmprocs(workers())
println("Workers after cleanup: $(workers())")

# ============================================================================
# Run 2: HiGHS with 50 workers
# ============================================================================
println()
println("=" ^ 70)
println("RUN 2: HiGHS with 50 workers")
println("=" ^ 70)

# Add 50 workers for HiGHS
highs_workers = 50
println("Adding $highs_workers workers...")
addprocs(highs_workers)
@everywhere using Euphemia

println("Workers: $(length(workers()))")
println()

highs_start = time()
highs_result = run_multi_zone_market_clearing(
    TEST_DATE;
    order_method=ORDER_METHOD,
    optimizer="highs",
    save_to_db=false,
    parallel=true,
    silent=true
)
highs_elapsed = time() - highs_start

println()
println("HiGHS Results:")
println("  Status: $(highs_result.status)")
println("  Zones: $(length(highs_result.market_prices))")
println("  Solve time: $(round(highs_result.solve_time, digits=2)) seconds")
println("  Total time: $(round(highs_result.total_time, digits=2)) seconds")
println("  Wall clock: $(round(highs_elapsed, digits=2)) seconds")

# Clean up HiGHS workers
println()
println("Cleaning up HiGHS workers...")
rmprocs(workers())

# ============================================================================
# Comparison
# ============================================================================
println()
println("=" ^ 70)
println("COMPARISON")
println("=" ^ 70)
println()
println("| Metric          | Gurobi (2 workers) | HiGHS (50 workers) | Winner  |")
println("|-----------------|-------------------:|-------------------:|---------|")

gurobi_total = round(gurobi_elapsed, digits=2)
highs_total = round(highs_elapsed, digits=2)
winner_total = gurobi_total < highs_total ? "Gurobi" : "HiGHS"
println("| Wall clock (s)  | $(lpad(gurobi_total, 18)) | $(lpad(highs_total, 18)) | $winner_total |")

gurobi_solve = round(gurobi_result.solve_time, digits=2)
highs_solve = round(highs_result.solve_time, digits=2)
winner_solve = gurobi_solve < highs_solve ? "Gurobi" : "HiGHS"
println("| Solve time (s)  | $(lpad(gurobi_solve, 18)) | $(lpad(highs_solve, 18)) | $winner_solve |")

speedup = round(max(gurobi_total, highs_total) / min(gurobi_total, highs_total), digits=2)
println()
println("Speedup: $(speedup)x ($(winner_total) is faster)")
println()
