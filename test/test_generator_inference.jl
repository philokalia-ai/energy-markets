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

# =============================================================================
# Test 3-Class Gas Classification (CCGT / CHP / OCGT)
# =============================================================================

@testset "Gas 3-Class Classification" begin

    @testset "Capacity fallback (2-arg backward compat)" begin
        # Small gas plant → OCGT (no name provided)
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 150.0) == Symbol("Fossil Gas OCGT")

        # Exactly at threshold → OCGT
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 200.0) == Symbol("Fossil Gas OCGT")

        # Above threshold → stays CCGT
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 201.0) == Symbol("Fossil Gas")
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 500.0) == Symbol("Fossil Gas")
    end

    @testset "CCGT name patterns" begin
        # GuD (German: Gas-und-Dampf = combined cycle)
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 120.0, "GuD Marzahn") == Symbol("Fossil Gas")
        # CCGT explicit
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 80.0, "CCGT Unit 1") == Symbol("Fossil Gas")
        # Combined cycle
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 150.0, "Combined Cycle Plant") == Symbol("Fossil Gas")
        # Combicycle
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "Combicycle 5") == Symbol("Fossil Gas")
        # Case insensitive
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "gud plant") == Symbol("Fossil Gas")
    end

    @testset "CCGT priority over CHP" begin
        # GuD + HKW → CCGT (CCGT overrides CHP)
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 167.0, "HKW Nord GuD Nord") == Symbol("Fossil Gas")
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "GuD BHKW Anlage") == Symbol("Fossil Gas")
    end

    @testset "CHP name patterns" begin
        # HKW (Heizkraftwerk)
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "HKW Klingenberg") == Symbol("Fossil Gas CHP")
        # BHKW (Blockheizkraftwerk)
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 50.0, "KW Hastedt BHKW") == Symbol("Fossil Gas CHP")
        # KWK
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 80.0, "KWK Anlage Nord") == Symbol("Fossil Gas CHP")
        # CHP explicit
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 125.0, "DESBR____CHP____") == Symbol("Fossil Gas CHP")
        # French Coge (cogeneration)
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 125.0, "CPCU-CogeVitry") == Symbol("Fossil Gas CHP")
        # Heizkraft
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "Heizkraftwerk Mitte") == Symbol("Fossil Gas CHP")
        # Polish Elektrociep
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "Elektrocieplownia") == Symbol("Fossil Gas CHP")
        # Warmekraft
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "Warmekraftwerk X") == Symbol("Fossil Gas CHP")
    end

    @testset "EC word-boundary pattern" begin
        # Polish EC prefix with word boundary
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "EC Krakow") == Symbol("Fossil Gas CHP")
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "PL_EC_Gdansk") == Symbol("Fossil Gas CHP")
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "Unit-EC-West") == Symbol("Fossil Gas CHP")
    end

    @testset "EC false positive rejection" begin
        # Should NOT match EC inside words
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "SECTOR Plant") != Symbol("Fossil Gas CHP")
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "ELECTRICITE Unit") != Symbol("Fossil Gas CHP")
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Gas"), 100.0, "SPECIAL Generator") != Symbol("Fossil Gas CHP")
    end

    @testset "Non-gas passthrough" begin
        @test Euphemia.classify_gas_subtype(Symbol("Fossil Hard coal"), 100.0, "HKW Coal") == Symbol("Fossil Hard coal")
        @test Euphemia.classify_gas_subtype(Symbol("Nuclear"), 50.0, "CCGT Nuclear") == Symbol("Nuclear")
        @test Euphemia.classify_gas_subtype(Symbol("Other"), 100.0, "CHP Other") == Symbol("Other")
    end

    @testset "CHP get_p_min_bounds_category" begin
        @test Euphemia.get_p_min_bounds_category(Symbol("Fossil Gas CHP")) == :gas_chp
        @test Euphemia.get_p_min_bounds_category(Symbol("Fossil Gas OCGT")) == :gas_ocgt
        @test Euphemia.get_p_min_bounds_category(Symbol("Fossil Gas")) == :gas_ccgt
    end

    @testset "CHP FuelTypeParameters" begin
        chp_params = Euphemia.get_fuel_type_parameters(Symbol("Fossil Gas CHP"))
        ccgt_params = Euphemia.get_fuel_type_parameters(Symbol("Fossil Gas"))
        ocgt_params = Euphemia.get_fuel_type_parameters(Symbol("Fossil Gas OCGT"))

        # CHP should have higher min load factor than CCGT (heat obligations)
        @test chp_params.min_load_factor > ccgt_params.min_load_factor
        @test chp_params.min_load_factor == 0.40

        # CHP should have longer min uptime than CCGT (heat obligations)
        @test chp_params.min_uptime >= ccgt_params.min_uptime
        @test chp_params.min_uptime == 6

        # CHP should ramp slower than CCGT (heat extraction constrains)
        @test chp_params.ramp_up_rate <= ccgt_params.ramp_up_rate
        @test chp_params.ramp_up_rate == 0.20

        # CHP startup times same as CCGT (same turbine technology)
        @test chp_params.cold_startup_time == ccgt_params.cold_startup_time
        @test chp_params.hot_startup_time == ccgt_params.hot_startup_time
    end

    @testset "CHP marginal cost between CCGT and OCGT" begin
        chp_cost = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas CHP")
        ccgt_cost = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas")
        ocgt_cost = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas OCGT")

        @test chp_cost > ccgt_cost
        @test chp_cost < ocgt_cost
    end

    @testset "CHP default initial conditions" begin
        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Gas CHP"))
        @test ic.is_on == true  # Heat-led, assumed running
        @test ic.thermal_state == :hot
        @test ic.hours_on > 0
    end

    @testset "CCGT default initial conditions (fixed Symbol matching)" begin
        # Symbol("Fossil Gas") should match CCGT, not fall through to generic gas
        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Gas"))
        @test ic.is_on == false
        @test ic.hours_off > 0
        @test ic.thermal_state == :hot  # Recently off, still warm
    end

    @testset "OCGT default initial conditions" begin
        ic = Euphemia.get_default_initial_conditions(Symbol("Fossil Gas OCGT"))
        @test ic.is_on == false
        @test ic.hours_off > 0
        @test ic.thermal_state == :warm  # Off longer
    end

    @testset "OCGT FuelTypeParameters" begin
        params = Euphemia.get_fuel_type_parameters(Symbol("Fossil Gas OCGT"))
        ccgt_params = Euphemia.get_fuel_type_parameters(Symbol("Fossil Gas"))

        # OCGT should be faster to start than CCGT
        @test params.hot_startup_time <= ccgt_params.hot_startup_time
        @test params.cold_startup_time <= ccgt_params.cold_startup_time

        # OCGT should ramp faster
        @test params.ramp_up_rate >= ccgt_params.ramp_up_rate

        # OCGT should have lower min load factor
        @test params.min_load_factor < ccgt_params.min_load_factor

        # Specific OCGT values
        @test params.min_load_factor == 0.20
        @test params.ramp_up_rate == 0.50
        @test params.min_uptime == 1
        @test params.min_downtime == 1
    end

    @testset "OCGT marginal cost higher than CCGT" begin
        ocgt_cost = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas OCGT")
        ccgt_cost = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas")

        @test ocgt_cost > ccgt_cost
        @test ocgt_cost > 100.0
        @test ccgt_cost < 100.0
    end

    @testset "GAS_OCGT_CAPACITY_THRESHOLD_MW constant" begin
        @test Euphemia.GAS_OCGT_CAPACITY_THRESHOLD_MW == 200.0
    end
