module BiddingStrategy

using Dates
using JuMP: OPTIMAL
# Note: MarketOrders and UnitCommitment should be included before this module
import Main.MarketOrders: SimpleOrder
import Main: solve_unit_commitment

export generate_market_orders_from_uc, UCToBidsResult

"""
    UCToBidsResult

Structure to hold the result of converting unit commitment solution to market orders.
"""
struct UCToBidsResult
    supply_orders::Vector{SimpleOrder}
    demand_orders::Vector{SimpleOrder}
    bidding_zone::Symbol
    day::Date
    total_supply_quantity::Float64
    total_demand_quantity::Float64
    success::Bool
    message::String
end

"""
    generate_market_orders_from_uc(bidding_zone::String, day::Date; markup_factor::Float64=1.1)

Converts the unit commitment optimization results into simple market orders for Euphemia.

# Arguments
- `bidding_zone::String`: The bidding zone identifier (e.g., "GR")
- `day::Date`: The target day for optimization and bidding
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1 = 10% markup)

# Returns
- `UCToBidsResult`: Contains supply orders, demand orders, and metadata

# Supply Strategy
For each generator and time period where the unit is committed:
- Creates SimpleOrder with price = marginal_cost × markup_factor
- Quantity = optimized generation level for that period
- Only creates orders for committed units (u[i,t] > 0.5)

# Demand Strategy  
For each time period:
- Creates SimpleOrder representing the net demand that needs to be served
- Price = high value (€3000/MWh) to ensure demand is always met
- Quantity = net demand for that period

# Example
```julia
result = generate_market_orders_from_uc("GR", Date("2018-06-24"))
if result.success
    println("Generated \$(length(result.supply_orders)) supply orders")
    println("Generated \$(length(result.demand_orders)) demand orders")
end
```
"""
function generate_market_orders_from_uc(
    bidding_zone::String, 
    day::Date; 
    markup_factor::Float64=1.1,
    demand_price::Float64=3000.0
)
    
    try
        # Solve unit commitment first
        println("Solving unit commitment for $bidding_zone on $day...")
        uc_solution = solve_unit_commitment(bidding_zone, day)
        
        if uc_solution.status != OPTIMAL
            return UCToBidsResult(
                SimpleOrder[], SimpleOrder[], Symbol(bidding_zone), day,
                0.0, 0.0, false, "Unit commitment optimization failed: $(uc_solution.status)"
            )
        end
        
        zone_symbol = Symbol(bidding_zone)
        supply_orders = SimpleOrder[]
        demand_orders = SimpleOrder[]
        
        # Extract solution data
        generators = uc_solution.generators
        time_slots = uc_solution.time_slots
        generation = uc_solution.g  # Generation matrix [generator, time]
        commitment = uc_solution.u  # Commitment matrix [generator, time]
        net_demand = uc_solution.net_demand
        
        N = length(generators)
        T = length(time_slots)
        
        println("Converting UC solution to market orders...")
        println("- $N generators, $T time periods")
        
        # Generate supply orders from committed generators
        total_supply_quantity = 0.0
        for i in 1:N
            gen = generators[i]
            for t in 1:T
                # Only create orders for committed units with positive generation
                if commitment[i, t] > 0.5 && generation[i, t] > 0.01  # Small threshold for numerical precision
                    
                    # Calculate bid price with markup
                    bid_price = gen.marginal_cost * markup_factor
                    bid_quantity = generation[i, t]
                    
                    # Create supply order
                    order = SimpleOrder(
                        :supply,
                        bid_price,
                        bid_quantity,
                        zone_symbol
                    )
                    
                    push!(supply_orders, order)
                    total_supply_quantity += bid_quantity
                    
                    # Debug output for first few orders
                    if length(supply_orders) <= 5
                        println("  Supply order: Gen$(i) T$(t) - $(bid_quantity)MW @ €$(round(bid_price, digits=2))/MWh")
                    end
                end
            end
        end
        
        # Generate demand orders from net demand
        total_demand_quantity = 0.0
        for t in 1:T
            if net_demand[t] > 0.01  # Small threshold for numerical precision
                
                # Create demand order with high price to ensure it's always served
                order = SimpleOrder(
                    :demand,
                    demand_price,  # High price to ensure demand is met
                    net_demand[t],
                    zone_symbol
                )
                
                push!(demand_orders, order)
                total_demand_quantity += net_demand[t]
                
                # Debug output for first few orders
                if length(demand_orders) <= 5
                    println("  Demand order: T$(t) - $(net_demand[t])MW @ €$(demand_price)/MWh")
                end
            end
        end
        
        println("Market orders generation completed:")
        println("- $(length(supply_orders)) supply orders ($(round(total_supply_quantity, digits=1)) MW total)")
        println("- $(length(demand_orders)) demand orders ($(round(total_demand_quantity, digits=1)) MW total)")
        
        return UCToBidsResult(
            supply_orders,
            demand_orders,
            zone_symbol,
            day,
            total_supply_quantity,
            total_demand_quantity,
            true,
            "Successfully converted UC solution to $(length(supply_orders) + length(demand_orders)) market orders"
        )
        
    catch e
        error_msg = "Error in generate_market_orders_from_uc: $(string(e))"
        println(error_msg)
        return UCToBidsResult(
            SimpleOrder[], SimpleOrder[], Symbol(bidding_zone), day,
            0.0, 0.0, false, error_msg
        )
    end
