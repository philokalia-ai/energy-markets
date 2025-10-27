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

export create_adjusted_order_book, AdjustedOrderBookResult

struct AdjustedOrderBookResult
    success::Bool
    message::String
    order_book::Union{Nothing, MPCCOrderBook}
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
        
        # Calculate net demand (load - renewables) for each time period
        renewable_by_time = Dict{String,Float64}()
        for renewable in renewables
            timeslot = renewable.date_time
            if haskey(renewable_by_time, timeslot)
                renewable_by_time[timeslot] += renewable.aggregated_generation_forecast
            else
                renewable_by_time[timeslot] = renewable.aggregated_generation_forecast
            end
        end
        
        # Create orders vector
        orders = SimpleOrder[]
        
        # Supply Orders: Create multiple orders per generator for different time periods
        supply_orders_count = 0
        total_supply_capacity = 0.0
        
        for generator in generators
            # Determine how many orders to create for this generator (spread across time periods)
            num_orders = rand(min_orders_per_generator:max_orders_per_generator)
            
            # Select random time periods for this generator's orders
            selected_hours = sort(rand(0:23, num_orders))
            
            for hour in selected_hours
                date_time = DateTime(day) + Hour(hour)
                
                # Apply random adjustment to generator capacity and price
                capacity_adjustment = 1.0 + rand() * (adjustment_range[2] - adjustment_range[1]) + adjustment_range[1]
                price_adjustment = 1.0 + rand() * (adjustment_range[2] - adjustment_range[1]) + adjustment_range[1]
                
                # Ensure reasonable bounds
                capacity_adjustment = max(0.1, min(2.0, capacity_adjustment))
                price_adjustment = max(0.5, min(1.8, price_adjustment))
                
                adjusted_capacity = generator.p_max * capacity_adjustment
                adjusted_price = generator.marginal_cost * price_adjustment
                
                # Create supply order (capacity available for sale)
                supply_order = SimpleOrder(
                    :supply,                    # type
                    adjusted_price,             # price
                    adjusted_capacity,          # quantity
                    Symbol(bidding_zone),       # zone
                    date_time,                  # date_time
                    60                          # resolution_code (60 minutes)
                )
                
                push!(orders, supply_order)
                supply_orders_count += 1
                total_supply_capacity += adjusted_capacity
            end
        end
        
        # Demand Orders: Create orders based on adjusted load data
        demand_orders_count = 0
        total_demand_quantity = 0.0
        
        for (hour_idx, load) in enumerate(loads[1:min(24, end)])  # Ensure max 24 hours
            date_time = DateTime(day) + Hour(hour_idx - 1)
            
            # Get renewable generation for this time slot
            renewable_gen = get(renewable_by_time, load.timeslot, 0.0)
            net_demand = max(10.0, load.value - renewable_gen)  # Ensure minimum demand
            
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
                60                          # resolution_code (60 minutes)
            )
            
            push!(orders, demand_order)
            demand_orders_count += 1
            total_demand_quantity += adjusted_demand
        end
        
        # Create the MPCC order book
        nodes = [bidding_zone]
        periods = [string(h) for h in 1:24]
        price_limits = (-500.0, 3000.0)  # Typical European market price limits
        
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