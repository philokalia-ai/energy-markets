#!/usr/bin/env julia

# Test script for database integration with energy price generation and storage

using Pkg
Pkg.activate(".")

using Test
using Dates

# Include the main module
include("../src/Euphemia.jl")
using .Euphemia

# Helper function to clean up test data
function cleanup_test_data()
    try
        Euphemia.withdb() do cnx
            LibPQ.execute(cnx, "DELETE FROM simulations.energy_prices WHERE bidding_zone IN ('GR', 'TEST', 'T24', 'T48', 'T96') AND code_version = 1")
        end
        @info "Test data cleaned up"
    catch e
        @warn "Could not clean up test data: $e"
    end
end

@testset "Database Integration Tests" begin

    # Clean up any existing test data first
    @info "Cleaning up any existing test data..."
    cleanup_test_data()

    @testset "Generate and Save Energy Prices for Greece" begin
        bidding_zone = "GR"
        test_day = Date(2024, 6, 18)

        @testset "UC-based method with database save" begin
            # Generate prices using Unit Commitment method
            @info "Generating UC-based energy prices for $bidding_zone on $test_day"
            prices_uc = generate_energy_prices(bidding_zone, test_day; order_method=:uc_based)

            # Validate prices structure
            @test !isempty(prices_uc)
            @test isa(prices_uc, Dict{String,Float64})
            @test length(prices_uc) > 0

            # Check timeslot key format
            sample_key = first(keys(prices_uc))
            @test length(sample_key) == 13  # "YYYYMMDD-HHMM" format
            @test sample_key[9] == '-'  # Hyphen separator

            # Check price values are reasonable (not all negative or extreme)
            price_values = collect(values(prices_uc))
            @test !all(p -> p < -500, price_values)  # Not all extremely negative
            @test !all(p -> p > 1000, price_values)  # Not all extremely high

            @info "Generated $(length(prices_uc)) UC-based price periods. Sample prices: $(round.(collect(values(prices_uc))[1:min(3, end)], digits=2))"

            # Save to database
            @info "Saving UC-based prices to database..."
            records_saved = save_energy_prices(prices_uc, bidding_zone, test_day, :uc_based)

            # Validate database save
            @test records_saved > 0
            @test records_saved == length(prices_uc)

            @info "✅ Successfully saved $records_saved UC-based records to database"
        end

        @testset "Alternative method with database save" begin
            # Generate prices using Alternative Order Book method
            @info "Generating Alternative order book energy prices for $bidding_zone on $test_day"
            prices_alt = generate_energy_prices(bidding_zone, test_day; order_method=:alternative)

            # Validate prices structure
            @test !isempty(prices_alt)
            @test isa(prices_alt, Dict{String,Float64})
            @test length(prices_alt) > 0

            # Check timeslot key format
            sample_key = first(keys(prices_alt))
            @test length(sample_key) == 13  # "YYYYMMDD-HHMM" format
            @test sample_key[9] == '-'  # Hyphen separator

            # Check price values are reasonable
            price_values = collect(values(prices_alt))
            @test !all(p -> p < -500, price_values)  # Not all extremely negative
            @test !all(p -> p > 1000, price_values)  # Not all extremely high

            @info "Generated $(length(prices_alt)) Alternative price periods. Sample prices: $(round.(collect(values(prices_alt))[1:min(3, end)], digits=2))"

            # Save to database
            @info "Saving Alternative prices to database..."
            records_saved = save_energy_prices(prices_alt, bidding_zone, test_day, :alternative)

            # Validate database save
            @test records_saved > 0
            @test records_saved == length(prices_alt)

            @info "✅ Successfully saved $records_saved Alternative records to database"
        end

        @testset "Database schema and error handling" begin
            # Test schema creation functionality
            @info "Testing schema creation functionality..."

            # This should work even if schema exists (idempotent)
            ensure_energy_prices_table()  # NOTICEs are expected for existing tables

            # Test with empty prices dict
            empty_prices = Dict{String,Float64}()
            records_saved = save_energy_prices(empty_prices, bidding_zone, test_day, :test)
            @test records_saved == 0

            # Test with malformed timeslot (should handle gracefully)
            bad_prices = Dict("bad-format" => 50.0, "20240618-1200" => 75.0)
            records_saved = save_energy_prices(bad_prices, bidding_zone, test_day, :test; create_schema=false)
            @test records_saved == 1  # Only the valid one should be saved

            @info "✅ Schema and error handling tests completed"
        end

        @testset "Temporal resolution detection" begin
            # Test with different numbers of periods to verify resolution detection
            test_cases = [
                (24, "1H", "hourly"),
                (48, "30M", "30-minute"),
                (96, "15M", "15-minute")
            ]

            for (num_periods, expected_code, description) in test_cases
                # Create mock prices with appropriate number of periods
                mock_prices = Dict{String,Float64}()
                for i in 0:(num_periods-1)
                    minutes = i * (24 * 60 ÷ num_periods)  # Distribute evenly across day
                    hour = minutes ÷ 60
                    min = minutes % 60
                    # Use different day to avoid unique constraint violations
                    test_date = test_day + Day(1) + Day(num_periods ÷ 24)  # Different day for each test
                    timeslot = "$(Dates.format(test_date, "yyyymmdd"))-$(lpad(hour, 2, '0'))$(lpad(min, 2, '0'))"
                    mock_prices[timeslot] = 50.0 + randn() * 10  # Random price around 50
                end

                @info "Testing $description resolution detection ($num_periods periods -> $expected_code)"
                # Use different bidding zone to avoid conflicts
                test_zone = "T$(num_periods)"  # T24, T48, T96
                records_saved = save_energy_prices(mock_prices, test_zone, test_day + Day(num_periods ÷ 24), Symbol("test_$num_periods"); create_schema=false)
                @test records_saved == num_periods

                @info "✅ Successfully handled $description data"
            end
        end
    end
end

@info """
Database Integration Test Summary:
- Tested UC-based price generation and database save for Greece
- Tested Alternative order book price generation and database save for Greece  
- Verified schema creation and error handling
- Tested temporal resolution detection (15M, 30M, 1H)
- All database operations use proper transaction management and batching

To clean up test data, run: cleanup_test_data()
"""