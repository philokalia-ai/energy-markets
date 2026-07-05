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

`exclude_counterparties` drops borders to the listed zones — used in
multi-zone clearing, where flows to zones inside the clearing set are
endogenous (ATC-constrained MPCC variables) and only borders to zones
OUTSIDE the set should enter as observed fixed injections.
"""
function get_net_imports(bidding_zone::String, day::Date;
    exclude_counterparties::Vector{String}=String[])
    # Two normalizations, both required for a correct MW value:
    # 1. AVG per border within the hour — flow_mw is a power value, so a
    #    border published at PT15M has 4 rows/hour; summing rows directly
    #    would inflate that border 4x relative to a PT60M border.
    # 2. Dedup counterparty aliases — some borders are reported twice under
    #    two map codes for the same area (e.g. UA and UA_IPS); strip the
    #    _IPS suffix and keep one row per (hour, counterparty, direction),
    #    deterministically preferring the larger flow (ORDER BY avg_flow
    #    DESC breaks ties so results are reproducible run to run).
    # date_time_utc is timestamptz; the hour key converts it with
    # AT TIME ZONE 'UTC' and the day window converts the BOUNDS to UTC
    # instants (keeping the column bare so an index on it stays usable) —
    # both are correct regardless of the client session timezone.
    df = sql2df_with_retry(
        """
        WITH border_hourly AS (
            SELECT DISTINCT ON (h, counterparty, direction)
                   h, counterparty, direction, avg_flow
            FROM (
                SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
                       regexp_replace(
                           CASE WHEN in_area_map_code = \$1
                                THEN out_area_map_code ELSE in_area_map_code END,
                           '_IPS\$', '') AS counterparty,
                       CASE WHEN in_area_map_code = \$1 THEN 1 ELSE -1 END AS direction,
                       AVG(flow_mw) AS avg_flow
                FROM entsoe.physical_flows
                WHERE (in_area_map_code = \$1 OR out_area_map_code = \$1)
                  AND in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
                  AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
                  AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
                GROUP BY 1,
                         CASE WHEN in_area_map_code = \$1
                              THEN out_area_map_code ELSE in_area_map_code END,
                         CASE WHEN in_area_map_code = \$1 THEN 1 ELSE -1 END
            ) per_code
            ORDER BY h, counterparty, direction, avg_flow DESC
        )
        SELECT h, SUM(direction * avg_flow) AS net_import
        FROM border_hourly
        WHERE counterparty <> ALL(\$3)
        GROUP BY h
        """,
        [bidding_zone, day, exclude_counterparties]
    )
    return Dict{Int,Float64}(row.h => row.net_import for row in eachrow(df))
end

# Fuel types priced at water value instead of SRMC
const WATER_VALUE_FUEL_TYPES =
    [Symbol("Hydro Water Reservoir"), Symbol("Hydro Pumped Storage")]

# ENTSO-E production_type strings for hydro availability lookup
const HYDRO_PRODUCTION_TYPES =
    ["Hydro Water Reservoir", "Hydro Pumped Storage", "Hydro Run-of-river and poundage"]

"""
    get_hydro_availability(bidding_zone::String, day::Date; lookback_days=30) -> Union{Float64,Nothing}

Recent achievable hydro output as a fraction of what the fleet produced at
its best over the trailing window: the 95th-percentile hourly total hydro
output over the `lookback_days` before `day` (strictly before — no
lookahead). Hydro is energy-limited, so recent peak output is a physical
proxy for the water actually available — in dry periods (e.g. August 2024,
May 2025 in SEE) reservoirs cannot sustain nameplate output regardless of
price, which tightens the real capacity margin and drives scarcity pricing.

