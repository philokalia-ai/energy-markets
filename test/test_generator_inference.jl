# Tests for Generator Parameter Inference
# Includes both synthetic data tests and database integration tests

using Test
using DataFrames
using Dates
using Statistics
using LibPQ

# =============================================================================
# Test infer_ramp_rates
# =============================================================================

@testset "Ramp Rate Inference" begin

    @testset "Basic ramp rate calculation" begin
        # Create synthetic generation data with known ramps
        # 100 MW plant, ramping up 10 MW per period (hourly data)
        n = 200
        gen_values = vcat(
            fill(50.0, 50),           # Stable at 50 MW
            collect(50.0:10.0:100.0), # Ramp up 10 MW/period (6 periods)
            fill(100.0, 50),          # Stable at 100 MW
            collect(100.0:-10.0:50.0),# Ramp down 10 MW/period
            fill(50.0, 200 - 50 - 6 - 50 - 6)  # Fill rest
        )[1:n]

        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill("PT60M", n),
            actual_generation_output_mw = gen_values
        )

        p_max = 100.0
        rates = Euphemia.infer_ramp_rates(df, p_max)

        # Should detect ~10 MW/hour ramps, which is 10% of p_max per hour
        @test rates.ramp_up !== nothing
        @test rates.ramp_down !== nothing
        @test rates.ramp_up > 0.05  # At least 5%
        @test rates.ramp_up < 0.20  # At most 20%
    end

    @testset "Insufficient data returns nothing" begin
        # Less than MIN_DATA_POINTS_FOR_RAMP_INFERENCE
        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:50],
            resolution_code = fill("PT60M", 50),
            actual_generation_output_mw = fill(50.0, 50)
        )

        rates = Euphemia.infer_ramp_rates(df, 100.0)
        @test rates.ramp_up === nothing
        @test rates.ramp_down === nothing
    end

    @testset "15-minute resolution normalization" begin
        # With 15-min data, ramps should be normalized to hourly
        n = 200
        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Minute(15*i) for i in 1:n],
            resolution_code = fill("PT15M", n),
            actual_generation_output_mw = vcat(fill(50.0, 100), fill(60.0, 100))
        )

        rates = Euphemia.infer_ramp_rates(df, 100.0)
        # Rates should be fraction per HOUR, not per 15-min period
        @test rates.ramp_up !== nothing || rates.ramp_down !== nothing
    end
end

# =============================================================================
# Test infer_p_min
# =============================================================================

@testset "p_min Inference" begin

    @testset "Basic p_min calculation" begin
        # Plant that operates stably between 40-100 MW
        n = 500
        gen_values = vcat(
            fill(0.0, 50),    # Off periods
            fill(45.0, 100),  # Stable low operation
            fill(80.0, 100),  # Stable high operation
            fill(0.0, 50),    # Off again
            fill(50.0, 200)   # More stable operation
        )[1:n]

        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill("PT60M", n),
            actual_generation_output_mw = gen_values
        )

        p_max = 100.0
        fuel_type = Symbol("Fossil Gas")

        p_min = Euphemia.infer_p_min(df, p_max, fuel_type)

        # Should detect stable operation around 45-50 MW (35-55% bounds for gas)
        @test p_min !== nothing
        @test p_min >= 35.0  # Lower bound for gas_ccgt
        @test p_min <= 55.0  # Upper bound for gas_ccgt
    end

    @testset "Transient filtering" begin
        # Include startup ramps that should be filtered out
        gen_values = Float64[]

        # Pattern: off -> ramp up -> stable -> ramp down -> off
        for _ in 1:10
            append!(gen_values, fill(0.0, 10))           # Off
            append!(gen_values, collect(0.0:20.0:100.0)) # Ramp up (transient) - 6 values
            append!(gen_values, fill(50.0, 30))          # Stable
            append!(gen_values, collect(50.0:-10.0:0.0)) # Ramp down (transient) - 6 values
        end

        n = length(gen_values)
        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill("PT60M", n),
            actual_generation_output_mw = gen_values
        )

        p_min = Euphemia.infer_p_min(df, 100.0, Symbol("Fossil Gas"))

        # Should find stable operation at ~50 MW, not the transient values
        @test p_min !== nothing
        @test p_min >= 35.0  # Clamped to gas bounds
    end

    @testset "Coal gets higher bounds" begin
        n = 300
        gen_values = vcat(fill(30.0, 150), fill(60.0, 150))

        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill("PT60M", n),
            actual_generation_output_mw = gen_values
        )

        p_min = Euphemia.infer_p_min(df, 100.0, Symbol("Fossil Brown coal/Lignite"))

        # Coal has higher bounds (45-65%)
        @test p_min !== nothing
        @test p_min >= 45.0  # Lower bound for coal
    end
