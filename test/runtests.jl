"""
Euphemia Test Suite

Run with: julia --project=. test/runtests.jl
Or:       julia -e 'using Pkg; Pkg.test()'

Test Categories:
1. Core Unit Tests - Always run, no external dependencies
2. Integration Tests - Require database connection
3. Comparison Tests - Long-running analysis (run separately)
"""

using Test
using Euphemia
using Dates
using JuMP

println("=" ^ 70)
println("EUPHEMIA TEST SUITE")
println("=" ^ 70)
println()

# =============================================================================
# CORE UNIT TESTS
# These tests run on synthetic data and should always pass
# =============================================================================

@testset "Euphemia Core Tests" begin

    # -------------------------------------------------------------------------
    # Network Module Tests
    # Tests for network topology, transfer capacity, and ATC constraints
    # -------------------------------------------------------------------------
    @testset "Network Module" begin
        println("\n" * "=" ^ 60)
        println("Running Network Module Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_network_module.jl"))
    end

    # -------------------------------------------------------------------------
    # Multi-Zone MPCC Tests
    # Tests for multi-zone market clearing with transmission flows
    # -------------------------------------------------------------------------
    @testset "Multi-Zone MPCC" begin
        println("\n" * "=" ^ 60)
        println("Running Multi-Zone MPCC Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_multi_zone_mpcc.jl"))
    end

    # -------------------------------------------------------------------------
    # MPCC Market Clearing Tests
    # Tests for core MPCC solver functionality
    # -------------------------------------------------------------------------
    @testset "MPCC Market Clearing" begin
        println("\n" * "=" ^ 60)
        println("Running MPCC Market Clearing Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_mpcc.jl"))
    end

end

# =============================================================================
# SUMMARY
# =============================================================================

println("\n" * "=" ^ 70)
println("TEST SUITE COMPLETED")
println("=" ^ 70)
