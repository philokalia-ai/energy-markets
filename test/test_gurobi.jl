#!/usr/bin/env julia

"""
Simple Gurobi Test Script
Tests if Gurobi is properly installed and licensed.
"""

using Pkg
using JuMP

println("🔧 GUROBI LICENSE TEST")
println("="^50)

# Check if Gurobi is available
println("\n📦 Checking Gurobi package...")
try
    using Gurobi
    println("✅ Gurobi package loaded successfully")
    
    # Check Gurobi version
    println("📋 Gurobi version: $(Gurobi.GRB_VERSION_MAJOR).$(Gurobi.GRB_VERSION_MINOR).$(Gurobi.GRB_VERSION_TECHNICAL)")
    
catch e
    println("❌ Failed to load Gurobi package: $e")
    println("💡 You may need to install it with: Pkg.add(\"Gurobi\")")
    exit(1)
end

# Test license by creating a simple model
println("\n🔐 Testing Gurobi license...")
try
    # Create a simple optimization model
    model = Model(Gurobi.Optimizer)
    
    # Add variables
    @variable(model, x >= 0)
    @variable(model, y >= 0)
    
    # Add constraints
    @constraint(model, x + y <= 1)
    
    # Set objective
    @objective(model, Max, 2x + y)
    
    # Solve
    println("🚀 Solving simple test problem...")
    optimize!(model)
    
    # Check solution
    if termination_status(model) == MOI.OPTIMAL
        println("✅ Gurobi license is working!")
        println("📊 Optimal solution:")
        println("   x = $(value(x))")
        println("   y = $(value(y))")
        println("   Objective = $(objective_value(model))")
    else
        println("❌ Optimization failed with status: $(termination_status(model))")
        exit(1)
    end
    
catch e
    println("❌ Gurobi license test failed: $e")
    if occursin("license", lowercase(string(e)))
        println("💡 This looks like a license issue. Check:")
        println("   - License file location")
        println("   - Environment variables (GRB_WLSACCESSID, etc.)")
        println("   - Network connectivity for WLS")
    end
    exit(1)
end

println("\n🎉 Gurobi is ready to use!")
println("="^50)