end

# =============================================================================
# Test Behavioral Gas Validation
# =============================================================================

@testset "Behavioral Gas Validation (validate_gas_classification)" begin

    # Helper to create a Generator for testing
    function make_gas_gen(; fuel_type=Symbol("Fossil Gas OCGT"), p_max=100.0, code="TEST-GEN")
        Euphemia.Generator(code, "Test Gas Plant", fuel_type, "Location",
                           p_max, 20.0, "GR", 140.0)
    end

    # Helper to create synthetic historical data
    function make_historical(; n=500, on_fraction=0.8, output_when_on=70.0, starts=5, res="PT60M")
        gen_values = Float64[]
        on_periods = round(Int, n * on_fraction / max(starts, 1))  # periods per run
        off_periods = round(Int, n * (1 - on_fraction) / max(starts, 1))

        for _ in 1:starts
            append!(gen_values, fill(output_when_on, on_periods))
            append!(gen_values, fill(0.0, off_periods))
        end
        gen_values = gen_values[1:min(n, length(gen_values))]
        if length(gen_values) < n
            append!(gen_values, fill(0.0, n - length(gen_values)))
        end

        return DataFrame(
            date_time_utc = [DateTime(2024, 1, 1) + Hour(i) for i in 1:n],
            resolution_code = fill(res, n),
            actual_generation_output_mw = gen_values
        )
    end

    @testset "OCGT with high CF + few starts → CHP" begin
        gen = make_gas_gen(fuel_type=Symbol("Fossil Gas OCGT"))
        # High capacity factor (>50%), few starts (<2/week) → baseload heat-led
        hist = make_historical(n=1000, on_fraction=0.85, output_when_on=70.0, starts=3)
        result = Euphemia.validate_gas_classification(gen, hist)
        @test result == Symbol("Fossil Gas CHP")
    end

    @testset "OCGT with medium CF + long runs → CCGT" begin
        gen = make_gas_gen(fuel_type=Symbol("Fossil Gas OCGT"))
        # Capacity factor when running = 45/100 = 0.45 (>0.35 but <0.50, so CHP rule doesn't trigger)
        # Long on-periods (100h each) → mean_run > 12h → CCGT rule triggers
        hist = make_historical(n=1000, on_fraction=0.4, output_when_on=45.0, starts=4)
        result = Euphemia.validate_gas_classification(gen, hist)
        @test result == Symbol("Fossil Gas")
    end

    @testset "Genuine OCGT stays OCGT" begin
        gen = make_gas_gen(fuel_type=Symbol("Fossil Gas OCGT"))
        # Low CF, many starts, short runs → genuine peaker
        hist = make_historical(n=1000, on_fraction=0.08, output_when_on=80.0, starts=40)
        result = Euphemia.validate_gas_classification(gen, hist)
        @test result == Symbol("Fossil Gas OCGT")
    end

    @testset "CCGT with very peaky behavior → OCGT" begin
        gen = make_gas_gen(fuel_type=Symbol("Fossil Gas"), p_max=300.0)
        # Very low CF (<15%), many starts (>5/week), short runs (<4h) → peaker
        hist = make_historical(n=1000, on_fraction=0.05, output_when_on=30.0, starts=60)
        result = Euphemia.validate_gas_classification(gen, hist)
        @test result == Symbol("Fossil Gas OCGT")
    end

    @testset "CHP not overridden by behavior" begin
        gen = make_gas_gen(fuel_type=Symbol("Fossil Gas CHP"))
        # Even if behavior looks peaky, CHP (name-based) is high-confidence
        hist = make_historical(n=1000, on_fraction=0.05, output_when_on=30.0, starts=60)
        result = Euphemia.validate_gas_classification(gen, hist)
        @test result == Symbol("Fossil Gas CHP")
    end

    @testset "Insufficient data → no reclassification" begin
        gen = make_gas_gen(fuel_type=Symbol("Fossil Gas OCGT"))
        # Too few data points
        hist = make_historical(n=50, on_fraction=0.9, output_when_on=70.0, starts=1)
        result = Euphemia.validate_gas_classification(gen, hist)
        @test result == Symbol("Fossil Gas OCGT")
    end

    @testset "Non-gas plants → no reclassification" begin
        coal_gen = Euphemia.Generator("COAL-1", "Coal Plant", Symbol("Fossil Hard coal"),
                                      "Location", 200.0, 90.0, "GR", 80.0)
        hist = make_historical(n=500, on_fraction=0.9, output_when_on=150.0, starts=2)
        result = Euphemia.validate_gas_classification(coal_gen, hist)
        @test result == Symbol("Fossil Hard coal")
    end
end

println("Generator Inference Tests completed!")
