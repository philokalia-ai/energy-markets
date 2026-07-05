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
import ..get_generators, ..get_loads, ..get_generation_forecast_for_wind_and_solar
import ..get_marginal_cost, ..sql2df_with_retry
import ..MarketOrders: SimpleOrder
import ..MPCC: MPCCOrderBook
import ..disaggregate_temporal_data
import ..AlternativeOrderBook: AdjustedOrderBookResult, parse_timeslot_to_datetime

"""
    get_net_imports(bidding_zone::String, day::Date) -> Dict{Int,Float64}

Net physical imports (MW, positive = importing) per UTC hour for a zone,
from `entsoe.physical_flows`. Both flow directions are summed across all
borders; rows are restricted to BZN-level areas on both sides to avoid the
double-reporting of the same border at CTA level (e.g. GR–IT vs GR–IT-SOUTH).

Returns an empty Dict when no flow data exists for the day.
"""
function get_net_imports(bidding_zone::String, day::Date)
    df = sql2df_with_retry(
        """
        SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
               SUM(CASE WHEN in_area_map_code = \$1 THEN flow_mw ELSE -flow_mw END) AS net_import
        FROM entsoe.physical_flows
        WHERE (in_area_map_code = \$1 OR out_area_map_code = \$1)
          AND in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
          AND date_time_utc >= \$2::date AND date_time_utc < \$2::date + 1
        GROUP BY 1
        """,
        [bidding_zone, day]
    )
    return Dict{Int,Float64}(row.h => row.net_import for row in eachrow(df))
end

# Fuel types priced at water value instead of SRMC
const WATER_VALUE_FUEL_TYPES =
    [Symbol("Hydro Water Reservoir"), Symbol("Hydro Pumped Storage")]

