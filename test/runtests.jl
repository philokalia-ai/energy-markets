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
    # Generator Inference Tests
    # Tests for inferring ramp rates, p_min, uptime/downtime from synthetic data
    # -------------------------------------------------------------------------
    @testset "Generator Inference" begin
        println("\n" * "=" ^ 60)
        println("Running Generator Inference Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_generator_inference.jl"))
    end

    # -------------------------------------------------------------------------
    # Data Fetching Tests
    # DB integration tests for generators, loads, renewables, transfer capacities
    # -------------------------------------------------------------------------
    @testset "Data Fetching" begin
        println("\n" * "=" ^ 60)
        println("Running Data Fetching Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_data_fetching.jl"))
    end

    # -------------------------------------------------------------------------
    # Data Store Selection + Writable Offline Results
    # Pure backend-selection logic and the DuckDB writable results roundtrip
    # (self-contained: builds a synthetic DuckDB extract, needs no Postgres)
    # -------------------------------------------------------------------------
    @testset "Data Store Selection" begin
        println("\n" * "=" ^ 60)
        println("Running Data Store Selection Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_data_store_selection.jl"))
    end

    # -------------------------------------------------------------------------
    # DuckDB query-path performance changes
    # (self-contained: synthetic flows extract, no Postgres) — proves the
    # day-level physical-flow cache is behavior-identical to the original SQL
    # -------------------------------------------------------------------------
    @testset "DuckDB Perf Paths" begin
        println("\n" * "=" ^ 60)
        println("Running DuckDB Perf Path Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_duckdb_perf_paths.jl"))
    end

    # -------------------------------------------------------------------------
    # Initial Conditions Tests
    # Tests for generator initial state determination for UC optimization
    # -------------------------------------------------------------------------
    @testset "Initial Conditions" begin
        println("\n" * "=" ^ 60)
        println("Running Initial Conditions Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_initial_conditions.jl"))
    end

    # -------------------------------------------------------------------------
    # UC Enhancements Tests
    # Tests for cost breakdown, solver tuning, and batch query optimization
    # -------------------------------------------------------------------------
    @testset "UC Enhancements" begin
        println("\n" * "=" ^ 60)
        println("Running UC Enhancements Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_uc_enhancements.jl"))
    end

    # -------------------------------------------------------------------------
    # UC Caching Tests
    # Tests for caching Unit Commitment results in the database
    # -------------------------------------------------------------------------
    @testset "UC Caching" begin
        println("\n" * "=" ^ 60)
        println("Running UC Caching Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_uc_caching.jl"))
    end

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

    @testset "Scenario Hooks" begin
        println("\n" * "=" ^ 60)
        println("Running Scenario Hooks Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_scenario_hooks.jl"))
    end

    @testset "Multi-Zone Scenario API" begin
        println("\n" * "=" ^ 60)
        println("Running Multi-Zone Scenario API Tests...")
        println("=" ^ 60)
        # Pure ZoneScenario-resolution tests always run; the book-level guards
        # (SEE 5-zone, EU 39-zone, fleet_modifier, targeting) run when a DuckDB
        # EU extract is available (EUPHEMIA_EU_EXTRACT or data/public/…), else
        # skip cleanly. The solve-based two-pass propagation check is gated
        # behind MZ_SCENARIO_SOLVE=1.
        include(joinpath(@__DIR__, "test_multi_zone_scenario.jl"))
    end

    @testset "Zone Profiles" begin
        println("\n" * "=" ^ 60)
        println("Running Zone Profile Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_zone_profiles.jl"))
    end

end

# =============================================================================
# SUMMARY
# =============================================================================

println("\n" * "=" ^ 70)
println("TEST SUITE COMPLETED")
println("=" ^ 70)
