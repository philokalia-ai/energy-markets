using Test
using Dates

# Include the main module
include("../src/Euphemia.jl")
using .Euphemia

# Import the format_time function from UnitCommitment
include("../src/UnitCommitment.jl")

"""
    test_unit_commitment_with_retry(zone, date; max_retries=2, retry_delay=5.0)

Test unit commitment for a zone with automatic retry on database connection failures.
"""
function test_unit_commitment_with_retry(zone, date; max_retries=2, retry_delay=5.0)
    last_error = nothing

    for attempt in 1:max_retries
        try
            return test_unit_commitment(zone, date)
        catch e
            last_error = e

            # Check if it's a database connection error
            if (isa(e, TaskFailedException) &&
                occursin("JLConnectionError", string(e))) ||
               (isa(e, Exception) &&
                (occursin("PostgreSQL connection", string(e)) ||
                 occursin("connection socket", string(e))))

                if attempt < max_retries
                    @warn "Database connection failed for zone $zone (attempt $attempt/$max_retries)"
                    @info "Retrying in $retry_delay seconds..."
                    sleep(retry_delay)
                    continue
                else
                    @error "Zone $zone failed after $max_retries attempts due to connection issues"
                end
            else
                # Non-connection error, don't retry
                break
            end
        end
    end

    # If we get here, all retries failed
    throw(last_error)
end

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
        df = Euphemia.sql2df_with_retry(query)
        return df.map_code
    catch e
        @error "Failed to fetch bidding zones: $e"
        return ["GR", "DE", "FR"]  # Fallback to known zones
    end
end

@testset "Unit Commitment All Bidding Zones" begin
    test_date = Date(2024, 6, 18)
    test_start_time = now()

    println("Getting available bidding zones...")
    zones = get_available_bidding_zones()

    println("Found $(length(zones)) bidding zones: $(zones)")
    println("Test date: $test_date")
    println("Test started at: $(Dates.format(test_start_time, "yyyy-mm-dd HH:MM:SS"))")
    println("="^60)

    successful_zones = String[]
    failed_zones = String[]
    zone_timings = Dict{String,Float64}()

    for zone in zones
        current_time = Dates.format(now(), "HH:MM:SS")
        println("\nTesting zone: $zone (started at $current_time)")
        println("-"^30)

        start_time = time()
        try
            result = test_unit_commitment_with_retry(zone, test_date)
            elapsed_time = time() - start_time
            zone_timings[zone] = elapsed_time
            println("✅ SUCCESS for zone $zone ($(format_time(elapsed_time)))")
            push!(successful_zones, zone)
        catch e
            elapsed_time = time() - start_time
            zone_timings[zone] = elapsed_time
            println("❌ FAILED for zone $zone: $e ($(format_time(elapsed_time)))")
            push!(failed_zones, zone)
        end
    end

    println("\n" * "="^60)
    println("SUMMARY")
    println("="^60)
    println("Total zones tested: $(length(zones))")
    println("Successful: $(length(successful_zones)) - $(successful_zones)")
    println("Failed: $(length(failed_zones)) - $(failed_zones)")

    # Display timing summary
    println("\n" * "="^60)
    println("TIMING SUMMARY")
    println("="^60)

    # Sort zones by execution time (longest first)
    sorted_timings = sort(collect(zone_timings), by=x -> x[2], rev=true)

    for (zone, elapsed_time) in sorted_timings
        status = zone in successful_zones ? "✅" : "❌"
        println("$status $zone: $(format_time(elapsed_time))")
    end

    if !isempty(zone_timings)
        total_time = sum(values(zone_timings))
        avg_time = total_time / length(zone_timings)
        println("\nTotal execution time: $(format_time(total_time))")
        println("Average time per zone: $(format_time(avg_time))")
    end

    # Test that at least some zones were successful
    @test length(successful_zones) > 0

    println("="^60)
    println("Test completed!")
end