end

# =============================================================================
# Test infer_uptime_downtime
# =============================================================================

@testset "Uptime/Downtime Inference" begin

    @testset "Basic uptime detection" begin
        # Plant with clear on/off cycles: 10h on, 5h off
        n = 300
        gen_values = Float64[]

        for _ in 1:20
            append!(gen_values, fill(50.0, 10))  # 10 hours on
            append!(gen_values, fill(0.0, 5))    # 5 hours off
        end
        gen_values = gen_values[1:n]

        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill("PT60M", n),
            actual_generation_output_mw = gen_values
        )

        (uptime, downtime) = Euphemia.infer_uptime_downtime(df, Symbol("Fossil Gas"))

        # Should detect ~10h uptime, ~5h downtime (clamped to bounds)
        @test uptime !== nothing
        @test downtime !== nothing
        @test uptime >= 2   # gas_ccgt lower bound
        @test uptime <= 12  # gas_ccgt upper bound
        @test downtime >= 1
        @test downtime <= 8
    end

    @testset "Insufficient cycles returns nothing" begin
        # Only 2 on/off cycles - not enough
        n = 200
        gen_values = vcat(fill(50.0, 100), fill(0.0, 100))

        df = DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill("PT60M", n),
            actual_generation_output_mw = gen_values
        )

        (uptime, downtime) = Euphemia.infer_uptime_downtime(df, Symbol("Fossil Gas"))

        # Need at least 5 cycles for inference
        @test uptime === nothing || downtime === nothing
    end
end

# =============================================================================
# Test fuel type bounds
# =============================================================================

@testset "Fuel Type Bounds" begin

    @testset "get_p_min_bounds_category" begin
        @test Euphemia.get_p_min_bounds_category(Symbol("Fossil Brown coal/Lignite")) == :coal
        @test Euphemia.get_p_min_bounds_category(Symbol("Fossil Hard coal")) == :coal
        @test Euphemia.get_p_min_bounds_category(Symbol("Fossil Gas")) == :gas_ccgt
        @test Euphemia.get_p_min_bounds_category(Symbol("Other")) == :default
    end

    @testset "FLEXIBLE_FUEL_TYPES" begin
        @test Symbol("Hydro Water Reservoir") in Euphemia.FLEXIBLE_FUEL_TYPES
        @test Symbol("Hydro Pumped Storage") in Euphemia.FLEXIBLE_FUEL_TYPES
        @test Symbol("Battery") in Euphemia.FLEXIBLE_FUEL_TYPES
        @test !(Symbol("Fossil Gas") in Euphemia.FLEXIBLE_FUEL_TYPES)
    end

    @testset "P_MIN_BOUNDS consistency" begin
        # Verify bounds are reasonable
        for (category, (low, high)) in Euphemia.P_MIN_BOUNDS
            @test 0.0 <= low < high <= 1.0
        end
    end
end

# =============================================================================
# Test Generator struct with new fields
# =============================================================================

