using Test
using Dates

# Include the main module
include("../src/Euphemia.jl")
using .Euphemia

# Import the format_time function from UnitCommitment
include("../src/UnitCommitment.jl")

"""
    test_euphemia_with_retry(zone, date; max_retries=2, retry_delay=5.0, order_method=:uc_based, model=:mpcc, optimizer="highs")

Test Euphemia market clearing for a zone with automatic retry on database connection failures.
"""
function test_euphemia_with_retry(zone, date; 
    max_retries=2, 
    retry_delay=5.0, 
    order_method=:alternative, 
    model=:mpcc, 
    optimizer="highs",
    markup_factor=1.1,
    random_seed=nothing)
    
    last_error = nothing

    for attempt in 1:max_retries
        try
            return test_euphemia_market_clearing(zone, date; 
                order_method=order_method, 
                model=model, 
                optimizer=optimizer,
                markup_factor=markup_factor,
                random_seed=random_seed)
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

"""
    test_euphemia_market_clearing(zone, date; order_method=:uc_based, model=:mpcc, optimizer="highs", markup_factor=1.1, random_seed=nothing)

Test Euphemia market clearing for a specific zone and date.
"""
function test_euphemia_market_clearing(zone, date; 
    order_method=:alternative, 
    model=:mpcc, 
    optimizer="highs",
    markup_factor=1.1,
    random_seed=nothing)
    
    # Generate energy prices using Euphemia
    prices = generate_energy_prices(zone, date; 
        order_method=order_method,
        model=model,
        optimizer=optimizer,
        markup_factor=markup_factor,
        random_seed=random_seed,
        silent=true)
    
    # Validate results
    if isempty(prices)
        error("No prices generated for zone $zone")
    end
    
    # Check that we have reasonable number of prices based on resolution
    if length(prices) < 24
        error("Too few prices: expected at least 24, got $(length(prices)) prices")
    end
    
    # Determine the resolution based on number of prices
    resolution_minutes = if length(prices) == 24
        60  # Hourly
    elseif length(prices) == 48
        30  # Half-hourly
    elseif length(prices) == 96
        15  # Quarter-hourly
    else
        # Calculate approximate resolution
        round(Int, (24 * 60) / length(prices))
    end
    
    # Check that all prices are reasonable (-1000 to 10000 €/MWh)
    # Note: Negative prices are realistic in electricity markets (excess renewables, must-run units)
    for (hour, price) in prices
        if price < -1000 || price > 10000
            error("Unreasonable price for hour $hour: €$price/MWh")
        end
    end
    
    # Calculate summary statistics
    price_values = collect(values(prices))
    min_price = minimum(price_values)
    max_price = maximum(price_values)
    avg_price = sum(price_values) / length(price_values)
    
    return (
        success=true,
        prices=prices,
        min_price=min_price,
        max_price=max_price,
        avg_price=avg_price,
        total_periods=length(prices),
        resolution_minutes=resolution_minutes
    )
end

