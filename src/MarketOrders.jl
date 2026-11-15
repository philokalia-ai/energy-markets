module MarketOrders

using Dates

abstract type MarketOrder end  # Abstract base type for all orders

# Simple Order (with time dimension for electricity markets)
struct SimpleOrder <: MarketOrder
    type::Symbol # :supply or :demand for some reason called sense in EUPHEMIA's public description
    price::Float64
    quantity::Float64
    zone::Symbol
    date_time::DateTime  # ENTSO-E style delivery date and time
    resolution_code::Int  # Resolution in minutes (60, 30, 15)
end

"""
    LinkedHourlyOrder

An hourly order that belongs to a FAMILY sharing one daily energy budget:
Σ_t accepted MWh over the family's members ≤ `family_budget_mwh`. This is the
divisible form of an exclusive group of profile blocks (the instrument
energy-limited plants — pumped storage — use on EPEX/Nord Pool): the convex hull
of every generation profile that fits the budget. The family's members carry the
same `family` id and budget.

The MPCC never clears these directly: `solve_mpcc_market_clearing` first runs a
full-day master LP (`src/mpcc/complex_orders.jl`) that allocates each family's
energy across the periods, then turns every member into a plain `SimpleOrder`
capped at its allocation (fix-and-reprice). Only built when
`EUPHEMIA_COMPLEX_ORDERS` asks for it — otherwise no book ever contains one.
"""
struct LinkedHourlyOrder <: MarketOrder
    type::Symbol           # :supply (families are generation-side)
    price::Float64
    quantity::Float64      # MW offered in this period
    zone::Symbol
    date_time::DateTime
    resolution_code::Int   # minutes
    family::String         # e.g. "ESTOR:DE_LU"
    family_budget_mwh::Float64
end

# Aggregated Periodic Orders
struct AggregatedPeriodicOrder <: MarketOrder
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    period::Int  # Time period for the order
end

# Complex Orders
struct MICOrder <: MarketOrder  # Minimum Income Condition Order
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    min_income::Float64  # Minimum required revenue for acceptance
end

struct LoadGradientOrder <: MarketOrder  # Load Gradient Order
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    gradient_limit::Float64  # Max increase/decrease per period
end

# Block Orders
struct BlockOrder <: MarketOrder
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    min_revenue::Float64  # Must be met for acceptance
end

struct LinkedBlockOrder <: MarketOrder
    blocks::Vector{BlockOrder}  # Set of linked blocks
    relation::Symbol  # e.g., :sequential, :all_or_nothing
end

struct ExclusiveBlockOrder <: MarketOrder
    blocks::Vector{BlockOrder}  # Set of mutually exclusive blocks
end

struct FlexibleOrder <: MarketOrder
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    flexible_period::Int  # Period in which it can be executed
end

# Merit Orders
struct MeritOrder <: MarketOrder
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    ranking::Int  # Priority ranking
end

# PUN (Prezzo Unico Nazionale) Orders
struct PUNOrder <: MarketOrder
    type::Symbol # :supply or :demand 
    price::Float64
    quantity::Float64
    zone::Symbol
    reference_zone::Symbol  # Reference price zone for PUN calculation
end

end  # module Orders
