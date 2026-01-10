# Tests for Generator Initial Conditions
# Tests for determining initial state of generators at the start of UC optimization

using Test
using Dates
using DataFrames

# =============================================================================
# Unit Tests - Synthetic Data
# =============================================================================

@testset "Thermal State Determination" begin
    @testset "Hot state (recently running)" begin
        @test Euphemia.determine_thermal_state(0) == :hot
        @test Euphemia.determine_thermal_state(1) == :hot
        @test Euphemia.determine_thermal_state(8) == :hot
    end

    @testset "Warm state (off for medium duration)" begin
        @test Euphemia.determine_thermal_state(9) == :warm
        @test Euphemia.determine_thermal_state(24) == :warm
        @test Euphemia.determine_thermal_state(48) == :warm
    end

    @testset "Cold state (off for long duration)" begin
        @test Euphemia.determine_thermal_state(49) == :cold
        @test Euphemia.determine_thermal_state(72) == :cold
        @test Euphemia.determine_thermal_state(100) == :cold
    end

    @testset "Custom thresholds" begin
        # Custom warm threshold = 4, cold threshold = 12
        @test Euphemia.determine_thermal_state(3; warm_threshold=4, cold_threshold=12) == :hot
        @test Euphemia.determine_thermal_state(5; warm_threshold=4, cold_threshold=12) == :warm
        @test Euphemia.determine_thermal_state(15; warm_threshold=4, cold_threshold=12) == :cold
    end
end

@testset "Default Initial Conditions" begin
    @testset "Baseload plants (assumed running)" begin
        # Coal/Lignite - assumed to be running
        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Brown coal/Lignite"))
        @test ic.is_on == true
        @test ic.hours_on > 0
        @test ic.thermal_state == :hot

        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Hard coal"))
        @test ic.is_on == true

        ic = Euphemia.get_default_initial_conditions(Symbol("Nuclear"))
        @test ic.is_on == true
    end

    @testset "Mid-merit plants (CCGT)" begin
        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Gas - CCGT"))
        @test ic.is_on == false
        @test ic.hours_off > 0
        @test ic.thermal_state == :hot  # Recently off, still warm
    end

    @testset "Peaker plants (OCGT)" begin
        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Gas"))
        @test ic.is_on == false
        @test ic.hours_off > 0
    end

    @testset "Flexible resources (hydro, batteries)" begin
        ic = Euphemia.get_default_initial_conditions(Symbol("Hydro Water Reservoir"))
        @test ic.is_on == false
        @test ic.hours_off == 0  # No thermal constraints
        @test ic.thermal_state == :hot

        ic = Euphemia.get_default_initial_conditions(Symbol("Hydro Pumped Storage"))
        @test ic.is_on == false
        @test ic.thermal_state == :hot
    end

    @testset "Unknown fuel type" begin
        ic = Euphemia.get_default_initial_conditions(Symbol("Unknown Type"))
        @test ic.is_on == false
        @test ic.thermal_state == :warm  # Conservative default
    end
end

@testset "InitialConditions Struct" begin
    ic = Euphemia.InitialConditions(true, 150.0, 12, 0, :hot)

    @test ic.is_on == true
    @test ic.output == 150.0
    @test ic.hours_on == 12
    @test ic.hours_off == 0
    @test ic.thermal_state == :hot

    # Generator that's off
    ic_off = Euphemia.InitialConditions(false, 0.0, 0, 24, :warm)
    @test ic_off.is_on == false
    @test ic_off.output == 0.0
    @test ic_off.hours_off == 24
    @test ic_off.thermal_state == :warm
end

