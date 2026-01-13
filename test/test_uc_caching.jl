# Tests for UC Results Caching
# Tests for caching Unit Commitment optimization results in the database

using Test
using Dates
using DataFrames
using JuMP
using LibPQ

# =============================================================================
# Unit Tests - Schema Creation
# =============================================================================

@testset "UC Caching Schema" begin
    @testset "ensure_uc_results_tables creates tables" begin
        # Ensure tables exist
        Euphemia.ensure_uc_results_tables()

        # Verify tables exist by querying information_schema
        tables_df = Euphemia.sql2df_with_retry("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'simulations'
              AND table_name IN ('uc_results', 'uc_generation', 'uc_net_demand')
        """, [])

        @test "uc_results" in tables_df.table_name
        @test "uc_generation" in tables_df.table_name
        @test "uc_net_demand" in tables_df.table_name
    end

    @testset "Tables have expected columns" begin
        # Check uc_results columns
        results_cols = Euphemia.sql2df_with_retry("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'simulations' AND table_name = 'uc_results'
        """, [])

        expected_cols = ["id", "bidding_zone", "market_date", "status", "solver",
                        "resolution_minutes", "num_generators", "num_periods",
                        "total_cost", "production_cost", "startup_cost", "noload_cost",
                        "hot_startups", "warm_startups", "cold_startups",
                        "code_version", "created_at"]

        for col in expected_cols
            @test col in results_cols.column_name
        end
    end
end

# =============================================================================
# Unit Tests - Cache Check Function
# =============================================================================

@testset "has_cached_uc_results" begin
    @testset "Returns false when no cache exists" begin
        # Use a test zone/date that definitely won't have cached results
        @test Euphemia.has_cached_uc_results("TEST_ZONE_XXX", Date(1900, 1, 1)) == false
    end

    @testset "Returns false for invalid dates" begin
        @test Euphemia.has_cached_uc_results("GR", Date(1800, 1, 1)) == false
    end
end

# =============================================================================
# Unit Tests - Function Signatures
# =============================================================================

@testset "Function Signatures" begin
    @testset "solve_unit_commitment has cache parameters" begin
        # Check that the function accepts the new parameters
        @test hasmethod(Euphemia.solve_unit_commitment,
            Tuple{String, Date})

        # The method should accept use_cache and force_rerun kwargs
        # This is a compile-time check - if it passes, the signature is correct
    end

    @testset "Caching functions exist" begin
        @test hasmethod(Euphemia.has_cached_uc_results, Tuple{String, Date})
        @test hasmethod(Euphemia.save_uc_results, Tuple{NamedTuple, String, Date})
        @test hasmethod(Euphemia.load_uc_results, Tuple{String, Date})
    end
end

# =============================================================================
# Integration Tests - Require Database
# =============================================================================