@testset "Generator Struct" begin

    @testset "Constructor with all fields" begin
        gen = Euphemia.Generator(
            "GEN-001", "Test Plant", Symbol("Fossil Gas"), "Location",
            100.0, 35.0, "GR", 50.0,
            0.25, 0.25,  # ramp rates
            4, 2          # uptime, downtime
        )

        @test gen.code == "GEN-001"
        @test gen.ramp_up == 0.25
        @test gen.ramp_down == 0.25
        @test gen.min_uptime == 4
        @test gen.min_downtime == 2
    end

    @testset "Constructor with defaults" begin
        gen = Euphemia.Generator(
            "GEN-001", "Test Plant", Symbol("Fossil Gas"), "Location",
            100.0, 35.0, "GR", 50.0
        )

        @test gen.ramp_up === nothing
        @test gen.ramp_down === nothing
        @test gen.min_uptime === nothing
        @test gen.min_downtime === nothing
    end
end

# =============================================================================
# Database Integration Tests
# These tests require a database connection
# =============================================================================

@testset "Database Integration" begin

    @testset "Fetch historical generation data" begin
        # Get one generator from the database
        gens = Euphemia.get_generators("GR", Date(2024, 6, 15); exclude_unavailable=false)
        @test length(gens) > 0

        # Fetch historical data for the first generator
        gen = gens[1]
        historical = Euphemia.get_historical_generation(gen.code, Date(2024, 6, 15))

        # Should have data with correct columns
        @test :date_time_utc in propertynames(historical)
        @test :resolution_code in propertynames(historical)
        @test :actual_generation_output_mw in propertynames(historical)

        # Should have some rows (12 months of data)
        @test nrow(historical) > 0
        println("  Fetched $(nrow(historical)) rows for $(gen.name)")
    end

    @testset "Inference on real data" begin
        # Get a thermal generator
        gens = Euphemia.get_generators("GR", Date(2024, 6, 15); exclude_unavailable=false)
        thermal_gens = filter(g -> !(g.fuel_type in Euphemia.FLEXIBLE_FUEL_TYPES), gens)
        @test length(thermal_gens) > 0

        gen = thermal_gens[1]
        historical = Euphemia.get_historical_generation(gen.code, Date(2024, 6, 15))

        # Test ramp rate inference
        rates = Euphemia.infer_ramp_rates(historical, gen.p_max)
        # May or may not have enough data, but shouldn't error
        @test rates isa NamedTuple

        # Test p_min inference
        p_min = Euphemia.infer_p_min(historical, gen.p_max, gen.fuel_type)
        # May be nothing if insufficient data
        @test p_min === nothing || p_min > 0

        println("  Inference completed for $(gen.name)")
    end

    @testset "Cache save and load" begin
        # Use a test zone marker to avoid polluting real cache
        test_zone = "TEST_ZONE"

        # Create a test generator with known values
        test_gen = Euphemia.Generator(
            "TEST-GEN-001", "Test Generator", Symbol("Fossil Gas"), "Test Location",
            100.0, 35.0, test_zone, 50.0,
            0.15, 0.15,  # ramp rates
            6, 3          # uptime, downtime
        )

        # Save to cache
        count = Euphemia.save_inferred_parameters([test_gen], test_zone, Date(2024, 6, 15))
        @test count == 1

        # Load from cache
        cache = Euphemia.load_cached_parameters(test_zone; max_age_days=7)
        @test length(cache) == 1
        @test haskey(cache, "TEST-GEN-001")

        # Verify values
        cached = cache["TEST-GEN-001"]
        @test cached.ramp_up ≈ 0.15
        @test cached.ramp_down ≈ 0.15
        @test cached.p_min ≈ 35.0
        @test cached.min_uptime == 6
        @test cached.min_downtime == 3

        # Cleanup: delete test data
        Euphemia.withdb() do conn
            LibPQ.execute(conn, "DELETE FROM simulations.generator_inferred_parameters WHERE bidding_zone = 'TEST_ZONE'")
        end

        println("  Cache save/load test passed")
    end

end

println("Generator Inference Tests completed!")
