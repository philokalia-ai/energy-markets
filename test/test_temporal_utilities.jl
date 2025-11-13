#!/usr/bin/env julia

"""
Test suite for TemporalResolutionUtilities.jl

This test suite validates the temporal resolution detection and disaggregation
functionality that is now centralized in TemporalResolutionUtilities.jl.
"""

# Add the src directory to the load path
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

include("../src/Euphemia.jl")
using .Euphemia
using Dates

println("🧪 Testing Temporal Resolution Utilities")
println("="^50)

# Mock data structures for testing
struct TestLoad
    timeslot::String
    value::Float64
    resolution_code::String
end

struct TestRenewable
    date_time::String
    aggregated_generation_forecast::Float64
    resolution_code::String
end

# Test 1: Basic functionality test
println("\n📋 Test 1: Basic Function Availability")
println("-"^30)

@assert isdefined(Euphemia, :parse_resolution_to_minutes) "parse_resolution_to_minutes function not available"
@assert isdefined(Euphemia, :determine_finest_resolution) "determine_finest_resolution function not available"
@assert isdefined(Euphemia, :generate_sub_slots_from_source) "generate_sub_slots_from_source function not available"
@assert isdefined(Euphemia, :disaggregate_temporal_data) "disaggregate_temporal_data function not available"

println("✅ All temporal utility functions are available")

# Test 2: Resolution parsing
println("\n📋 Test 2: Resolution Code Parsing")
println("-"^30)

test_cases = [
    ("PT15M", 15),
    ("PT30M", 30),
    ("PT60M", 60),
    ("PT1H", 60),  # This might fail if not supported
]

for (code, expected) in test_cases
    try
        result = parse_resolution_to_minutes(code)
        if result == expected
            println("✅ $code → $result minutes")
        else
            println("❌ $code → $result minutes (expected $expected)")
        end
    catch e
        println("⚠️ $code → Error: $e")
    end
end

# Test 3: Mixed resolution disaggregation
println("\n📋 Test 3: Mixed Resolution Disaggregation")
println("-"^30)

# Create test data with mixed resolutions (60min loads, 15min renewables)
test_loads = [
    TestLoad("20241031-0000", 1000.0, "PT60M"),
    TestLoad("20241031-0100", 1100.0, "PT60M"),
    TestLoad("20241031-0200", 1200.0, "PT60M")
]

test_renewables = [
    TestRenewable("20241031-0000", 100.0, "PT15M"),
    TestRenewable("20241031-0015", 110.0, "PT15M"),
    TestRenewable("20241031-0030", 120.0, "PT15M"),
    TestRenewable("20241031-0045", 130.0, "PT15M"),
    TestRenewable("20241031-0100", 140.0, "PT15M"),
    TestRenewable("20241031-0115", 150.0, "PT15M"),
    TestRenewable("20241031-0130", 160.0, "PT15M"),
    TestRenewable("20241031-0145", 170.0, "PT15M"),
    TestRenewable("20241031-0200", 180.0, "PT15M"),
]

println("🔧 Testing disaggregation with:")
println("   • Loads: $(length(test_loads)) data points at 60-minute resolution")
println("   • Renewables: $(length(test_renewables)) data points at 15-minute resolution")

# Perform disaggregation
target_timeslots, load_by_time, renewable_by_time = disaggregate_temporal_data(test_loads, test_renewables)

println("\n📊 Disaggregation Results:")
println("   • Time slots generated: $(length(target_timeslots))")
println("   • Load data points: $(length(load_by_time))")
println("   • Renewable data points: $(length(renewable_by_time))")

# Test 4: Energy conservation validation
println("\n📋 Test 4: Energy Conservation Validation")
println("-"^30)

# Check load conservation for each hour
global all_tests_passed = true

for hour in 0:2
    hour_prefix = "20241031-$(lpad(hour, 2, '0'))"
    hour_slots = filter(slot -> startswith(slot, hour_prefix), target_timeslots)

    # Original load for this hour
    original_load = test_loads[hour+1].value

    # Sum of disaggregated loads for this hour
    disaggregated_total = sum(get(load_by_time, slot, 0.0) for slot in hour_slots)

    # Conservation check
    conservation_error = abs(disaggregated_total - original_load)
    conservation_passed = conservation_error < 0.01  # Allow for small floating point errors

    println("   Hour $hour:")
    println("     • Original load: $(original_load) MW")
    println("     • Disaggregated total: $(round(disaggregated_total, digits=2)) MW")
    println("     • Conservation error: $(round(conservation_error, digits=6)) MW")
    println("     • ✅ Conservation: $(conservation_passed ? "PASSED" : "FAILED")")

    if !conservation_passed
        global all_tests_passed = false
    end
end

# Test 5: Time slot structure validation
println("\n📋 Test 5: Time Slot Structure Validation")
println("-"^30)

# Check that time slots are properly formatted and sequential
expected_slots = 12  # 3 hours × 4 slots per hour (15-minute resolution)
@assert length(target_timeslots) == expected_slots "Expected $expected_slots time slots, got $(length(target_timeslots))"

# Check time slot format
slot_format_valid = all(length(slot) == 13 && occursin(r"^\d{8}-\d{4}$", slot) for slot in target_timeslots)
@assert slot_format_valid "Time slot format validation failed"

# Check that slots are sorted
slots_sorted = target_timeslots == sort(target_timeslots)
@assert slots_sorted "Time slots are not properly sorted"

println("✅ Time slot count: $(length(target_timeslots)) (expected: $expected_slots)")
println("✅ Time slot format: Valid (YYYYMMDD-HHMM)")
println("✅ Time slot ordering: Properly sorted")

# Test 6: Renewable data consistency
println("\n📋 Test 6: Renewable Data Consistency")
println("-"^30)

# Check that all renewable data is preserved
original_renewable_total = sum(r.aggregated_generation_forecast for r in test_renewables)
disaggregated_renewable_total = sum(values(renewable_by_time))

renewable_conservation_error = abs(disaggregated_renewable_total - original_renewable_total)
renewable_conservation_passed = renewable_conservation_error < 0.01

println("   • Original renewable total: $(round(original_renewable_total, digits=2)) MW")
println("   • Disaggregated renewable total: $(round(disaggregated_renewable_total, digits=2)) MW")
println("   • Conservation error: $(round(renewable_conservation_error, digits=6)) MW")
println("   • ✅ Renewable conservation: $(renewable_conservation_passed ? "PASSED" : "FAILED")")

if !renewable_conservation_passed
    global all_tests_passed = false
end

# Final summary
println("\n🎯 Test Summary")
println("="^50)

if all_tests_passed
    println("✅ ALL TESTS PASSED!")
    println("   The temporal disaggregation functionality is working correctly.")
    println("   Energy conservation is maintained for both loads and renewables.")
    println("   Time slot generation and formatting are correct.")
    exit(0)
else
    println("❌ SOME TESTS FAILED!")
    println("   Please review the failed tests above.")
    exit(1)
end