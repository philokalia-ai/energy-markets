module AlternativeOrderBook

"""
Alternative Order Book Generation for MPCC

This module provides functions to create realistic order books by adjusting
real generator and demand data with random variations, bypassing Unit Commitment
complexity while maintaining market realism.
"""

using Dates, Random
import ..get_generators, ..get_loads, ..get_generation_forecast_for_wind_and_solar
import ..MarketOrders: SimpleOrder
import ..MPCC: MPCCOrderBook
import ..parse_resolution_to_minutes, ..determine_finest_resolution, ..generate_sub_slots_from_source, ..disaggregate_temporal_data

"""
    parse_timeslot_to_datetime(timeslot::String, day::Date)

Parses a timeslot string (e.g., "20240618-0015") to DateTime.
"""
function parse_timeslot_to_datetime(timeslot::String, day::Date)
    try
        if length(timeslot) >= 13
            hour_str = timeslot[10:11]
            min_str = timeslot[12:13]
            hour = parse(Int, hour_str)
            minute = parse(Int, min_str)
            return DateTime(day) + Hour(hour) + Minute(minute)
        end
    catch
        # Fallback: return start of day
        return DateTime(day)
    end
    return DateTime(day)
end

struct AdjustedOrderBookResult
    success::Bool
    message::String
    order_book::Union{Nothing,MPCCOrderBook}
    generators_used::Int
    demand_orders::Int
    supply_orders::Int
    total_demand::Float64
    total_supply::Float64
    supply_demand_ratio::Float64
end

