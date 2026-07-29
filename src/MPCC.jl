module MPCC

using JuMP, Dates, DataFrames
using JuMP: AffExpr
using Distributed: myid, workers, pmap, WorkerPool

# Import shared solver selection from parent module
import ..select_solver

# Import required modules from parent Euphemia package
import ..Euphemia.MarketOrders: MarketOrder, SimpleOrder, AggregatedPeriodicOrder
import ..Euphemia.Network: NetworkTopology, TransferCapacity, get_connected_zones, get_zone_pairs, create_transfer_capacity_from_entsoe
import ..Euphemia: get_loads, get_generators, get_generation_forecast_for_wind_and_solar

# Result structure
struct MPCCResult
    status::Symbol
    objective_value::Float64
    market_prices::Dict{String,Dict{String,Float64}}
    stepwise_acceptance::Dict{String,Float64}
    block_acceptance::Dict{String,Float64}
    block_activation::Dict{String,Float64}
    transmission_flows::Dict{String,Dict{String,Float64}}
    solve_time::Float64              # Time spent in optimization solver
    total_time::Float64              # Total processing time (including order book creation)
    solver_name::String
    message::String
end

"""
    with_total_time(result::MPCCResult, total_time::Float64) -> MPCCResult

Create a copy of MPCCResult with updated total_time.
Useful for setting the total processing time after order book creation.
"""
function with_total_time(result::MPCCResult, total_time::Float64)
    return MPCCResult(
        result.status,
        result.objective_value,
        result.market_prices,
        result.stepwise_acceptance,
        result.block_acceptance,
        result.block_activation,
        result.transmission_flows,
        result.solve_time,
        total_time,
        result.solver_name,
        result.message
    )
end

# Typed order book structure using existing MarketOrder types
struct MPCCOrderBook
    orders::Vector{MarketOrder}                # All market orders using existing types
    nodes::Vector{String}                      # Bidding zone identifiers
    periods::Vector{String}                    # Time period identifiers (e.g., "1", "2", ..., "24")
    price_limits::Tuple{Float64,Float64}       # (min_price, max_price) bounds
    network_topology::Union{Nothing,NetworkTopology,TransferCapacity}  # Optional network constraints (TransferCapacity for multi-zone)
end

# Configuration constants
const DEFAULT_MARKUP_FACTOR = 1.1
const BIG_M_PARAMETER = 4000000.0

"""
    extract_time_period(order_datetime::DateTime, order_book_periods::Vector{String})

Extracts the appropriate time period identifier for an order based on the order book's period structure.
Supports both hourly (1-24) and sub-hourly (timeslot strings) periods.
"""
function extract_time_period(order_datetime::DateTime, order_book_periods::Vector{String})
    # Check if periods are timeslot strings (sub-hourly) or simple numbers (hourly)
    if !isempty(order_book_periods)
        sample_period = order_book_periods[1]

        # If periods look like timeslot strings (e.g., "20180624-0015")
        if length(sample_period) > 5 && contains(sample_period, "-")
            # Format DateTime to match timeslot format: "YYYYMMDD-HHMM"
            date_str = Dates.format(order_datetime, "yyyymmdd")
            time_str = Dates.format(order_datetime, "HHMM")
            timeslot = "$(date_str)-$(time_str)"

            # Return the timeslot if it exists in periods, otherwise find closest match
            if timeslot in order_book_periods
                return timeslot
            else
                # Fallback: find the period with matching hour
                hour = Dates.hour(order_datetime)
                minute = Dates.minute(order_datetime)
                target_time = hour * 100 + minute

                for period in order_book_periods
                    if length(period) >= 13
                        period_hour = parse(Int, period[10:11])
                        period_min = parse(Int, period[12:13])
                        period_time = period_hour * 100 + period_min

                        if period_time >= target_time
                            return period
                        end
                    end
                end

                # Ultimate fallback: return first period of the day
                return order_book_periods[1]
            end
        else
            # Periods are simple hour numbers (1-24) - use original logic
            hour_of_day = Dates.hour(order_datetime) + 1  # Convert 0-23 to 1-24
            return string(hour_of_day)
        end
    else
        # Fallback for empty periods
        hour_of_day = Dates.hour(order_datetime) + 1
        return string(hour_of_day)
    end
end



# Split by concern; each file is `include`d in the original definition order,
# so the module body is line-for-line the pre-split code.
include("mpcc/solver.jl")           # solve_mpcc_market_clearing + the per-period decomposition variant
include("mpcc/coupling_metrics.jl") # iterative-coupling helpers: flows -> net imports, convergence, damping


end  # module MPCC