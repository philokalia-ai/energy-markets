module BiddingStrategy

using Dates
using JuMP: OPTIMAL
# Note: MarketOrders and UnitCommitment should be included before this module
import ..Euphemia.MarketOrders: SimpleOrder
import ..Euphemia: solve_unit_commitment, get_loads

# Configuration constants
const DEFAULT_UNCOMMITTED_UNIT_FRACTION = 0.2  # 20% of max capacity for uncommitted units with very low p_min
const COMMITMENT_THRESHOLD = 0.5  # Threshold for determining if a unit is committed (u[i,t] > 0.5)
const GENERATION_THRESHOLD = 0.01  # Minimum generation threshold in MW for numerical precision
const DEMAND_THRESHOLD = 0.01  # Minimum demand threshold in MW for numerical precision

export generate_market_orders_from_uc, apply_bidding_strategy_to_uc, UCToBidsResult

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
    generate_market_orders_from_uc(bidding_zone::String, day::Date; markup_factor::Float64=1.1, bidding_strategy::Symbol=:committed_only)

Converts the unit commitment optimization results into simple market orders for Euphemia.

# Arguments
- `bidding_zone::String`: The bidding zone identifier (e.g., "GR")
- `day::Date`: The target day for optimization and bidding
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1 = 10% markup)
- `bidding_strategy::Symbol`: Strategy for creating supply orders
  - `:committed_only` - Only bid committed units (conservative, respects UC constraints)
  - `:all_available_max` - Bid all units at maximum capacity (unrealistic but useful for testing)
  - `:all_available_realistic` - Bid all units with UC-informed realistic quantities (aggressive)
- `uncommitted_unit_fraction::Float64`: Fraction of p_max to use for uncommitted units with very low p_min (default: 0.2 = 20%)

# Returns
- `UCToBidsResult`: Contains supply orders, demand orders, and metadata

# Supply Strategies

## :committed_only (Conservative)
For each generator and time period where the unit is committed:
- Creates SimpleOrder with price = marginal_cost × markup_factor
- Quantity = optimized generation level for that period
- Only creates orders for committed units (u[i,t] > COMMITMENT_THRESHOLD)
- Respects complex UC constraints (startup times, ramping, minimum uptimes)

## :all_available_max (Maximum Capacity)
For each generator and time period:
- Creates SimpleOrder with price = marginal_cost × markup_factor  
- Quantity = p_max (maximum capacity regardless of UC solution)
- Bids all units at their theoretical maximum capacity
- Unrealistic but useful for testing market clearing behavior
- Ignores UC constraints and operational limitations

## :all_available_realistic (UC-Informed Realistic)
For each generator and time period:
- Creates SimpleOrder with price = marginal_cost × markup_factor  
- Quantity = available capacity considering operational constraints
- Bids all units regardless of UC commitment decision
- Uses UC solution to inform realistic bid quantities (not just p_max)
- Lets Euphemia handle final dispatch optimization

# Demand Strategy  
For each time period:
- Creates SimpleOrder representing the net demand that needs to be served
- Price = high value (€3000/MWh) to ensure demand is always met
- Quantity = net demand for that period

