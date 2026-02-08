using Test
using Dates
using Euphemia

"""
Test suite for run_independent_clearing_for_date_range function.
Tests the multi-date processing functionality with October 2025 as the target period.
"""

@testset "Date Range Processing Tests" begin

    @testset "October 2025 Two Day Processing" begin
        println("🗓️ Testing date range processing for October 2025 (2 days)")

        # Define October 2025 date range
        start_date = Date(2025, 10, 2)
        end_date = Date(2025, 10, 3)

        println("📅 Processing dates: $start_date to $end_date")
        println("📊 Expected: 2 dates")

        # Test with basic parameters (sequential processing for reliability)
        result = run_independent_clearing_for_date_range(
            start_date, end_date;
            order_method=:uc_based,
            model=:mpcc,
            optimizer="highs",
            save_to_db=false,  # Don't save during testing
            skip_existing=false,  # Process all zones
            silent=true,
            max_retries=1,  # Reduced retries for faster testing
            parallel=true  # Parallel for performance testing
        )

        # Verify basic result structure
        @test haskey(result, :date_results)
        @test haskey(result, :total_dates)
        @test haskey(result, :successful_dates)
        @test haskey(result, :failed_dates)
        @test haskey(result, :total_zones_processed)
        @test haskey(result, :total_zones_successful)
        @test haskey(result, :total_time)
        @test haskey(result, :start_date)
        @test haskey(result, :end_date)
        @test haskey(result, :daily_summaries)

        # Verify date range correctness
        @test result.start_date == start_date
        @test result.end_date == end_date
        @test result.total_dates == 2
        @test length(result.date_results) == 2
        @test length(result.daily_summaries) == 2

        # Verify date consistency in results
        expected_dates = collect(start_date:Day(1):end_date)
        result_dates = [dr.date for dr in result.date_results]
        @test result_dates == expected_dates

        # Verify summary dates match
        summary_dates = [ds.date for ds in result.daily_summaries]
        @test summary_dates == expected_dates

        # Verify counters consistency
        @test result.successful_dates + result.failed_dates == result.total_dates
        @test result.successful_dates >= 0
        @test result.failed_dates >= 0

        # Verify processing time is reasonable
        @test result.total_time > 0
        @test result.total_time < 1800  # Should complete within 30 minutes for 2 days testing

        # Check that we got some successful processing
        @test result.total_zones_processed > 0
        println("✅ Processed $(result.total_zones_processed) zone-date combinations")
        println("✅ $(result.successful_dates)/$(result.total_dates) dates successful")
        println("✅ Total processing time: $(round(result.total_time/60, digits=1)) minutes")

        # Verify zone processing across dates
        if result.total_zones_successful > 0
            @test result.total_zones_successful <= result.total_zones_processed

            success_rate = result.total_zones_successful / result.total_zones_processed * 100
            println("✅ Zone success rate: $(round(success_rate, digits=1))%")

            # Check that successful dates have proper structure
            successful_date_results = filter(dr -> dr.success, result.date_results)
            @test length(successful_date_results) == result.successful_dates

            for date_result in successful_date_results
                @test haskey(date_result, :zones_result)
                @test date_result.zones_result !== nothing
                @test date_result.zones_successful > 0
                @test date_result.elapsed_time > 0
            end
        end
    end

    @testset "October 2025 First Week Processing" begin
        println("\n🗓️ Testing date range processing for October 2025 first week")

        # Define first week of October 2025
        start_date = Date(2025, 10, 1)
        end_date = Date(2025, 10, 7)

        println("📅 Processing dates: $start_date to $end_date")
        println("📊 Expected: 7 dates")

        # Test with parallel processing enabled
        result = run_independent_clearing_for_date_range(
            start_date, end_date;
            order_method=:uc_based,
            model=:mpcc,
            optimizer="highs",
            save_to_db=false,
            parallel=true,  # Test parallel processing
            max_workers=4,  # Limit workers for testing
            chunk_size=2,   # Small chunks for testing
            silent=true,
            max_retries=1
        )

        # Basic structure verification
        @test result.total_dates == 7
        @test length(result.date_results) == 7
        @test result.start_date == start_date
        @test result.end_date == end_date

        # Verify all dates are processed
        result_dates = [dr.date for dr in result.date_results]
        expected_dates = collect(start_date:Day(1):end_date)
        @test result_dates == expected_dates

        println("✅ Week processing completed: $(result.successful_dates)/7 dates successful")

        if result.total_zones_successful > 0
            # Check daily summaries for successful dates
            successful_summaries = filter(ds -> ds.zones_successful > 0, result.daily_summaries)

            for summary in successful_summaries
                @test summary.zones_total >= 0
                @test summary.zones_successful >= 0
                @test summary.success_rate >= 0 && summary.success_rate <= 100
                @test summary.total_periods >= 0

                # If we have successful zones, check price statistics
                if summary.zones_successful > 0 && summary.total_periods > 0
                    @test summary.avg_price >= 0
                    @test summary.min_price >= 0
                    @test summary.max_price >= 0
                    @test summary.max_price >= summary.min_price

                    println("📊 $(summary.date): $(summary.zones_successful) zones, €$(summary.avg_price)/MWh avg")
                end
            end
        end
    end

    @testset "Error Handling and Edge Cases" begin
        println("\n🧪 Testing error handling and edge cases")

        # Test invalid date range (start > end)
        @test_throws ErrorException run_independent_clearing_for_date_range(
            Date(2025, 10, 31), Date(2025, 10, 1)
        )

        # Test single date (start == end)
        single_date = Date(2025, 10, 15)
        result_single = run_independent_clearing_for_date_range(
            single_date, single_date;
            save_to_db=false,
            silent=true,
            max_retries=1
        )

        @test result_single.total_dates == 1
        @test result_single.start_date == single_date
        @test result_single.end_date == single_date
        @test length(result_single.date_results) == 1
        @test result_single.date_results[1].date == single_date

        println("✅ Single date processing works correctly")

        # Test with custom fallback zones
        fallback_result = run_independent_clearing_for_date_range(
            Date(2025, 10, 1), Date(2025, 10, 2);
            fallback_zones=["GR", "FR"],
            save_to_db=false,
            silent=true,
            max_retries=1
        )

        @test fallback_result.total_dates == 2
        println("✅ Custom fallback zones processing works")
    end

    @testset "Progress Tracking" begin
        println("\n📈 Testing progress tracking functionality")

        # Progress callback function for testing
        progress_calls = []
        function test_progress_callback(date, current, total, elapsed)
            push!(progress_calls, (date=date, current=current, total=total, elapsed=elapsed))
        end

        # Test short date range with progress callback
        result = run_independent_clearing_for_date_range(
            Date(2025, 10, 1), Date(2025, 10, 3);
            progress_callback=test_progress_callback,
            save_to_db=false,
            silent=true,
            max_retries=1
        )

        # Verify progress callback was called
        @test length(progress_calls) == 3  # One call per date
        @test progress_calls[1].current == 1
        @test progress_calls[2].current == 2
        @test progress_calls[3].current == 3
        @test all(pc.total == 3 for pc in progress_calls)
        @test all(pc.elapsed >= 0 for pc in progress_calls)

        println("✅ Progress callback functionality works correctly")
    end
