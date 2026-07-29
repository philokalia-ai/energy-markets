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
    # -------------------------------------------------------------------------
    # UC Enhancements Tests
    # Tests for cost breakdown, solver tuning, and batch query optimization
    # -------------------------------------------------------------------------
    # -------------------------------------------------------------------------
    # UC Caching Tests
    # Tests for caching Unit Commitment results in the database
    # -------------------------------------------------------------------------
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

    @testset "Forecast Tracking" begin
        println("\n" * "=" ^ 60)
        println("Running Forecast Tracking Tests...")
        println("=" ^ 60)
        # Pure logic only (eligibility gate, lead-day arithmetic, realized-day
        # write guard, scoring math, JSON serializer) — no DB, no solver.
        include(joinpath(@__DIR__, "test_forecast_tracking.jl"))
    end

    @testset "Weather RES" begin
        println("\n" * "=" ^ 60)
        println("Running Weather RES Tests...")
        println("=" ^ 60)
        # Pure logic only (power curve, sun elevation, feature vectors,
        # ensemble averaging, open-meteo response parsing on literal JSON)
        # — no network, no DB, no solver.
        include(joinpath(@__DIR__, "test_weather_res.jl"))
    end

    @testset "Weather Load Model" begin
        println("\n" * "=" ^ 60)
        println("Running Weather Load Model Tests...")
        println("=" ^ 60)
        # Pure logic only (feature vectors, EU-DST local time, Easter/holiday
        # computus, ridge fit/predict, open-meteo parsing) — no network/DB.
        include(joinpath(@__DIR__, "test_weather_load.jl"))
    end

    @testset "Extract Refresh Logic" begin
        println("\n" * "=" ^ 60)
        println("Running Extract Refresh Logic Tests...")
        println("=" ^ 60)
        # Pure logic + in-memory DuckDB only (where-clause construction,
        # watermark bounds, ERA5 cell fetch window, seed/append machinery with
        # a stubbed source) — no Postgres, no network, no extract file.
        include(joinpath(@__DIR__, "test_extract_refresh_logic.jl"))
    end

    @testset "15-min Resolution" begin
        println("\n" * "=" ^ 60)
        println("Running 15-min Resolution (upsample) Tests...")
        println("=" ^ 60)
        include(joinpath(@__DIR__, "test_15min_resolution.jl"))
    end

    @testset "Price reconstruction (pure, DB-free)" begin
        println("\n" * "=" ^ 60)
        println("Running competitive price reconstruction unit tests...")
        println("=" ^ 60)
        # The arithmetic that decides every published price, now callable without
        # a solver. Two testsets deliberately pin PRESERVED defects so a Phase-2
        # fix has to change a test on purpose.
        include(joinpath(@__DIR__, "test_price_reconstruction.jl"))
    end

    @testset "Code review 2026-07" begin
        println("\n" * "=" ^ 60)
        println("Running July 2026 code-review regression tests...")
        println("=" ^ 60)
        # DB-free. Two @test_broken entries document defects that are real,
        # reproduced, and deliberately NOT fixed here because they change every
        # price and need their own code_version + backfill
        # (docs/experiments/review-2026-07.md).
        include(joinpath(@__DIR__, "test_review_2026_07.jl"))
    end

end

# =============================================================================
# SUMMARY
# =============================================================================

println("\n" * "=" ^ 70)
println("TEST SUITE COMPLETED")
println("=" ^ 70)
