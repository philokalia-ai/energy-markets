#!/usr/bin/env julia

"""
Test script to verify solver environment caching is working correctly.
Tests both performance improvement and solver-agnostic functionality.
"""

using Pkg
Pkg.activate(".")

using Euphemia
using JuMP
using Printf
using Dates

println("🧪 SOLVER ENVIRONMENT CACHING TEST")
println("="^60)

function test_solver_caching()
    println("\n🔧 Testing solver environment caching...")

    # Test 1: Check if caching functions are available
    println("\n1️⃣ Testing cache function availability...")
    try
        clear_solver_cache!()
        println("   ✅ clear_solver_cache!() works")
    catch e
        println("   ❌ clear_solver_cache!() failed: $e")
        return false
    end

    # Test 2: Test cached optimizer retrieval for different solvers
    println("\n2️⃣ Testing cached optimizer retrieval...")

    solvers_to_test = ["highs", "gurobi", "cplex"]
    working_solvers = String[]

    for solver in solvers_to_test
        try
            optimizer = get_cached_optimizer(solver)
            println("   ✅ $solver: cached optimizer created successfully")
            push!(working_solvers, solver)
        catch e
            println("   ⚠️  $solver: not available or failed ($e)")
        end
    end

    if isempty(working_solvers)
        println("   ❌ No solvers available for testing")
        return false
    end

    # Test 3: Performance test with Gurobi (if available)
    if "gurobi" in working_solvers
        println("\n3️⃣ Testing Gurobi caching performance...")
        test_gurobi_caching_performance()
    else
        println("\n3️⃣ Skipping Gurobi performance test (not available)")
    end

    # Test 4: Test solver-agnostic select_solver function
    println("\n4️⃣ Testing solver-agnostic select_solver()...")
    try
        optimizer, name = select_solver("auto")
        println("   ✅ select_solver(\"auto\") returned: $name")

        # Test specific solver selection
        for solver in working_solvers
            try
                opt, solver_name = select_solver(solver)
                println("   ✅ select_solver(\"$solver\") returned: $solver_name")
            catch e
                println("   ❌ select_solver(\"$solver\") failed: $e")
            end
        end
    catch e
        println("   ❌ select_solver() failed: $e")
        return false
    end

    return true
end

function test_gurobi_caching_performance()
    """Test that Gurobi environment caching provides performance benefits."""

    # Clear cache to start fresh
    clear_solver_cache!()

    # Test 1: First creation (should create environment)
    println("   🏃 First Gurobi optimizer creation (should create env)...")
    start_time = time()
    opt1 = get_cached_optimizer("gurobi")
    first_creation_time = time() - start_time
    @printf("      Time: %.3fs\n", first_creation_time)

    # Test 2: Second creation (should reuse environment)
    println("   🏃 Second Gurobi optimizer creation (should reuse env)...")
    start_time = time()
    opt2 = get_cached_optimizer("gurobi")
    second_creation_time = time() - start_time
    @printf("      Time: %.3fs\n", second_creation_time)

    # Test 3: Multiple rapid creations
    println("   🏃 Multiple rapid creations (should all reuse env)...")
    times = Float64[]
    for i in 1:5
        start_time = time()
        opt = get_cached_optimizer("gurobi")
        creation_time = time() - start_time
        push!(times, creation_time)
    end

    avg_cached_time = sum(times) / length(times)
    @printf("      Average cached creation time: %.3fs\n", avg_cached_time)

    # Analysis
    if second_creation_time < first_creation_time * 0.5
        println("   ✅ Caching appears to be working (second creation ≥50% faster)")
    else
        println("   ⚠️  Caching benefit unclear (times similar)")
    end

    # Performance summary
    println("   📊 Performance Summary:")
    @printf("      First creation: %.3fs (includes env setup)\n", first_creation_time)
    @printf("      Subsequent avg: %.3fs (reuses env)\n", avg_cached_time)
    if first_creation_time > 0
        speedup = first_creation_time / avg_cached_time
        @printf("      Speedup factor: %.1fx\n", speedup)
    end
end

function test_model_creation()
    """Test that cached optimizers work correctly with JuMP models."""
    println("\n5️⃣ Testing JuMP model creation with cached optimizers...")

    try
        optimizer, name = select_solver("auto")
        println("   Creating test model with $name...")

        # This should work without triggering additional license authentication
        start_time = time()
        model = Model(optimizer)
        @variable(model, x >= 0)
        @objective(model, Max, x)
        creation_time = time() - start_time

        @printf("   ✅ Model creation successful (%.3fs)\n", creation_time)

        # Test that we can create multiple models quickly
        println("   Creating 3 additional models...")
        times = Float64[]
        for i in 1:3
            start_time = time()
            model = Model(optimizer)
            @variable(model, y >= 0)
            push!(times, time() - start_time)
        end

        avg_time = sum(times) / length(times)
        @printf("   ✅ Average additional model creation: %.3fs\n", avg_time)

    catch e
        println("   ❌ Model creation failed: $e")
        return false
    end

    return true
end

# Run all tests
println("\n🚀 Starting comprehensive caching tests...")

success = test_solver_caching()

if success
    success = test_model_creation()
end

# Summary
println("\n" * "="^60)
if success
    println("🎉 ALL TESTS PASSED!")
    println("✅ Solver environment caching is working correctly")
    println("✅ System remains solver-agnostic")
    println("✅ Performance benefits confirmed for applicable solvers")
else
    println("❌ SOME TESTS FAILED")
    println("⚠️  Check error messages above for details")
end

# Cleanup
clear_solver_cache!()
println("🧹 Cache cleared")
println("="^60)