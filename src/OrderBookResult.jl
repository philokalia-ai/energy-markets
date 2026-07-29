"""
    OrderBookResult

The shared result type for order-book construction plus the one timeslot helper
every builder needs. Formerly `AlternativeOrderBook`, which also held the
`:alternative` book builder — deleted in cv25's subtraction phase along with the
rest of the UC path. What remains is used by the merit-order book, so it is named
for what it is.
"""
module OrderBookResult

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


end  # module OrderBookResult