end

"""
    print_orders_summary(result::UCToBidsResult)

Prints a summary of the generated market orders.
"""
function print_orders_summary(result::UCToBidsResult)
    if !result.success
        println("❌ Bidding strategy failed: $(result.message)")
        return
    end
    
    println("\n📊 Market Orders Summary for $(result.bidding_zone) on $(result.day)")
    println("=" ^ 50)
    
    # Supply orders analysis
    if !isempty(result.supply_orders)
        supply_prices = [order.price for order in result.supply_orders]
        supply_quantities = [order.quantity for order in result.supply_orders]
        
        println("🔵 SUPPLY ORDERS:")
        println("  Count: $(length(result.supply_orders))")
        println("  Total quantity: $(round(result.total_supply_quantity, digits=1)) MW")
        println("  Price range: €$(round(minimum(supply_prices), digits=2)) - €$(round(maximum(supply_prices), digits=2))/MWh")
        println("  Avg price: €$(round(sum(supply_prices .* supply_quantities) / sum(supply_quantities), digits=2))/MWh (quantity-weighted)")
    end
    
    # Demand orders analysis  
    if !isempty(result.demand_orders)
        demand_quantities = [order.quantity for order in result.demand_orders]
        
        println("\n🔴 DEMAND ORDERS:")
        println("  Count: $(length(result.demand_orders))")
        println("  Total quantity: $(round(result.total_demand_quantity, digits=1)) MW")
        println("  Price: €$(result.demand_orders[1].price)/MWh (fixed high price)")
    end
    
    println("\n✅ $(result.message)")
end

"""
    export_orders_to_csv(result::UCToBidsResult, filepath::String)

Exports the generated market orders to a CSV file for analysis or external use.
"""
function export_orders_to_csv(result::UCToBidsResult, filepath::String)
    if !result.success
        println("❌ Cannot export orders: $(result.message)")
        return false
    end
    
    try
        # Combine all orders into a single DataFrame-like structure
        orders_data = []
        
        # Add supply orders
        for (i, order) in enumerate(result.supply_orders)
            push!(orders_data, (
                order_id = "SUPPLY_$i",
                type = string(order.type),
                price = order.price,
                quantity = order.quantity,
                zone = string(order.zone),
                day = string(result.day)
            ))
        end
        
        # Add demand orders
        for (i, order) in enumerate(result.demand_orders)
            push!(orders_data, (
                order_id = "DEMAND_$i", 
                type = string(order.type),
                price = order.price,
                quantity = order.quantity,
                zone = string(order.zone),
                day = string(result.day)
            ))
        end
        
        # Write to CSV (simple implementation)
        open(filepath, "w") do file
            # Header
            println(file, "order_id,type,price,quantity,zone,day")
            
            # Data rows
            for row in orders_data
                println(file, "$(row.order_id),$(row.type),$(row.price),$(row.quantity),$(row.zone),$(row.day)")
            end
        end
        
        println("✅ Exported $(length(orders_data)) orders to $filepath")
        return true
        
    catch e
        println("❌ Error exporting orders: $(string(e))")
        return false
    end
end

end  # module BiddingStrategy