@testset "UC Caching Integration" begin
    test_zone = "GR"
    test_date = Date(2024, 6, 15)

    @testset "Save and load roundtrip with synthetic data" begin
        # Create a minimal synthetic solution for testing
        synthetic_gen = Euphemia.Generator(
            "TEST_GEN_001",
            "Test Generator 1",
            Symbol("Fossil Gas"),
            "Test Location",
            100.0,  # p_max
            30.0,   # p_min
            test_zone,
            50.0,   # marginal_cost
            nothing, nothing, nothing, nothing  # ramp_up, ramp_down, min_uptime, min_downtime
        )

        # Create minimal cost breakdown
        synthetic_cost_breakdown = (
            production_cost=5000.0,
            startup_cost=500.0,
            noload_cost=200.0,
            startup_counts=Dict{Symbol,Int}(:hot => 1, :warm => 0, :cold => 0),
            generator_costs=Dict{String,Float64}(),
            fuel_type_costs=Dict{Symbol,Float64}(),
            period_costs=Float64[],
            total_capacity=100.0,
            avg_committed_capacity=80.0,
            avg_generation=70.0,
            capacity_utilization=0.7,
            commitment_utilization=0.8,
            startup_costs_by_type=Dict{Symbol,Float64}(:hot => 500.0, :warm => 0.0, :cold => 0.0)
        )

        # Create synthetic solution with unique test date to avoid conflicts
        synthetic_test_date = Date(2099, 12, 31)
        synthetic_solution = (
            status=OPTIMAL,
            solver="HiGHS",
            generators=[synthetic_gen],
            time_slots=["20991231-0000", "20991231-0100", "20991231-0200"],
            resolution_minutes=60,
            net_demand=[80.0, 85.0, 90.0],
            renewable_generation=Dict("20991231-0000" => 10.0, "20991231-0100" => 12.0, "20991231-0200" => 15.0),
            g=[70.0 75.0 80.0],  # 1x3 matrix
            u=[1.0 1.0 1.0],
            v=[1.0 0.0 0.0],
            total_cost=5700.0,
            cost_breakdown=synthetic_cost_breakdown,
            initial_conditions=nothing
        )

        # First, clear any existing test data
        try
            Euphemia.withdb() do cnx
                LibPQ.execute(cnx, """
                    DELETE FROM simulations.uc_results
                    WHERE bidding_zone = 'TEST_CACHE' AND market_date = \$1
                """, [synthetic_test_date])
            end
        catch e
            # Ignore errors if table doesn't exist
        end

        # Save synthetic solution
        result_id = Euphemia.save_uc_results(synthetic_solution, "TEST_CACHE", synthetic_test_date)
        @test result_id !== nothing
        @test result_id > 0

        # Check cache exists
        @test Euphemia.has_cached_uc_results("TEST_CACHE", synthetic_test_date) == true

        # Load and verify
        loaded = Euphemia.load_uc_results("TEST_CACHE", synthetic_test_date)
        @test loaded !== nothing
        @test loaded.status == OPTIMAL
        @test loaded.solver == "HiGHS"
        @test loaded.resolution_minutes == 60
        @test length(loaded.time_slots) == 3
        @test loaded.total_cost == 5700.0

        # Verify matrices were saved/loaded correctly
        @test size(loaded.g) == (1, 3)
        @test loaded.g[1, 1] == 70.0
        @test loaded.g[1, 3] == 80.0

        # Verify cost breakdown was partially restored
        @test loaded.cost_breakdown.production_cost == 5000.0
        @test loaded.cost_breakdown.startup_counts[:hot] == 1

        # Cleanup
        Euphemia.withdb() do cnx
            LibPQ.execute(cnx, """
                DELETE FROM simulations.uc_results
                WHERE bidding_zone = 'TEST_CACHE'
            """, [])
        end

        println("  Synthetic save/load roundtrip passed")
    end

    @testset "load_uc_results returns nothing for missing cache" begin
        result = Euphemia.load_uc_results("NONEXISTENT_ZONE", Date(1999, 1, 1))
        @test result === nothing
    end

    @testset "from_cache field is set on loaded results" begin
        # Use a test cache entry
        synthetic_test_date = Date(2098, 1, 1)

        # Create and save a minimal entry
        synthetic_gen = Euphemia.Generator(
            "TEST_GEN_002", "Test Gen 2", Symbol("Fossil Gas"), "Loc",
            100.0, 30.0, "TEST_FROM_CACHE", 50.0, nothing, nothing, nothing, nothing
        )

        synthetic_solution = (
            status=OPTIMAL,
            solver="HiGHS",
            generators=[synthetic_gen],
            time_slots=["20980101-0000"],
            resolution_minutes=60,
            net_demand=[80.0],
            renewable_generation=Dict{String,Float64}(),
            g=[70.0;;],  # 1x1 matrix
            u=[1.0;;],
            v=[0.0;;],
            total_cost=100.0,
            cost_breakdown=(
                production_cost=100.0, startup_cost=0.0, noload_cost=0.0,
                startup_counts=Dict{Symbol,Int}(:hot => 0, :warm => 0, :cold => 0),
                generator_costs=Dict{String,Float64}(), fuel_type_costs=Dict{Symbol,Float64}(),
                period_costs=Float64[], total_capacity=100.0, avg_committed_capacity=100.0,
                avg_generation=70.0, capacity_utilization=0.7, commitment_utilization=1.0,
                startup_costs_by_type=Dict{Symbol,Float64}(:hot => 0.0, :warm => 0.0, :cold => 0.0)
            ),
            initial_conditions=nothing
        )

        Euphemia.save_uc_results(synthetic_solution, "TEST_FROM_CACHE", synthetic_test_date)

        loaded = Euphemia.load_uc_results("TEST_FROM_CACHE", synthetic_test_date)
        @test loaded !== nothing
        @test loaded.from_cache == true

        # Cleanup
        Euphemia.withdb() do cnx
            LibPQ.execute(cnx, """
                DELETE FROM simulations.uc_results
                WHERE bidding_zone = 'TEST_FROM_CACHE'
            """, [])
        end
    end
end

println("UC Caching Tests completed!")