end

# Helper function to print detailed test results
function print_test_summary(result)
    println("\n" * "="^60)
    println("📋 TEST RESULT SUMMARY")
    println("="^60)
    println("📅 Date range: $(result.start_date) to $(result.end_date)")
    println("📊 Total dates: $(result.total_dates)")
    println("✅ Successful dates: $(result.successful_dates)")
    println("❌ Failed dates: $(result.failed_dates)")
    println("🌍 Total zone-date combinations: $(result.total_zones_processed)")
    println("✅ Successful zone-date combinations: $(result.total_zones_successful)")
    println("⏱️ Total processing time: $(round(result.total_time/60, digits=1)) minutes")

    if result.total_zones_successful > 0
        success_rate = result.total_zones_successful / result.total_zones_processed * 100
        println("📈 Zone success rate: $(round(success_rate, digits=1))%")

        # Show price statistics for successful dates
        successful_summaries = filter(ds -> ds.zones_successful > 0 && ds.avg_price > 0, result.daily_summaries)
        if !isempty(successful_summaries)
            avg_prices = [s.avg_price for s in successful_summaries]
            println("💰 Price range: €$(round(minimum(avg_prices), digits=2)) - €$(round(maximum(avg_prices), digits=2))/MWh")
        end
    end

    println("="^60)
end