# Function to get available bidding zones from the database
function get_available_bidding_zones(test_date::Date)
    query = """
    SELECT DISTINCT map_code
    FROM entsoe.production_and_generation_units
    WHERE production_unit_status = 'COMMISSIONED'
      AND generation_unit_status = 'COMMISSIONED'  
      AND area_type_code IN ('BZN', 'BZN/CTA')
      AND '$test_date' >= valid_from 
      AND ('$test_date' <= valid_to OR valid_to IS NULL)
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

@testset "Euphemia Market Clearing All Bidding Zones" begin
    test_date = Date(2024, 6, 18)
    test_start_time = now()

    # Test different configurations - focusing on Alternative Order Book
    test_configs = [
        (order_method=:alternative, model=:mpcc, optimizer="highs", name="Alternative + MPCC + HiGHS"),
    ]

    # Add Gurobi configurations if available
    try
        using Gurobi
        push!(test_configs, (order_method=:alternative, model=:mpcc, optimizer="gurobi", name="Alternative + MPCC + Gurobi"))
    catch
        @warn "Gurobi not available, skipping Gurobi-based tests"
    end

    println("Getting available bidding zones...")
    zones = get_available_bidding_zones(test_date)

    println("Found $(length(zones)) bidding zones: $(zones)")
    println("Test date: $test_date")
    println("Test started at: $(Dates.format(test_start_time, "yyyy-mm-dd HH:MM:SS"))")
    println("Test configurations: $(length(test_configs))")
    
    for config in test_configs
        println("\n" * "="^80)
        println("TESTING CONFIGURATION: $(config.name)")
        println("="^80)

        successful_zones = String[]
        failed_zones = String[]
        zone_results = Dict{String,Any}()
        zone_timings = Dict{String,Float64}()

        for zone in zones
            current_time = Dates.format(now(), "HH:MM:SS")
            println("\nTesting zone: $zone (started at $current_time)")
            println("-"^40)

            start_time = time()
            try
                result = test_euphemia_with_retry(zone, test_date;
                    order_method=config.order_method,
                    model=config.model,
                    optimizer=config.optimizer,
                    markup_factor=1.1,
                    random_seed=(config.order_method == :alternative ? 12345 : nothing))
                
                elapsed_time = time() - start_time
                zone_timings[zone] = elapsed_time
                zone_results[zone] = result
                
                println("✅ SUCCESS for zone $zone ($(format_time(elapsed_time)))")
                println("   💰 Price range: €$(round(result.min_price, digits=2)) - €$(round(result.max_price, digits=2))/MWh")
                println("   📊 Average price: €$(round(result.avg_price, digits=2))/MWh")
                println("   ⏰ Resolution: $(result.resolution_minutes) minutes ($(result.total_periods) periods)")
                
                push!(successful_zones, zone)
            catch e
                elapsed_time = time() - start_time
                zone_timings[zone] = elapsed_time
                println("❌ FAILED for zone $zone: $e ($(format_time(elapsed_time)))")
                push!(failed_zones, zone)
            end
        end

        println("\n" * "="^80)
        println("SUMMARY - $(config.name)")
        println("="^80)
        println("Total zones tested: $(length(zones))")
        println("Successful: $(length(successful_zones))")
        println("Failed: $(length(failed_zones))")
        
        if !isempty(successful_zones)
            println("\n✅ Successful zones:")
            for zone in successful_zones
                result = zone_results[zone]
                resolution_str = result.resolution_minutes == 60 ? "1h" : "$(result.resolution_minutes)min"
                println("  - $zone: €$(round(result.min_price, digits=1))-$(round(result.max_price, digits=1))/MWh (avg: €$(round(result.avg_price, digits=1))/MWh, $(resolution_str))")
            end
        end

        if !isempty(failed_zones)
            println("\n❌ Failed zones:")
            for zone in failed_zones
                println("  - $zone")
            end
        end

        # Display timing summary
        println("\n" * "="^60)
        println("TIMING SUMMARY - $(config.name)")
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

        # Calculate overall statistics for successful zones
        if !isempty(successful_zones)
            all_prices = Float64[]
            for zone in successful_zones
                result = zone_results[zone]
                append!(all_prices, collect(values(result.prices)))
            end
            
            if !isempty(all_prices)
                overall_min = minimum(all_prices)
                overall_max = maximum(all_prices)
                overall_avg = sum(all_prices) / length(all_prices)
                
                println("\n📈 OVERALL PRICE STATISTICS")
                println("="^40)
                println("Total price points: $(length(all_prices))")
                println("Overall price range: €$(round(overall_min, digits=2)) - €$(round(overall_max, digits=2))/MWh")
                println("Overall average price: €$(round(overall_avg, digits=2))/MWh")
                
                # Resolution breakdown
                resolution_counts = Dict{Int,Int}()
                for zone in successful_zones
                    result = zone_results[zone]
                    resolution_counts[result.resolution_minutes] = get(resolution_counts, result.resolution_minutes, 0) + 1
                end
                
                println("\n📊 RESOLUTION BREAKDOWN")
                println("="^40)
                for (res_min, count) in sort(collect(resolution_counts))
                    res_str = res_min == 60 ? "1 hour" : "$(res_min) minutes"
                    println("  $res_str: $count zones")
                end
            end
        end

        println("="^80)
        println("Configuration $(config.name) completed!")
    end

    println("\n" * "="^80)
    println("ALL CONFIGURATIONS COMPLETED!")
    println("="^80)
    
    total_test_time = (now() - test_start_time).value / 1000  # Convert to seconds
    println("Total test duration: $(format_time(total_test_time))")
end