@testset "Consecutive State Counting" begin
    # Create synthetic historical data (DESC order - most recent first)
    @testset "Counting hours ON" begin
        # Simulate a generator that's been on for several periods
        df = DataFrame(
            date_time_utc = [DateTime(2024, 6, 14, 22), DateTime(2024, 6, 14, 21),
                           DateTime(2024, 6, 14, 20), DateTime(2024, 6, 14, 19)],
            resolution_code = ["PT60M", "PT60M", "PT60M", "PT60M"],
            actual_generation_output_mw = [100.0, 100.0, 100.0, 100.0]
        )
        hours = Euphemia.count_consecutive_state(df, true)
        @test hours == 4
    end

    @testset "Counting hours OFF" begin
        # Simulate a generator that's been off for several periods
        df = DataFrame(
            date_time_utc = [DateTime(2024, 6, 14, 22), DateTime(2024, 6, 14, 21),
                           DateTime(2024, 6, 14, 20), DateTime(2024, 6, 14, 19)],
            resolution_code = ["PT60M", "PT60M", "PT60M", "PT60M"],
            actual_generation_output_mw = [0.0, 0.0, 0.0, 0.0]
        )
        hours = Euphemia.count_consecutive_state(df, false)
        @test hours == 4
    end

    @testset "State transition" begin
        # Generator was off, then turned on 2 hours ago
        df = DataFrame(
            date_time_utc = [DateTime(2024, 6, 14, 22), DateTime(2024, 6, 14, 21),
                           DateTime(2024, 6, 14, 20), DateTime(2024, 6, 14, 19)],
            resolution_code = ["PT60M", "PT60M", "PT60M", "PT60M"],
            actual_generation_output_mw = [100.0, 100.0, 0.0, 0.0]  # On for last 2 hours
        )
        hours_on = Euphemia.count_consecutive_state(df, true)
        @test hours_on == 2

        # Generator was on, then turned off 3 hours ago
        df2 = DataFrame(
            date_time_utc = [DateTime(2024, 6, 14, 22), DateTime(2024, 6, 14, 21),
                           DateTime(2024, 6, 14, 20), DateTime(2024, 6, 14, 19)],
            resolution_code = ["PT60M", "PT60M", "PT60M", "PT60M"],
            actual_generation_output_mw = [0.0, 0.0, 0.0, 100.0]  # Off for last 3 hours
        )
        hours_off = Euphemia.count_consecutive_state(df2, false)
        @test hours_off == 3
    end

    @testset "15-minute resolution" begin
        # 4 quarters of an hour = 1 hour
        df = DataFrame(
            date_time_utc = [DateTime(2024, 6, 14, 22, 45), DateTime(2024, 6, 14, 22, 30),
                           DateTime(2024, 6, 14, 22, 15), DateTime(2024, 6, 14, 22, 0)],
            resolution_code = ["PT15M", "PT15M", "PT15M", "PT15M"],
            actual_generation_output_mw = [100.0, 100.0, 100.0, 100.0]
        )
        hours = Euphemia.count_consecutive_state(df, true)
        @test hours == 1  # 4 * 15min = 60min = 1 hour
    end
end

# =============================================================================
# Database Integration Tests
# =============================================================================

@testset "Database Integration" begin
    test_date = Date(2024, 6, 15)
    test_zone = "GR"

    @testset "Get recent generation data" begin
        # Get generators first
        generators = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=false)
        @test length(generators) > 0

        # Pick a thermal generator for testing
        thermal_gens = filter(g -> occursin("Fossil", string(g.fuel_type)), generators)
        @test length(thermal_gens) > 0

        gen = thermal_gens[1]
        day_before = test_date - Day(1)
        end_dt = DateTime(day_before, Time(23, 0, 0))

        # Fetch recent generation
        recent = Euphemia.get_recent_generation(gen.code, end_dt; hours_back=24)
        @test isa(recent, DataFrame)
        # May or may not have data depending on date
        println("    $(gen.name): $(nrow(recent)) recent records")
    end

    @testset "Infer initial conditions from historical data" begin
        generators = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=false)
        thermal_gens = filter(g -> occursin("Fossil", string(g.fuel_type)), generators)
        gen = thermal_gens[1]

        ic = Euphemia.infer_initial_conditions(gen.code, test_date, gen.fuel_type)

        @test isa(ic, Euphemia.InitialConditions)
        @test ic.is_on isa Bool
        @test ic.output >= 0
        @test ic.hours_on >= 0
        @test ic.hours_off >= 0
        @test ic.thermal_state in [:hot, :warm, :cold]

        println("    $(gen.name): is_on=$(ic.is_on), output=$(round(ic.output))MW, " *
                "hours_on=$(ic.hours_on), thermal=$(ic.thermal_state)")
    end

    @testset "Get initial conditions for multiple generators" begin
        generators = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=false)
        # Test with a subset to keep it quick
        test_gens = generators[1:min(5, end)]

        conditions = Euphemia.get_initial_conditions(test_gens, test_date; use_historical=true)

        @test isa(conditions, Dict{String, Euphemia.InitialConditions})
        @test length(conditions) == length(test_gens)

        # All generators should have conditions
        for gen in test_gens
            @test haskey(conditions, gen.code)
            ic = conditions[gen.code]
            @test isa(ic, Euphemia.InitialConditions)
        end

        on_count = count(ic -> ic.is_on, values(conditions))
        println("    Tested $(length(test_gens)) generators: $on_count ON, $(length(test_gens) - on_count) OFF")
    end

    @testset "Get initial conditions without historical data" begin
        generators = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=false)
        test_gens = generators[1:min(3, end)]

        conditions = Euphemia.get_initial_conditions(test_gens, test_date; use_historical=false)

        @test isa(conditions, Dict{String, Euphemia.InitialConditions})
        @test length(conditions) == length(test_gens)

        # Should use defaults
        for gen in test_gens
            ic = conditions[gen.code]
            @test isa(ic, Euphemia.InitialConditions)
        end
    end
end

println("Initial Conditions Tests completed!")
