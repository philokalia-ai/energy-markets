"""
    OrderBookResult

The shared result type for order-book construction plus the one timeslot helper
every builder needs. Formerly `AlternativeOrderBook`, which also held the
`:alternative` book builder — deleted in cv25's subtraction phase along with the
rest of the UC path. What remains is used by the merit-order book, so it is named
for what it is.
"""
module OrderBookResult

using Dates
import ..MPCC: MPCCOrderBook   # the result wraps one

"""
    parse_timeslot_to_datetime(timeslot::String, day::Date)

Parses a timeslot string (e.g., "20240618-0015") to DateTime.
"""
function parse_timeslot_to_datetime(timeslot::String, day::Date)
    # A malformed slot used to be silently mapped to 00:00 (stacking its orders
    # on midnight) — refuse instead (bug sweep 2026-08-25).
    length(timeslot) >= 13 ||
        throw(ArgumentError("timeslot \"$timeslot\" is not yyyymmdd-HHMM"))
    hour = parse(Int, timeslot[10:11])
    minute = parse(Int, timeslot[12:13])
    (0 <= hour <= 23 && 0 <= minute <= 59) ||
        throw(ArgumentError("timeslot \"$timeslot\" has an invalid time"))
    return DateTime(day) + Hour(hour) + Minute(minute)
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