using Test
using Dates

# Include the main module
include("../src/Euphemia.jl")
using .Euphemia

# Function to get available bidding zones from the database
function get_available_bidding_zones()
    query = """
    SELECT DISTINCT map_code
    FROM entsoe.production_and_generation_units
    WHERE production_unit_status = 'COMMISSIONED'
      AND generation_unit_status = 'COMMISSIONED'  
      AND area_type_code IN ('BZN', 'BZN/CTA')
      AND map_code IS NOT NULL
    ORDER BY map_code
    """

    try
        df = Euphemia.sql2df(query)
        return df.map_code
    catch e
        @error "Failed to fetch bidding zones: $e"
        return ["GR", "DE", "FR"]  # Fallback to known zones
    end
end

@testset "Unit Commitment All Bidding Zones" begin
    test_date = Date(2024, 6, 18)

    println("Getting available bidding zones...")
    zones = get_available_bidding_zones()

    println("Found $(length(zones)) bidding zones: $(zones)")
    println("Test date: $test_date")
    println("="^60)

    successful_zones = String[]
    failed_zones = String[]

    for zone in zones
        println("\nTesting zone: $zone")
        println("-"^30)

        try
            result = test_unit_commitment(zone, test_date)
            println("✅ SUCCESS for zone $zone")
            push!(successful_zones, zone)
        catch e
            println("❌ FAILED for zone $zone: $e")
            push!(failed_zones, zone)
        end
    end

    println("\n" * "="^60)
    println("SUMMARY")
    println("="^60)
    println("Total zones tested: $(length(zones))")
    println("Successful: $(length(successful_zones)) - $(successful_zones)")
    println("Failed: $(length(failed_zones)) - $(failed_zones)")

    # Test that at least some zones were successful
    @test length(successful_zones) > 0

    println("="^60)
    println("Test completed!")
end