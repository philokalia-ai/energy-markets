# Tests for Data Fetching Functions
# Small DB integration tests to verify data access layer works correctly

using Test
using DataFrames
using Dates

# =============================================================================
# Database Integration Tests for Core Data Types
# These tests verify that data fetching functions work and return expected structures
# =============================================================================

@testset "Data Fetching Integration" begin

    test_date = Date(2024, 6, 15)
    test_zone = "GR"

    @testset "Generators" begin
        # Test basic generator fetching
        generators = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=false)

        @test length(generators) > 0
        @test all(g -> isa(g, Euphemia.Generator), generators)

        # Verify generator structure
        gen = generators[1]
        @test !isempty(gen.code)
        @test !isempty(gen.name)
        @test gen.p_max > 0
        @test gen.bidding_zone == test_zone

        println("  Fetched $(length(generators)) generators for $test_zone")
    end

    @testset "Generators with unavailability filtering" begin
        # Test that filtering doesn't break
        generators_filtered = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=true)
        generators_all = Euphemia.get_generators(test_zone, test_date; exclude_unavailable=false)

        # Filtered should be <= unfiltered (some may be unavailable)
        @test length(generators_filtered) <= length(generators_all)

        println("  Filtered: $(length(generators_filtered)), All: $(length(generators_all))")
    end

    @testset "Loads" begin
        loads = Euphemia.get_loads(test_zone, test_date)

        @test isa(loads, Vector{Euphemia.Load})
        @test length(loads) > 0

        # Verify struct fields
        load = loads[1]
        @test !isempty(load.timeslot)
        @test !isempty(load.resolution_code)
        @test load.bidding_zone == test_zone

        # Verify data quality
        @test all(l -> l.value >= 0, loads)  # Load should be non-negative

        println("  Fetched $(length(loads)) load records for $test_zone")
    end

    @testset "Renewables (Wind and Solar Forecast)" begin
        renewables = Euphemia.get_generation_forecast_for_wind_and_solar(test_zone, test_date)

        @test isa(renewables, Vector{Euphemia.RenewablesGenerationForecast})
        @test length(renewables) > 0

        # Verify struct fields
        ren = renewables[1]
        @test !isempty(ren.date_time)
        @test !isempty(ren.production_type)
        @test ren.bidding_zone == test_zone

        # Verify data quality
        @test all(r -> r.aggregated_generation_forecast >= 0, renewables)  # Generation should be non-negative

        println("  Fetched $(length(renewables)) renewable forecast records for $test_zone")
    end

    @testset "Transfer Capacities" begin
        # Test fetching transfer capacities between two zones
        capacities = Euphemia.get_entsoe_transfer_capacities(test_date, "GR", "BG")

        @test isa(capacities, DataFrame)
        # May be empty if no direct connection, but should have correct structure
        if nrow(capacities) > 0
            @test :hour in propertynames(capacities)
            @test :capacity_mw in propertynames(capacities)
            println("  Fetched $(nrow(capacities)) transfer capacity records for GR-BG")
        else
            println("  No transfer capacity data for GR-BG (may not have direct connection)")
        end
    end

    @testset "Zone Discovery" begin
        # Test that we can discover available zones
        zones = Euphemia.get_available_zones(test_date)

        @test isa(zones, Vector{String})
        @test length(zones) > 0
        @test test_zone in zones

        println("  Discovered $(length(zones)) zones with data: $(join(zones[1:min(5,end)], ", "))...")
    end

end

println("Data Fetching Tests completed!")