Returns MW (the p95 hourly output), or `nothing` when no data exists.
"""
function get_hydro_availability(bidding_zone::String, day::Date; lookback_days::Int=30)
    df = sql2df_with_retry(
        """
        SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY hydro_mw) AS p95
        FROM (
            SELECT date_time_utc, SUM(actual_generation_output_mw) AS hydro_mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1
              AND production_type = ANY(\$2)
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$4::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY date_time_utc
        ) hourly
        """,
        [bidding_zone, HYDRO_PRODUCTION_TYPES, day - Day(lookback_days), day]
    )
    (isempty(df) || ismissing(df.p95[1])) && return nothing
    return Float64(df.p95[1])
end

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
    peak_kappa::Float64=1.2,
    peak_exponent::Float64=4.0,
    water_value_base::Float64=0.85,
    water_value_dry_boost::Float64=1.0,
    water_value_span::Float64=0.9,
    demand_elastic_share::Float64=0.02,
    demand_elastic_price::Float64=250.0,
    price_cap::Float64=3000.0,
    include_net_imports::Bool=true,
    net_import_exclude::Vector{String}=String[]
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
        net_imports = include_net_imports ?
                      get_net_imports(bidding_zone, day; exclude_counterparties=net_import_exclude) :
                      Dict{Int,Float64}()
        slot_import(ts) = get(net_imports, Dates.hour(parse_timeslot_to_datetime(ts, day)), 0.0)

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

        # Hydro energy limitation: recent actual peak output caps what the
        # hydro fleet can offer (dry periods → less water → tighter margin).
        # Thermal keeps the flat availability derate; hydro gets a
        # data-driven one.
        is_hydro(g) = g.fuel_type in WATER_VALUE_FUEL_TYPES ||
                      g.fuel_type == Symbol("Hydro Run-of-river and poundage")
        hydro_pmax = sum((g.p_max for g in generators if is_hydro(g)); init=0.0)
        hydro_scale = 1.0   # offered-quantity cap (fraction of nameplate)
        hydro_dryness = 0.0 # 0 = normal water conditions, →1 = severe drought
        if hydro_pmax > 1.0
            hydro_avail = get_hydro_availability(bidding_zone, day)
            hydro_norm = get_hydro_availability(bidding_zone, day; lookback_days=365)
            if hydro_avail !== nothing
                hydro_scale = clamp(hydro_avail / hydro_pmax, 0.2, 1.0)
                # Dryness compares the recent achievable output to the
                # zone's own long-run level — hydro habitually runs below
                # nameplate, so nameplate is the wrong drought baseline
                if hydro_norm !== nothing && hydro_norm > 1.0
                    hydro_dryness = clamp(1.0 - hydro_avail / hydro_norm, 0.0, 1.0)
                end
                println("  💧 Hydro: recent p95 $(round(Int, hydro_avail)) MW, " *
                        "1y p95 $(round(Int, something(hydro_norm, NaN))) MW, " *
                        "nameplate $(round(Int, hydro_pmax)) MW → " *
                        "offer scale $(round(hydro_scale, digits=2)), dryness $(round(hydro_dryness, digits=2))")
            end
        end
        offered_pmax(g) = is_hydro(g) ? g.p_max * hydro_scale : g.p_max

        # Dispatchable capacity for the scarcity margin, derated for the
        # realistic availability of the fleet (unreported outages) and for
        # the hydro energy limit — nameplate capacity never looks scarce.
        dispatchable_capacity =
            availability_factor * sum((g.p_max for g in generators if !is_hydro(g)); init=0.0) +
            hydro_scale * hydro_pmax

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
        demand_orders_count = 0
        total_demand_quantity = 0.0
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
                demand_orders_count += 1
                total_demand_quantity += -ni
            end

            # Normalized within-day demand position (0 = trough, 1 = peak)
            norm_demand = (net_demand[ts] - nd_min) / nd_span

            # Markup on upper supply tranches: absolute scarcity (capacity
            # margin below threshold) plus peak-hour strategic bidding —
            # participants know when the daily peak is and price their last
            # tranches accordingly, even when capacity is formally adequate.
            # The high exponent concentrates the markup in the true peak
            # hours: at norm_demand 0.5 (e.g. summer nights, where residual
            # demand is mid-range) the markup is ~6% of peak_kappa, not 25%.
            margin = dispatchable_capacity / net_demand[ts]
            scarcity = 1.0 +
                       scarcity_kappa * max(0.0, scarcity_threshold - margin)^2 +
                       peak_kappa * norm_demand^peak_exponent

            for g in generators
                if g.fuel_type in WATER_VALUE_FUEL_TYPES
                    # Hydro opportunity cost: cheap relative to gas off-peak,
                    # premium over gas at the peak. Single tranche — hydro
                    # dispatches all-or-nothing at its water value.
                    # Dry-period boost: scarce water raises the opportunity
                    # cost of releasing it — the same MWh could be sold in a
                    # later, tighter hour. Dryness is the recent achievable
                    # output vs the zone's own long-run level.
                    water_value = gas_srmc * (1.0 + water_value_dry_boost * hydro_dryness) *
                                  (water_value_base + water_value_span * norm_demand)
                    push!(orders, SimpleOrder(:supply, water_value, offered_pmax(g),
                        Symbol(bidding_zone), date_time, resolution_minutes))
                    supply_orders_count += 1
                    total_supply_capacity += offered_pmax(g)
                else
                    # Must-run self-scheduling: baseload-ish units (SRMC not
                    # far above gas) bid their minimum-load block near zero —
                    # shutting down and restarting costs more than running a
                    # few hours below cost. This is what lets midday prices
                    # collapse below thermal SRMC in renewable-surplus hours.
                    must_run_qty = 0.0
                    if g.code in committed
                        must_run_qty = min(g.p_min, offered_pmax(g))
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
                    flexible_capacity = max(offered_pmax(g) - must_run_qty, 0.0)
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

        # Merge orders with identical (type, price, timeslot): all units of a
        # fuel type bid the same SRMC-derived tranche prices, so a zone-day
        # book collapses ~6x with market-equivalent clearing (partial
        # acceptance of a merged block ≡ distributing it among the
        # identically-priced originals). This directly cuts the MPCC binary
        # count, which is what limits multi-zone solve times.
        merged = Dict{Tuple{Symbol,Float64,DateTime},Float64}()
        for o in orders
            key = (o.type, round(o.price, digits=2), o.date_time)
            merged[key] = get(merged, key, 0.0) + o.quantity
        end
        pre_merge_count = length(orders)
        orders = [SimpleOrder(t, p, q, Symbol(bidding_zone), dt, resolution_minutes)
                  for ((t, p, dt), q) in merged]
        println("  🔗 Merged $(pre_merge_count) orders into $(length(orders)) price-distinct blocks")

        nodes = [bidding_zone]
        # EU day-ahead floor is -500; ceiling is the demand cap so shortage
        # hours can price exactly at the cap
        price_limits = (-500.0, price_cap)
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
        e isa InterruptException && rethrow()
        error_msg = "Error creating merit-order book: $(sprint(showerror, e))"
        println("  ❌ $error_msg")
        return AdjustedOrderBookResult(false, error_msg, nothing, 0, 0, 0, 0.0, 0.0, 0.0)
    end
end

end  # module MeritOrderBook
