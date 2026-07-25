module MeritOrderBook

"""
Merit-Order Bidding Order Book

Deterministic order book that models how participants actually bid in
day-ahead markets, instead of adding random noise to costs:

- **Demand** is (nearly) inelastic: a large tranche at the price cap plus a
  small price-sensitive tail. The clearing price therefore comes from the
  supply stack, not from an arbitrary demand price.
- **Thermal supply** bids in tranches (bid laddering): most capacity near
  SRMC, the last MW at a premium. This produces an upward-sloping offer
  curve per unit, as in real order books.
- **Scarcity markup**: when the capacity margin over demand tightens, upper
  tranches are marked up — capturing strategic bidding in tight hours.
- **Hydro water value**: reservoir and pumped-storage hydro bid opportunity
  cost tied to the gas SRMC and the day's demand shape, not their (trivial)
  variable cost. This is what sets evening-peak prices in hydro-rich zones
  like GR.

All prices derive from SRMC (`get_marginal_cost`, TTF-based for gas), so the
order book moves with real fuel prices.
"""

using Dates
using Statistics: median, quantile
import ..get_generators, ..get_loads, ..get_generation_forecast_for_wind_and_solar, ..Load, ..RenewablesGenerationForecast
import ..get_marginal_cost, ..sql2df_with_retry, ..Generator, ..normalize_fuel_type_name
import ..get_ttf_price, ..eua_price
import ..GAS_PLANT_EFFICIENCY, ..GAS_EMISSION_FACTOR, ..GAS_VOM_COST
import ..MarketOrders: SimpleOrder
import ..MPCC: MPCCOrderBook
import ..disaggregate_temporal_data, ..replicate_to_finer_resolution
import ..AlternativeOrderBook: AdjustedOrderBookResult, parse_timeslot_to_datetime

"""
    get_net_imports(bidding_zone::String, day::Date) -> Dict{Int,Float64}

Net physical imports (MW, positive = importing) per UTC hour for a zone,
from `entsoe.physical_flows`. Both flow directions are summed across all
borders; rows are restricted to BZN-level areas on both sides to avoid the
double-reporting of the same border at CTA level (e.g. GR–IT vs GR–IT-SOUTH).

Returns an empty Dict when no flow data exists for the day.

`exclude_counterparties` drops borders to the listed zones — used in
multi-zone clearing, where flows to zones inside the clearing set are
endogenous (ATC-constrained MPCC variables) and only borders to zones
OUTSIDE the set should enter as observed fixed injections.

`import_only_counterparties` keeps only the IMPORT direction of the listed
borders (per hour, `GREATEST(flow, 0)`), used for Nordic flow-based borders
that were dropped from the endogenous network: the observed import supplies
a starving importer (NO1), but the corresponding observed export must NOT
become firm cap-priced demand in the exporter's book — against the thin
Nordic unit fleets that manufactures scarcity that cascades down the
endogenous SE chain (measured: SE3 bias −6.5 → +578 when its NO1/FI exports
entered as firm demand). Empty by default — the single-zone and 5-zone SEE
paths are unchanged.
"""

# Split by concern; each file is `include`d in the original definition order,
# so the module body is line-for-line the pre-split code.
include("merit_order/flows_imports.jl") # physical-flow cache, net imports, ex-ante flows, import ATC/backstop, firm map
include("merit_order/zone_profiles.jl") # ZoneProfile struct, per-zone profiles, ZONE_PROFILES, ZoneScenario
include("merit_order/fleet_data.jl")    # hydro availability, per-type p95, installed capacity, reservoir dryness/drawdown
include("merit_order/boundary.jl")      # cv21 virtual boundary-counterparty book (DK1/Viking GB): anchor SRMC, capability, orders
# Optional order-book sink — set by the book-export feature; nothing = the
# exact pre-existing behaviour (guarded byte-identical).
const BOOK_SINK = Ref{Union{Nothing,Function}}(nothing)

include("merit_order/book_build.jl")    # create_merit_order_book — the merit-order book construction itself


end  # module MeritOrderBook