# Example
```julia
# Conservative approach (only committed units)
result1 = generate_market_orders_from_uc("GR", Date("2018-06-24"))

# Maximum capacity approach (all units at p_max)
result2 = generate_market_orders_from_uc("GR", Date("2018-06-24"), bidding_strategy=:all_available_max)

# Realistic approach (all units with UC-informed quantities)
result3 = generate_market_orders_from_uc("GR", Date("2018-06-24"), bidding_strategy=:all_available_realistic)
```
"""
function generate_market_orders_from_uc(
    bidding_zone::String,
    day::Date;
    markup_factor::Float64=1.1,
    demand_price::Float64=500.0,
    bidding_strategy::Symbol=:committed_only,
    uncommitted_unit_fraction::Float64=DEFAULT_UNCOMMITTED_UNIT_FRACTION
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

        # Get resolution from loads data (convert PT60M to 60)
        loads = get_loads(bidding_zone, day)  # Get loads to extract resolution
        resolution_str = loads[1].resolution_code  # e.g., "PT60M"
        match_result = match(r"PT(\d+)M", resolution_str)  # Attempt to match the pattern
        if match_result === nothing
            error("Invalid resolution format: $(resolution_str). Expected format: 'PT<number>M'.")
        end
        resolution_minutes = parse(Int, match_result[1])  # Extract 60 from "PT60M"

        N = length(generators)
        T = length(time_slots)

        println("Converting UC solution to market orders...")
        println("- $N generators, $T time periods")
        println("- Resolution: $(resolution_minutes) minutes")
        println("- Bidding strategy: $bidding_strategy")

        # Generate supply orders from generators
        total_supply_quantity = 0.0
        for i in 1:N
            gen = generators[i]
            for t in 1:T

                # Determine if we should create an order based on strategy
                should_bid = false
                bid_quantity = 0.0

                if bidding_strategy == :committed_only
                    # Conservative: Only bid committed units with positive generation
                    if commitment[i, t] > COMMITMENT_THRESHOLD && generation[i, t] > GENERATION_THRESHOLD
                        should_bid = true
                        bid_quantity = generation[i, t]  # Bid actual optimized generation
                    end
                elseif bidding_strategy == :all_available_max
                    # Maximum capacity: Bid all units at their theoretical maximum
                    should_bid = true
                    bid_quantity = gen.p_max  # Always bid maximum capacity
                elseif bidding_strategy == :all_available_realistic
                    # UC-informed realistic: Bid all units with realistic quantities
                    should_bid = true

                    if commitment[i, t] > COMMITMENT_THRESHOLD && generation[i, t] > GENERATION_THRESHOLD
                        # Committed unit: bid actual UC generation (what UC selected)
                        bid_quantity = generation[i, t]
                    else
                        # Uncommitted unit: bid realistic available capacity
                        # Consider what they could deliver if economic conditions changed slightly

                        # For uncommitted units, bid their minimum capacity as a conservative estimate
                        # This represents what they could deliver if called upon
                        if gen.p_min > GENERATION_THRESHOLD
                            bid_quantity = gen.p_min  # Minimum stable generation
                        else
                            # For units with very low p_min, use a configurable fraction of max capacity
                            bid_quantity = gen.p_max * uncommitted_unit_fraction
                        end
                    end
                else
                    error("Unknown bidding strategy: $bidding_strategy. Valid options: :committed_only, :all_available_max, :all_available_realistic")
                end

                if should_bid
                    # Calculate bid price with markup
                    bid_price = gen.marginal_cost * markup_factor
                    time_slot = time_slots[t]  # Get the time slot for this period

                    # Parse time slot and create supply order with time and resolution information
                    local date_time
                    try
                        date_time = DateTime(time_slot, "yyyymmdd-HHMM")
                    catch e
                        error("Invalid time_slot format: '$(time_slot)'. Expected format: 'YYYYMMDD-HHMM'. Error: $(e)")
                    end

                    order = SimpleOrder(
                        :supply,
                        bid_price,
                        bid_quantity,
                        zone_symbol,
                        date_time,
                        resolution_minutes
                    )

                    push!(supply_orders, order)
                    total_supply_quantity += bid_quantity

                    # Debug output for first few orders
                    if length(supply_orders) <= 5
                        if bidding_strategy == :committed_only
                            strategy_label = "UC=$(round(generation[i,t], digits=1))MW"
                        elseif bidding_strategy == :all_available_max
                            strategy_label = "Max=$(round(bid_quantity, digits=1))MW"
                        else  # :all_available_realistic
                            committed_status = commitment[i, t] > COMMITMENT_THRESHOLD ? "Committed" : "Uncommitted"
                            if commitment[i, t] > COMMITMENT_THRESHOLD
                                strategy_label = "$(committed_status)=$(round(generation[i,t], digits=1))MW"
                            else
                                strategy_label = "$(committed_status)=$(round(bid_quantity, digits=1))MW(min)"
                            end
                        end
                        println("  Supply order: Gen$(i) $(time_slot) - $(strategy_label) @ €$(round(bid_price, digits=2))/MWh")
                    end
                end
            end
        end

        # Generate demand orders from net demand
        total_demand_quantity = 0.0
        for t in 1:T
            if net_demand[t] > DEMAND_THRESHOLD  # Small threshold for numerical precision

                time_slot = time_slots[t]  # Get the time slot for this period

                # Parse time slot and create demand order with high price to ensure it's always served
                local date_time
                try
                    date_time = DateTime(time_slot, "yyyymmdd-HHMM")
                catch e
                    error("Invalid time_slot format: '$(time_slot)'. Expected format: 'YYYYMMDD-HHMM'. Error: $(e)")
                end

                order = SimpleOrder(
                    :demand,
                    demand_price,  # High price to ensure demand is met
                    net_demand[t],
                    zone_symbol,
                    date_time,
                    resolution_minutes
                )

                push!(demand_orders, order)
                total_demand_quantity += net_demand[t]

                # Debug output for first few orders
                if length(demand_orders) <= 5
                    println("  Demand order: $(time_slot) - $(net_demand[t])MW @ €$(demand_price)/MWh")
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
    apply_bidding_strategy_to_uc(uc_solution, bidding_zone::String, day::Date; markup_factor::Float64=1.1, demand_price::Float64=3000.0, bidding_strategy::Symbol=:committed_only)

Applies a bidding strategy to an already-solved unit commitment problem.
This is more efficient than `generate_market_orders_from_uc` when testing multiple strategies 
on the same UC solution, as it avoids re-solving the expensive optimization.

# Arguments
- `uc_solution`: Pre-solved unit commitment result from `solve_unit_commitment()`
- `bidding_zone::String`: The bidding zone identifier (e.g., "GR")
- `day::Date`: The target day for bidding
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1 = 10% markup)
- `demand_price::Float64`: Price for demand orders (default: €3000/MWh)
- `bidding_strategy::Symbol`: Strategy for creating supply orders (same as generate_market_orders_from_uc)
- `uncommitted_unit_fraction::Float64`: Fraction of p_max to use for uncommitted units with very low p_min (default: 0.2 = 20%)

# Returns
- `UCToBidsResult`: Contains supply orders, demand orders, and metadata

# Example
```julia
# Solve UC once
uc_solution = solve_unit_commitment("GR", Date("2018-06-24"))

# Apply different strategies to the same solution (much faster!)
result1 = apply_bidding_strategy_to_uc(uc_solution, "GR", Date("2018-06-24"), bidding_strategy=:committed_only)
result2 = apply_bidding_strategy_to_uc(uc_solution, "GR", Date("2018-06-24"), bidding_strategy=:all_available_max)
result3 = apply_bidding_strategy_to_uc(uc_solution, "GR", Date("2018-06-24"), bidding_strategy=:all_available_realistic)
```
"""
function apply_bidding_strategy_to_uc(
    uc_solution,
    bidding_zone::String,
    day::Date;
    markup_factor::Float64=1.1,
    demand_price::Float64=500.0,
    bidding_strategy::Symbol=:committed_only,
    uncommitted_unit_fraction::Float64=DEFAULT_UNCOMMITTED_UNIT_FRACTION
)

    try
        if uc_solution.status != OPTIMAL
            return UCToBidsResult(
                SimpleOrder[], SimpleOrder[], Symbol(bidding_zone), day,
                0.0, 0.0, false, "Unit commitment optimization failed: $(uc_solution.status)"
            )
        end

        zone_symbol = Symbol(bidding_zone)
        supply_orders = SimpleOrder[]
        demand_orders = SimpleOrder[]

        # Extract solution data (no UC solving here!)
        generators = uc_solution.generators
        time_slots = uc_solution.time_slots
        generation = uc_solution.g  # Generation matrix [generator, time]
        commitment = uc_solution.u  # Commitment matrix [generator, time]
        net_demand = uc_solution.net_demand

        # Get resolution from loads data (convert PT60M to 60)
        loads = get_loads(bidding_zone, day)  # Get loads to extract resolution
        resolution_str = loads[1].resolution_code  # e.g., "PT60M"
        match_result = match(r"PT(\d+)M", resolution_str)  # Attempt to match the pattern
        if match_result === nothing
            error("Invalid resolution format: $(resolution_str). Expected format: 'PT<number>M'.")
        end
        resolution_minutes = parse(Int, match_result[1])  # Extract 60 from "PT60M"

        N = length(generators)
        T = length(time_slots)

        println("Applying bidding strategy to existing UC solution...")
        println("- $N generators, $T time periods")
        println("- Resolution: $(resolution_minutes) minutes")
        println("- Bidding strategy: $bidding_strategy")

        # Generate supply orders from generators (same logic as before)
        total_supply_quantity = 0.0
        for i in 1:N
            gen = generators[i]
            for t in 1:T

                # Determine if we should create an order based on strategy
                should_bid = false
                bid_quantity = 0.0

                if bidding_strategy == :committed_only
                    # Conservative: Only bid committed units with positive generation
                    if commitment[i, t] > COMMITMENT_THRESHOLD && generation[i, t] > GENERATION_THRESHOLD
                        should_bid = true
                        bid_quantity = generation[i, t]  # Bid actual optimized generation
                    end
                elseif bidding_strategy == :all_available_max
                    # Maximum capacity: Bid all units at their theoretical maximum
                    should_bid = true
                    bid_quantity = gen.p_max  # Always bid maximum capacity
                elseif bidding_strategy == :all_available_realistic
                    # UC-informed realistic: Bid all units with realistic quantities
                    should_bid = true

                    if commitment[i, t] > COMMITMENT_THRESHOLD && generation[i, t] > GENERATION_THRESHOLD
                        # Committed unit: bid actual UC generation (what UC selected)
                        bid_quantity = generation[i, t]
                    else
                        # Uncommitted unit: bid realistic available capacity
                        if gen.p_min > GENERATION_THRESHOLD
                            bid_quantity = gen.p_min  # Minimum stable generation
                        else
                            # For units with very low p_min, use a configurable fraction of max capacity
                            bid_quantity = gen.p_max * uncommitted_unit_fraction
                        end
                    end
                else
                    error("Unknown bidding strategy: $bidding_strategy. Valid options: :committed_only, :all_available_max, :all_available_realistic")
                end

                if should_bid
                    # Calculate bid price with markup
                    bid_price = gen.marginal_cost * markup_factor
                    time_slot = time_slots[t]  # Get the time slot for this period

                    # Parse time slot and create supply order with time and resolution information
                    local date_time
                    try
                        date_time = DateTime(time_slot, "yyyymmdd-HHMM")
                    catch e
                        error("Invalid time_slot format: '$(time_slot)'. Expected format: 'YYYYMMDD-HHMM'. Error: $(e)")
                    end

                    order = SimpleOrder(
                        :supply,
                        bid_price,
                        bid_quantity,
                        zone_symbol,
                        date_time,
                        resolution_minutes
                    )

                    push!(supply_orders, order)
                    total_supply_quantity += bid_quantity
                end
            end
        end

        # Generate demand orders from net demand
        total_demand_quantity = 0.0
        for t in 1:T
            if net_demand[t] > DEMAND_THRESHOLD  # Small threshold for numerical precision

                time_slot = time_slots[t]  # Get the time slot for this period

                # Parse time slot and create demand order with high price to ensure it's always served
                local date_time
                try
                    date_time = DateTime(time_slot, "yyyymmdd-HHMM")
                catch e
                    error("Invalid time_slot format: '$(time_slot)'. Expected format: 'YYYYMMDD-HHMM'. Error: $(e)")
                end

                order = SimpleOrder(
                    :demand,
                    demand_price,  # High price to ensure demand is met
                    net_demand[t],
                    zone_symbol,
                    date_time,
                    resolution_minutes
                )

                push!(demand_orders, order)
                total_demand_quantity += net_demand[t]
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
        error_msg = "Error in apply_bidding_strategy_to_uc: $(string(e))"
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
    println("="^50)

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
                order_id="SUPPLY_$i",
                type=string(order.type),
                price=order.price,
                quantity=order.quantity,
                zone=string(order.zone),
                date_time=string(order.date_time),
                resolution_code=order.resolution_code,
                day=string(result.day)
            ))
        end

        # Add demand orders
        for (i, order) in enumerate(result.demand_orders)
            push!(orders_data, (
                order_id="DEMAND_$i",
                type=string(order.type),
                price=order.price,
                quantity=order.quantity,
                zone=string(order.zone),
                date_time=string(order.date_time),
                resolution_code=order.resolution_code,
                day=string(result.day)
            ))
        end

        # Write to CSV (simple implementation)
        open(filepath, "w") do file
            # Header
            println(file, "order_id,type,price,quantity,zone,date_time,resolution_code,day")

            # Data rows
            for row in orders_data
                println(file, "$(row.order_id),$(row.type),$(row.price),$(row.quantity),$(row.zone),$(row.date_time),$(row.resolution_code),$(row.day)")
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