"""
    create_adjusted_order_book(bidding_zone::String, day::Date; 
                              adjustment_range::Tuple{Float64,Float64}=(-0.10, 0.30),
                              min_orders_per_generator::Int=3,
                              max_orders_per_generator::Int=8,
                              random_seed::Union{Int,Nothing}=nothing)

Create an order book by adjusting real generator and demand data with random variations.

# Arguments
- `bidding_zone::String`: The bidding zone (e.g., "GR")
- `day::Date`: The day for which to create the order book
- `adjustment_range::Tuple{Float64,Float64}`: Range for random adjustments (-10% to +30% by default)
- `min_orders_per_generator::Int`: Minimum number of orders per generator
- `max_orders_per_generator::Int`: Maximum number of orders per generator  
- `random_seed::Union{Int,Nothing}`: Optional random seed for reproducibility

# Returns
- `AdjustedOrderBookResult`: Contains the order book and metadata
"""
function create_adjusted_order_book(
    bidding_zone::String,
    day::Date;
    adjustment_range::Tuple{Float64,Float64}=(-0.10, 0.30),
    min_orders_per_generator::Int=3,
    max_orders_per_generator::Int=8,
    random_seed::Union{Int,Nothing}=nothing
)

    if !isnothing(random_seed)
        Random.seed!(random_seed)
    end

    try
        println("📊 Creating adjusted order book for $bidding_zone on $day")

        # Get real data
        generators = get_generators(bidding_zone, day)
        loads = get_loads(bidding_zone, day)
        renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day)

        if isempty(generators)
            return AdjustedOrderBookResult(false, "No generators found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        if isempty(loads)
            return AdjustedOrderBookResult(false, "No load data found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end

        println("  📋 Base data: $(length(generators)) generators, $(length(loads)) load points")

        # Disaggregate all temporal data to finest resolution using centralized utilities
        target_timeslots, load_by_time, renewable_by_time, resolution_minutes = disaggregate_temporal_data(loads, renewables)

        # Create orders vector
        orders = SimpleOrder[]

        # Supply Orders: Create multiple orders per generator for different time periods
        supply_orders_count = 0
        total_supply_capacity = 0.0

        for generator in generators
            # Each generator should be available for ALL time periods (realistic market behavior)
            # Generators typically offer their capacity for each hour unless they're offline
            selected_timeslots = target_timeslots

            for timeslot in selected_timeslots
                # Parse timeslot to get DateTime
                date_time = parse_timeslot_to_datetime(timeslot, day)

                # Apply random adjustment to generator availability and price
                # Capacity adjustment represents partial availability (maintenance, forced outages, etc.)
                capacity_adjustment = 0.3 + rand() * 0.7  # 30% to 100% availability
                price_adjustment = 1.0 + rand() * (adjustment_range[2] - adjustment_range[1]) + adjustment_range[1]

                # Ensure reasonable bounds
                capacity_adjustment = max(0.3, min(1.0, capacity_adjustment))  # Can't exceed physical capacity
                price_adjustment = max(0.5, min(1.8, price_adjustment))

                # For sub-hourly intervals, don't scale capacity - keep MW rating as is
                # The time resolution affects energy (MWh) but not power capacity (MW)
                adjusted_capacity = generator.p_max * capacity_adjustment
                adjusted_price = generator.marginal_cost * price_adjustment

                # Create supply order (capacity available for sale)
                supply_order = SimpleOrder(
                    :supply,                    # type
                    adjusted_price,             # price
                    adjusted_capacity,          # quantity
                    Symbol(bidding_zone),       # zone
                    date_time,                  # date_time
                    resolution_minutes          # resolution_code (detected resolution)
                )

                push!(orders, supply_order)
                supply_orders_count += 1
                total_supply_capacity += adjusted_capacity
            end
        end

        # Demand Orders: Create orders based on adjusted load data at finest resolution
        demand_orders_count = 0
        total_demand_quantity = 0.0

        for timeslot in target_timeslots
            # Parse timeslot to get DateTime
            date_time = parse_timeslot_to_datetime(timeslot, day)

            # Get load and renewable data for this time slot
            load_value = get(load_by_time, timeslot, 0.0)
            renewable_gen = get(renewable_by_time, timeslot, 0.0)
            net_demand = max(10.0, load_value - renewable_gen)  # Ensure minimum demand

            # Apply random adjustment to demand
            demand_adjustment = 1.0 + rand() * (adjustment_range[2] - adjustment_range[1]) + adjustment_range[1]
            demand_adjustment = max(0.7, min(1.5, demand_adjustment))  # More conservative for demand

            adjusted_demand = net_demand * demand_adjustment

            # Create demand price based on typical market conditions (higher than marginal costs)
            demand_price = rand(80:250)  # €/MWh - realistic demand price range

            # Create demand order
            demand_order = SimpleOrder(
                :demand,                    # type
                demand_price,               # price
                adjusted_demand,            # quantity
                Symbol(bidding_zone),       # zone
                date_time,                  # date_time
                resolution_minutes          # resolution_code (detected resolution)
            )

            push!(orders, demand_order)
            demand_orders_count += 1
            total_demand_quantity += adjusted_demand
        end

        # Create the MPCC order book
        nodes = [bidding_zone]
        periods = target_timeslots  # Use actual target timeslots at finest resolution
        price_limits = (-1000.0, 3000.0)  # Allow more negative prices to see natural market clearing

        order_book = MPCCOrderBook(orders, nodes, periods, price_limits, nothing)

        # Calculate supply-demand ratio
        supply_demand_ratio = total_supply_capacity > 0 ? total_supply_capacity / total_demand_quantity : 0.0

        println("  ✅ Created order book:")
        println("     📦 Supply orders: $supply_orders_count ($(round(total_supply_capacity)) MW)")
        println("     📈 Demand orders: $demand_orders_count ($(round(total_demand_quantity)) MW)")
        println("     ⚖️  Supply/Demand ratio: $(round(supply_demand_ratio, digits=2))")

        return AdjustedOrderBookResult(
            true,
            "Order book created successfully",
            order_book,
            length(generators),
            demand_orders_count,
            supply_orders_count,
            total_demand_quantity,
            total_supply_capacity,
            supply_demand_ratio
        )

    catch e
        error_msg = "Error creating adjusted order book: $e"
        println("  ❌ $error_msg")
        return AdjustedOrderBookResult(false, error_msg, nothing, 0, 0, 0, 0.0, 0.0, 0.0)
    end
end

"""
    print_order_book_summary(result::AdjustedOrderBookResult)

Print a detailed summary of the created order book.
"""
function print_order_book_summary(result::AdjustedOrderBookResult)
    if !result.success
        println("❌ Order book creation failed: $(result.message)")
        return
    end

    println("\n" * "="^70)
    println("ADJUSTED ORDER BOOK SUMMARY")
    println("="^70)

    println("📊 Market Structure:")
    println("   Generators used: $(result.generators_used)")
    println("   Supply orders: $(result.supply_orders)")
    println("   Demand orders: $(result.demand_orders)")
    println("   Total orders: $(result.supply_orders + result.demand_orders)")

    println("\n💰 Market Volumes:")
    println("   Total supply capacity: $(round(result.total_supply, digits=1)) MW")
    println("   Total demand: $(round(result.total_demand, digits=1)) MW")
    println("   Supply/Demand ratio: $(round(result.supply_demand_ratio, digits=2))")

    if result.supply_demand_ratio < 0.8
        println("   ⚠️  Supply shortage - expect high prices")
    elseif result.supply_demand_ratio > 1.5
        println("   ℹ️  Supply surplus - expect low prices")
    else
        println("   ✅ Balanced market conditions")
    end

    # Analyze order distribution by time period
    if !isnothing(result.order_book)
        orders_by_hour = Dict{Int,Int}()
        for order in result.order_book.orders
            hour = Dates.hour(order.date_time)
            orders_by_hour[hour] = get(orders_by_hour, hour, 0) + 1
        end

        println("\n⏰ Orders by Time Period:")
        for hour in sort(collect(keys(orders_by_hour)))
            count = orders_by_hour[hour]
            println("   Hour $hour: $count orders")
        end
    end

    println("="^70)
end

end  # module AlternativeOrderBook