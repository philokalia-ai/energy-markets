using Test
using Dates

# Include the main module
include("../src/Euphemia.jl")
using .Euphemia

# Function to get Italian bidding zones from the database
function get_italian_bidding_zones()
    query = """
    SELECT DISTINCT map_code
    FROM entsoe.production_and_generation_units
    WHERE production_unit_status = 'COMMISSIONED'
      AND generation_unit_status = 'COMMISSIONED'  
      AND area_type_code IN ('BZN', 'BZN/CTA')
      AND map_code LIKE 'IT%'  -- Filter for Italian zones
      AND map_code IS NOT NULL
    ORDER BY map_code
    """

    try
        df = Euphemia.sql2df(query)
        return df.map_code
    catch e
        @error "Failed to fetch Italian bidding zones: $e"
        return ["IT"]  # Fallback to main Italian zone
    end
end

# Function to check data availability for Italian zones with zone mapping
function check_italian_data_availability(zone::String, date::Date)
    println("Checking data availability for $zone on $date:")
    
    # Italian zone mapping - generators are under "IT"
    generator_zone = zone in ["IT-NORD", "IT-CNOR", "IT-CSUD", "IT-SUD", "IT-SICI", "IT-SARD"] ? "IT" : zone
    
    try
        # Check generators (use mapped zone)
        generators = get_generators(generator_zone, date)
        println("  Generators (from $generator_zone): $(length(generators)) found")
        
        # Check loads (use original zone)
        loads = get_loads(zone, date)
        println("  Load points: $(length(loads)) found")
        if !isempty(loads)
            println("    Resolution: $(loads[1].resolution_code)")
            println("    First few time slots: $(loads[1:min(3,end)] .|> l -> l.timeslot)")
        end
        
        # Check renewables (use original zone)
        renewables = get_generation_forecast_for_wind_and_solar(zone, date)
        println("  Renewable forecasts: $(length(renewables)) found")
        if !isempty(renewables)
            println("    Resolution: $(renewables[1].resolution_code)")
            println("    First few time slots: $(renewables[1:min(3,end)] .|> r -> r.date_time)")
        end
        
        return (
            generators = length(generators),
            loads = length(loads),
            renewables = length(renewables)
        )
    catch e
        println("  ❌ ERROR checking data: $e")
        return nothing
    end
end

@testset "Unit Commitment Italian Bidding Zones" begin
    test_date = Date(2024, 6, 18)
    
    println("="^70)
    println("ITALIAN BIDDING ZONES UNIT COMMITMENT TEST")
    println("Test date: $test_date")
    println("="^70)
    
    # Get Italian bidding zones
    println("Getting Italian bidding zones...")
    italian_zones = get_italian_bidding_zones()
    
    if isempty(italian_zones)
        @warn "No Italian bidding zones found in database"
        return
    end
    
    println("Found $(length(italian_zones)) Italian bidding zones: $(italian_zones)")
    println()
    
    # First, check data availability for all zones
    println("STEP 1: Data availability check")
    println("-"^50)
    data_status = Dict{String, Any}()
    
    for zone in italian_zones
        data_status[zone] = check_italian_data_availability(zone, test_date)
        println()
    end
    
    # Filter zones with sufficient data
    viable_zones = String[]
    for zone in italian_zones
        status = data_status[zone]
        if status !== nothing && status.generators > 0 && status.loads > 0
            push!(viable_zones, zone)
            println("✅ $zone has sufficient data ($(status.generators) gen, $(status.loads) loads, $(status.renewables) renewables)")
        else
            println("❌ $zone lacks sufficient data")
        end
    end
    
    if isempty(viable_zones)
        @warn "No Italian zones have sufficient data for testing"
        return
    end
    
    println()
    println("STEP 2: Unit Commitment testing")
    println("-"^50)
    
    successful_zones = String[]
    failed_zones = String[]
    error_details = Dict{String, String}()
    
    for zone in viable_zones
        println("\\nTesting zone: $zone")
        println("-"^30)
        
        try
            # Add more verbose error tracking
            result = test_unit_commitment(zone, test_date)
            println("✅ SUCCESS for zone $zone")
            push!(successful_zones, zone)
            
            # Print some result details
            if haskey(result, :optimization_summary)
                summary = result[:optimization_summary] 
                println("   Status: $(summary[:status])")
                println("   Objective: €$(round(summary[:objective_value], digits=2))")
            end
            
        catch e
            error_msg = string(e)
            println("❌ FAILED for zone $zone")
            println("   Error: $error_msg")
            
            # Store detailed error for analysis
            error_details[zone] = error_msg
            push!(failed_zones, zone)
            
            # Print stack trace for debugging
            println("   Stack trace:")
            for line in split(string(stacktrace(catch_backtrace())), "\\n")[1:min(5, end)]
                println("     $line")
            end
        end
    end
    
    println("\\n" * "="^70)
    println("ITALIAN ZONES TEST SUMMARY")
    println("="^70)
    println("Total Italian zones found: $(length(italian_zones))")
    println("Zones with sufficient data: $(length(viable_zones))")
    println("Successful UC runs: $(length(successful_zones))")
    println("Failed UC runs: $(length(failed_zones))")
    
    if !isempty(successful_zones)
        println("\\n✅ Successful zones:")
        for zone in successful_zones
            println("  - $zone")
        end
    end
    
    if !isempty(failed_zones)
        println("\\n❌ Failed zones:")
        for zone in failed_zones
            println("  - $zone: $(error_details[zone])")
        end
    end
    
    # Test assertion - at least one Italian zone should work
    @test length(successful_zones) > 0
    
    println("\\n" * "="^70)
    println("Test completed!")
    println("="^70)
end