"""
    create_merit_order_book(bidding_zone::String, day::Date; kwargs...)

Create a deterministic merit-order-based order book for MPCC clearing.

# Keyword arguments (bidding strategy parameters)
- `tranches`: supply tranches as (capacity share, price multiplier on SRMC)
- `scarcity_threshold`: capacity margin below which scarcity markup kicks in
- `scarcity_kappa`: quadratic scarcity markup coefficient
- `water_value_base` / `water_value_span`: hydro opportunity cost as a
  multiple of gas SRMC, scaled across the day's demand range
- `demand_elastic_share` / `demand_elastic_price`: size and price of the
  price-sensitive demand tail
- `price_cap`: price of the inelastic demand tranche
"""
function create_merit_order_book(
    bidding_zone::String,
    day::Date;
    tranches::Vector{Tuple{Float64,Float64}}=[(0.55, 0.95), (0.20, 1.05), (0.15, 1.25), (0.10, 1.60)],
    must_run_price_factor::Float64=0.05,
    must_run_srmc_threshold::Float64=1.15,
    availability_factor::Float64=0.80,
    scarcity_threshold::Float64=1.4,
    scarcity_kappa::Float64=3.0,
    peak_kappa::Float64=0.6,
    water_value_base::Float64=0.85,
    water_value_span::Float64=0.9,
    demand_elastic_share::Float64=0.02,
    demand_elastic_price::Float64=250.0,
    price_cap::Float64=3000.0,
    include_net_imports::Bool=true
)
    try
        println("📊 Creating merit-order order book for $bidding_zone on $day")

        generators = get_generators(bidding_zone, day)
        loads = get_loads(bidding_zone, day)
        renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day)

        if isempty(generators)
            return AdjustedOrderBookResult(false, "No generators found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        if isempty(loads)
            return AdjustedOrderBookResult(false, "No load data found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end

        target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
            disaggregate_temporal_data(loads, renewables)

        # Residual demand per slot (load minus renewables) drives water value
        # and scarcity. Renewables themselves are offered as near-zero-price
        # supply below, NOT netted from demand — this lets prices collapse
        # toward zero in renewable-surplus hours, as they do in reality.
        # Net physical imports as fixed injections: observed cross-border
        # schedules (positive = import). A single zone cleared in isolation
        # systematically overprices import hours and underprices export
        # hours; using the observed schedule is the standard single-zone
        # backtesting treatment. Set include_net_imports=false for a pure
        # isolated-zone simulation (or when forecasting without flow data).
        net_imports = include_net_imports ? get_net_imports(bidding_zone, day) : Dict{Int,Float64}()
        slot_import(ts) = get(net_imports, parse(Int, ts[10:11]), 0.0)

        gross_demand = Dict{String,Float64}()
        net_demand = Dict{String,Float64}()
        for ts in target_timeslots
            load_value = get(load_by_time, ts, 0.0)
            renewable_gen = get(renewable_by_time, ts, 0.0)
            gross_demand[ts] = max(10.0, load_value)
            # Residual demand on domestic thermal: load - RES - net imports
            net_demand[ts] = max(10.0, load_value - renewable_gen - slot_import(ts))
        end
        nd_values = [net_demand[ts] for ts in target_timeslots]
        nd_min, nd_max = minimum(nd_values), maximum(nd_values)
        nd_span = max(nd_max - nd_min, 1.0)

        # Gas SRMC anchors hydro water value (TTF-based when data exists)
        gas_srmc = get_marginal_cost(day, "Fossil Gas", bidding_zone)

        # Dispatchable capacity for the scarcity margin, derated for the
        # realistic availability of the fleet (unreported outages, energy
        # limits on hydro) — nameplate capacity never looks scarce.
        dispatchable_capacity = availability_factor * sum(g.p_max for g in generators)

        # UC-lite commitment: only units that are actually running
        # self-schedule their minimum load. Approximate the committed set as
        # the cheapest eligible thermal units whose derated capacity covers
        # the day's peak residual demand (commitment follows the peak; the
        # p_min of that set is then must-run through the trough).
        committed = Set{String}()
        peak_residual = nd_max
        eligible = sort(
            [g for g in generators
             if !(g.fuel_type in WATER_VALUE_FUEL_TYPES) &&
                g.marginal_cost <= must_run_srmc_threshold * gas_srmc &&
                g.p_min > 0.1],
            by=g -> g.marginal_cost)
        cum_capacity = 0.0
        for g in eligible
            cum_capacity >= 1.05 * peak_residual && break
            push!(committed, g.code)
            cum_capacity += availability_factor * g.p_max
        end

        orders = SimpleOrder[]
        supply_orders_count = 0
        total_supply_capacity = 0.0

        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)

            # Renewable forecast offered at near-zero price (RES bids as
            # price-taker; support schemes make it insensitive to price)
            res_qty = get(renewable_by_time, ts, 0.0)
            if res_qty > 0.1
                push!(orders, SimpleOrder(:supply, 1.0, res_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes))
                supply_orders_count += 1
                total_supply_capacity += res_qty
            end

            # Net imports as price-taking supply (imports) or firm extra
            # demand (exports) — scheduled flows are committed either way
            ni = slot_import(ts)
            if ni > 0.1
                push!(orders, SimpleOrder(:supply, 1.0, ni,
                    Symbol(bidding_zone), date_time, resolution_minutes))
                supply_orders_count += 1
                total_supply_capacity += ni
            elseif ni < -0.1
                push!(orders, SimpleOrder(:demand, price_cap, -ni,
                    Symbol(bidding_zone), date_time, resolution_minutes))
            end

            # Normalized within-day demand position (0 = trough, 1 = peak)
            norm_demand = (net_demand[ts] - nd_min) / nd_span

            # Markup on upper supply tranches: absolute scarcity (capacity
            # margin below threshold) plus peak-hour strategic bidding —
            # participants know when the daily peak is and price their last
            # tranches accordingly, even when capacity is formally adequate.
            margin = dispatchable_capacity / net_demand[ts]
            scarcity = 1.0 +
                       scarcity_kappa * max(0.0, scarcity_threshold - margin)^2 +
                       peak_kappa * norm_demand^2

            for g in generators
                if g.fuel_type in WATER_VALUE_FUEL_TYPES
                    # Hydro opportunity cost: cheap relative to gas off-peak,
                    # premium over gas at the peak. Single tranche — hydro
                    # dispatches all-or-nothing at its water value.
                    water_value = gas_srmc * (water_value_base + water_value_span * norm_demand)
                    push!(orders, SimpleOrder(:supply, water_value, g.p_max,
                        Symbol(bidding_zone), date_time, resolution_minutes))
                    supply_orders_count += 1
                    total_supply_capacity += g.p_max
                else
                    # Must-run self-scheduling: baseload-ish units (SRMC not
                    # far above gas) bid their minimum-load block near zero —
                    # shutting down and restarting costs more than running a
                    # few hours below cost. This is what lets midday prices
                    # collapse below thermal SRMC in renewable-surplus hours.
                    must_run_qty = 0.0
                    if g.code in committed
                        must_run_qty = min(g.p_min, g.p_max)
                        # Graduated self-scheduling: the deepest block is
                        # near-free (never shut down), the rest bids half
                        # cost — real curves are convex, not a cliff
                        deep_qty = must_run_qty * 0.6
                        push!(orders, SimpleOrder(:supply,
                            g.marginal_cost * must_run_price_factor, deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes))
                        push!(orders, SimpleOrder(:supply,
                            g.marginal_cost * 0.5, must_run_qty - deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes))
                        supply_orders_count += 2
                        total_supply_capacity += must_run_qty
                    end

                    # Remaining capacity: tranche ladder on SRMC, scarcity
                    # markup on the upper tranches (first tranche stays at
                    # cost so mid-merit keeps clearing)
                    flexible_capacity = max(g.p_max - must_run_qty, 0.0)
                    for (i, (share, mult)) in enumerate(tranches)
                        price = g.marginal_cost * mult * (i == 1 ? 1.0 : scarcity)
                        qty = flexible_capacity * share
                        qty < 0.1 && continue
                        push!(orders, SimpleOrder(:supply, price, qty,
                            Symbol(bidding_zone), date_time, resolution_minutes))
                        supply_orders_count += 1
                        total_supply_capacity += qty
                    end
                end
            end
        end

        # Demand: inelastic tranche at the cap + small price-sensitive tail
        demand_orders_count = 0
        total_demand_quantity = 0.0
        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)
            gd = gross_demand[ts]

            inelastic_qty = gd * (1.0 - demand_elastic_share)
            push!(orders, SimpleOrder(:demand, price_cap, inelastic_qty,
                Symbol(bidding_zone), date_time, resolution_minutes))
            demand_orders_count += 1

            elastic_qty = gd * demand_elastic_share
            if elastic_qty > 0.1
                push!(orders, SimpleOrder(:demand, demand_elastic_price, elastic_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes))
                demand_orders_count += 1
            end
            total_demand_quantity += gd
        end

        nodes = [bidding_zone]
        price_limits = (-1000.0, 4000.0)
        order_book = MPCCOrderBook(orders, nodes, target_timeslots, price_limits, nothing)

        supply_per_slot = total_supply_capacity / length(target_timeslots)
        demand_per_slot = total_demand_quantity / length(target_timeslots)
        ratio = demand_per_slot > 0 ? supply_per_slot / demand_per_slot : 0.0

        println("  ✅ Merit-order book: $supply_orders_count supply / $demand_orders_count demand orders")
        println("     ⚖️  Supply/Demand ratio: $(round(ratio, digits=2))  (gas SRMC €$(round(gas_srmc, digits=1))/MWh)")

        return AdjustedOrderBookResult(
            true, "Merit-order book created successfully", order_book,
            length(generators), demand_orders_count, supply_orders_count,
            total_demand_quantity, total_supply_capacity, ratio)

    catch e
        error_msg = "Error creating merit-order book: $e"
        println("  ❌ $error_msg")
        return AdjustedOrderBookResult(false, error_msg, nothing, 0, 0, 0, 0.0, 0.0, 0.0)
    end
end

end  # module MeritOrderBook
