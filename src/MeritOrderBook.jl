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
import ..get_marginal_cost, ..sql2df_with_retry, ..Generator, ..normalize_fuel_type_name
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
function get_net_imports(bidding_zone::String, day::Date;
    exclude_counterparties::Vector{String}=String[],
    import_only_counterparties::Vector{String}=String[])
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
        SELECT h, SUM(CASE WHEN counterparty = ANY(\$4)
                           THEN GREATEST(direction * avg_flow, 0)
                           ELSE direction * avg_flow END) AS net_import
        FROM border_hourly
        WHERE counterparty <> ALL(\$3)
        GROUP BY h
        """,
        [bidding_zone, day, exclude_counterparties, import_only_counterparties]
    )
    return Dict{Int,Float64}(row.h => row.net_import for row in eachrow(df))
end

"""
    get_dropped_border_exports(zone, day, counterparties) -> Dict{Int,Float64}

Per-UTC-hour EXPORT volume (MW, positive) over the borders to the listed
counterparties, from `entsoe.physical_flows` — the mirror of the import-only
clamp in `get_net_imports`. Used by the two-pass :hydro anchor to give
structural exporters (NO5) their outlet back as ref-priced demand while the
import supply stays separately clamped.
"""
function get_dropped_border_exports(bidding_zone::String, day::Date,
    counterparties::Vector{String})
    isempty(counterparties) && return Dict{Int,Float64}()
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
        SELECT h, SUM(GREATEST(-direction * avg_flow, 0)) AS export_mw
        FROM border_hourly
        WHERE counterparty = ANY(\$3)
        GROUP BY h
        """,
        [bidding_zone, day, counterparties]
    )
    return Dict{Int,Float64}(row.h => row.export_mw for row in eachrow(df))
end

"""
    get_firm_of(bidding_zone::String) -> Dict{String,String}

Map of `unit_code => firm` for a zone, from `simulations.unit_firms` (a small
read-only reference table, present on both backends). Returns an empty Dict
(and warns once) when the table is missing — the strategist hook then simply
has no firm information to key on.
"""
function get_firm_of(bidding_zone::String)
    try
        df = sql2df_with_retry(
            """
            SELECT unit_code, firm
            FROM simulations.unit_firms
            WHERE zone = \$1 AND unit_code IS NOT NULL AND firm IS NOT NULL
            """,
            [bidding_zone]
        )
        return Dict{String,String}(String(row.unit_code) => String(row.firm)
                                   for row in eachrow(df))
    catch e
        @warn "simulations.unit_firms unavailable; strategist firm_of will be empty" exception=e
        return Dict{String,String}()
    end
end

# Fuel types priced at water value instead of SRMC
const WATER_VALUE_FUEL_TYPES =
    [Symbol("Hydro Water Reservoir"), Symbol("Hydro Pumped Storage")]

# ENTSO-E production_type strings for hydro availability lookup
const HYDRO_PRODUCTION_TYPES =
    ["Hydro Water Reservoir", "Hydro Pumped Storage", "Hydro Run-of-river and pondage"]

# =============================================================================
# ZONE PROFILES — per-region bid-construction calibration
# =============================================================================
"""
    ZoneProfile

Bundles the per-zone bid-construction / hydro / fleet / scarcity parameters of
`create_merit_order_book` (previously ~18 loose kwargs) into one named value.
The clearing machinery is region-agnostic; different European regions are
governed by different price-forming forces, so each is calibrated with its own
profile selected via `ZONE_PROFILES`, which **defaults to `SEE_PROFILE`**.

`SEE_PROFILE` holds the exact v10 defaults, so the SEE core (GR/BG/RO/RS/HU) and
Iberia are byte-identical to the pre-abstraction code — the non-negotiable
regression guard (unit-tested: a GR book with `SEE_PROFILE` equals a GR book
built with no profile). Region profiles are authored as thin deltas over SEE.

Fields are data, not logic. Two levers extend the old kwargs:
- `thermal_srmc_multiplier` scales non-hydro marginal costs (Italy's LNG /
  older-fleet efficiency premium); `1.0` = unchanged.
- `hydro_model` selects the hydro offer model: `:gas_anchored` (SEE default —
  water value tied to gas SRMC and demand shape) or `:reservoir_opportunity`
  (Nordic — water value from reservoir filling level, decoupled from gas).
"""
Base.@kwdef struct ZoneProfile
    tranches::Vector{Tuple{Float64,Float64}} =
        [(0.55, 0.95), (0.20, 1.05), (0.15, 1.25), (0.10, 1.60)]
    must_run_price_factor::Float64 = 0.05
    must_run_srmc_threshold::Float64 = 1.15
    availability_factor::Float64 = 0.80
    scarcity_threshold::Float64 = 1.4
    scarcity_kappa::Float64 = 3.0
    peak_kappa::Float64 = 1.2
    peak_exponent::Float64 = 4.0
    water_value_base::Float64 = 0.85
    water_value_dry_boost::Float64 = 1.0
    water_value_span::Float64 = 0.9
    demand_elastic_share::Float64 = 0.02
    demand_elastic_price::Float64 = 250.0
    price_cap::Float64 = 3000.0
    fleet_completion::Bool = true
    fleet_truthing::Bool = true
    derate_headroom::Float64 = 1.15
    thermal_srmc_multiplier::Float64 = 1.0
    hydro_model::Symbol = :gas_anchored
    nuclear_srmc_floor::Float64 = 0.0
    opportunity_anchor::Symbol = :none
    anchor_share::Float64 = 0.9
end

"SEE / default profile — the exact v10 parameters (regression baseline)."
const SEE_PROFILE = ZoneProfile()

"Iberia — near-isolated, already the best-fit region; identical to SEE (verified)."
const IBERIA_PROFILE = SEE_PROFILE

"""
Continental core (DE/FR/BE/NL/AT/CH/PL/CZ/SK). High-RES thermal with heavy
transit; genuine scarcity should be rare, so the scarcity/peak markups are
softened relative to SEE. Adequacy is expected to come mostly from the Phase-1
network fix (endogenous flows + the CH transit hub), not bid tuning.
"""
const CONTINENTAL_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
)

"""
Italy. Gas-heavy but higher SRMC than SEE — older, less-efficient CCGTs burning
premium-priced LNG — so thermal marginal costs carry an efficiency/LNG premium.
"""
const ITALY_PROFILE = ZoneProfile(
    thermal_srmc_multiplier = 1.20,
)

"""
Nordic (NO*/SE*/FI/DK*). Hydro-dominated: the price is the opportunity cost of
stored water (reservoir level + export value), NOT a gas anchor. Uses the
`:reservoir_opportunity` hydro model and softens scarcity so full reservoirs no
longer slam into the price cap.
"""
const NORDIC_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    # Demand-shape band applied to the reservoir-opportunity water value
    # (see the :reservoir_opportunity branch): 0.6 at the trough → 1.1 at the
    # peak, so hydro is cheap off-peak but firms up into the evening.
    water_value_base = 0.6,
    water_value_span = 0.5,
)

"""
France. Nuclear-dominated exporter. Diagnostics (2026-04): the fleet picture is
CORRECT — nuclear unit fleet 50.9 GW vs trailing-30d p95 47.4 GW, within the
derate headroom, so fleet-truthing rightly stays silent — yet the hourly
residual shows a LEVEL gap concentrated off-peak: sim ≈ €10 (nuclear tranche-1
at SRMC) overnight vs actual €55–70, while midday RES-surplus hours match. The
observed French off-peak price reflects EDF's opportunity-cost *bidding* of the
modulating nuclear fleet, not the ~€10 fuel SRMC — a bidding-layer position,
which per the repo's cost-model convention belongs here, not in the SRMC table.
`nuclear_srmc_floor` lifts the nuclear bid base to that observed level; peaks
stay set by gas/hydro/scarcity as in CONTINENTAL.
"""
const FRANCE_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    nuclear_srmc_floor = 55.0,
    opportunity_anchor = :nuclear,
    # Measured: share 0.9 → bias +33 (cal5), share 0.7 → +21 (cal6), both
    # with the coupled shape right (corr 0.76 → 0.80–0.83) — the neighbor-
    # weighted ref imports the overpricing of CH/BE/ES, so the share must
    # discount it. Extrapolating the measured share→bias line puts |bias|≤10
    # at ≈0.55: EDF's off-peak position sits just above half the coupled
    # neighbor price.
    anchor_share = 0.55,
)

"""
Southern/mid Norway (NO1/NO2/NO3/NO5). Same reservoir-opportunity hydro model
as NORDIC, plus the `:hydro` opportunity anchor for two-pass clearing: these
zones are coupled to the continent (2026-04 actuals €70–108 tracking DE/NL)
and their stored water prices at the export opportunity — the pass-1 coupled
continental price — not at a fraction of gas SRMC (iteration-1 result: flat
−58…−92 residual with full reservoirs). NO4 (far north, actuals ≈ €18, NOT
continentally coupled — congestion isolates it like SE1/SE2) deliberately
stays on plain NORDIC_PROFILE.
"""
const NORWAY_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    opportunity_anchor = :hydro,
)

"""
Baltic (EE/LT/LV). Tightly coupled to the Nordic hydro system and thermally
thin; softened scarcity like the continental core. Left close to SEE otherwise —
their residual error is expected to shrink once the Nordic zones are corrected.
"""
const BALTIC_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
)

"""
    ZONE_PROFILES

Registry mapping bidding-zone code → `ZoneProfile`. Zones absent from the
registry fall back to `SEE_PROFILE` via `get_zone_profile`, so the default is
always the validated SEE calibration.
"""
const ZONE_PROFILES = Dict{String,ZoneProfile}(
    # SEE core (explicit for clarity; equal to the fallback)
    "GR" => SEE_PROFILE, "BG" => SEE_PROFILE, "RO" => SEE_PROFILE,
    "RS" => SEE_PROFILE, "HU" => SEE_PROFILE, "SI" => SEE_PROFILE,
    # Iberia
    "ES" => IBERIA_PROFILE, "PT" => IBERIA_PROFILE,
    # Italy sub-zones
    "IT-NORTH" => ITALY_PROFILE, "IT-CNORTH" => ITALY_PROFILE,
    "IT-CSOUTH" => ITALY_PROFILE, "IT-SOUTH" => ITALY_PROFILE,
    "IT-Calabria" => ITALY_PROFILE, "IT-Sicily" => ITALY_PROFILE,
    "IT-Sardinia" => ITALY_PROFILE,
    # Norway — southern/mid zones carry the :hydro opportunity anchor;
    # NO4 (far north, not continentally coupled) stays plain NORDIC
    "NO1" => NORWAY_PROFILE, "NO2" => NORWAY_PROFILE, "NO3" => NORWAY_PROFILE,
    "NO4" => NORDIC_PROFILE, "NO5" => NORWAY_PROFILE,
    "SE1" => NORDIC_PROFILE, "SE2" => NORDIC_PROFILE, "SE3" => NORDIC_PROFILE,
    "SE4" => NORDIC_PROFILE, "FI" => NORDIC_PROFILE,
    "DK1" => NORDIC_PROFILE, "DK2" => NORDIC_PROFILE,
    # Baltic
    "EE" => BALTIC_PROFILE, "LT" => BALTIC_PROFILE, "LV" => BALTIC_PROFILE,
    # France (nuclear-heavy: continental scarcity + nuclear bid position)
    "FR" => FRANCE_PROFILE,
    # Continental core
    "DE_LU" => CONTINENTAL_PROFILE,
    "BE" => CONTINENTAL_PROFILE, "NL" => CONTINENTAL_PROFILE,
    "AT" => CONTINENTAL_PROFILE, "CH" => CONTINENTAL_PROFILE,
    "PL" => CONTINENTAL_PROFILE, "CZ" => CONTINENTAL_PROFILE,
    "SK" => CONTINENTAL_PROFILE,
)

"""
    get_zone_profile(zone) -> ZoneProfile

Profile for a zone, defaulting to `SEE_PROFILE` for any zone not in the registry.
"""
get_zone_profile(zone::AbstractString) = get(ZONE_PROFILES, String(zone), SEE_PROFILE)

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
    get_type_output_p95(bidding_zone::String, day::Date; lookback_days=30) -> Dict{String,Float64}

95th-percentile hourly actual output per production type over the trailing
window (strictly before `day` — no lookahead), from
`entsoe.aggregated_generation_per_type`. Used for fleet completion: ENTSO-E's
unit-level table only lists larger units, so for some zones (RO, BG, RS) the
per-type aggregate output demonstrably exceeds the unit-level fleet capacity.
"""
function get_type_output_p95(bidding_zone::String, day::Date; lookback_days::Int=30)
    df = sql2df_with_retry(
        """
        SELECT production_type,
               percentile_cont(0.95) WITHIN GROUP (ORDER BY mw) AS p95
        FROM (
            SELECT production_type, date_time_utc, SUM(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY production_type, date_time_utc
        ) hourly
        GROUP BY production_type
        """,
        [bidding_zone, day - Day(lookback_days), day]
    )
    return Dict{String,Float64}(row.production_type => Float64(row.p95)
                                for row in eachrow(df) if !ismissing(row.p95))
end

"""
    get_reservoir_dryness(bidding_zone::String, day::Date) -> Union{Float64,Nothing}

Hydrological dryness from ENTSO-E weekly reservoir filling levels
(`entsoe.aggregated_hydro_storage_filling_rate`): the latest stored energy
strictly before `day`'s ISO week, compared to the median stored energy for
the same weeks (±2) of previous years. Returns `clamp(1 - current/norm, 0, 1)`
— 0 in normal/wet conditions, approaching 1 in severe drought — or `nothing`
when either value is unavailable.

Unlike output-based dryness, this measures the water itself, so it is not
confounded by dispatch incentives (hydro running hard *because* prices are
high looks "wet" in output terms while reservoirs are actually draining).
"""
function get_reservoir_dryness(bidding_zone::String, day::Date)
    iso_week = Int(Dates.week(day))
    iso_year = year(day)

    current = sql2df_with_retry(
        """
        SELECT stored_energy_mwh
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
          AND (year < \$2 OR (year = \$2 AND week < \$3))
        ORDER BY year DESC, week DESC
        LIMIT 1
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(current) || ismissing(current.stored_energy_mwh[1])) && return nothing

    norm = sql2df_with_retry(
        """
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY stored_energy_mwh) AS med
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
          AND year < \$2
          AND week BETWEEN \$3 - 2 AND \$3 + 2
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(norm) || ismissing(norm.med[1]) || Float64(norm.med[1]) <= 0.0) && return nothing

    return clamp(1.0 - Float64(current.stored_energy_mwh[1]) / Float64(norm.med[1]), 0.0, 1.0)
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
- `fleet_completion`: add aggregate capacity where the type's recent output
  (p95) exceeds the unit-level fleet (under-reported fleets: RO/BG/RS)
- `fleet_truthing` / `derate_headroom`: derate baseload types whose
  unit-level fleet exceeds `derate_headroom ×` recent p95 — phantom
  capacity from unfiled derates or fuel constraints (2022 GR lignite)

# Scenario hooks (all default `nothing`; when all are `nothing` the code path
# is byte-identical to the no-kwargs call)
- `load_modifier::Union{Nothing,Function}`: `f(timeslot::String, load_mw::Float64) -> Float64`,
  applied to every entry of `load_by_time` at the source (after temporal
  disaggregation and any hourly aggregation), so the change propagates to net
  demand, scarcity margin, water value and demand orders.
- `renewable_modifier::Union{Nothing,Function}`: same signature, applied to
  `renewable_by_time` at the same point (e.g. `(ts, v) -> v + 300` during
  daylight slots models +300 MW of solar).
- `extra_orders::Union{Nothing,Function}`: `f(ctx) -> Vector{SimpleOrder}`,
  called after all standard orders are built and BEFORE merging. `ctx` is a
  NamedTuple `(zone, day, timeslots, resolution_minutes, load_by_time,
  renewable_by_time)`. Returned orders (`:supply` or `:demand`) are appended
  (tagged `"EXTRA"`). Models "ships request more power" (cap-priced demand) or
  "a new plant" (supply).
- `strategist::Union{Nothing,Function}`: `f(ctx) -> Vector{Tuple{SimpleOrder,String}}`
  (a plain `Vector{SimpleOrder}` is also accepted and re-tagged `"STRATEGIST"`),
  called after `extra_orders` and before merging. `ctx` is a NamedTuple
  `(tagged_orders, zone, day, timeslots, load_by_time, renewable_by_time,
  firm_of)` where `firm_of` is a `Dict{String,String}` unit_code→firm from
  `simulations.unit_firms`. The returned set REPLACES the tagged order list.

  Example — "what if the incumbent PPC marked up its peakers' top tranches 20%?":
  ```julia
  strat = ctx -> [ (firm_of_ppc(ctx, o, tag) ? bump(o) : o, tag)
                   for (o, tag) in ctx.tagged_orders ]
  ```
  A strategist that finds all orders whose `firm_of[tag] == "PPC"` and
  multiplies their two top tranche prices by 1.2, returning everything else
  unchanged.

Only the single-zone (`:merit_order`) path threads these hooks; multi-zone
clearing does not (v1 limitation).
"""
function create_merit_order_book(
    bidding_zone::String,
    day::Date;
    profile::ZoneProfile=SEE_PROFILE,
    tranches::Union{Nothing,Vector{Tuple{Float64,Float64}}}=nothing,
    must_run_price_factor::Union{Nothing,Float64}=nothing,
    must_run_srmc_threshold::Union{Nothing,Float64}=nothing,
    availability_factor::Union{Nothing,Float64}=nothing,
    scarcity_threshold::Union{Nothing,Float64}=nothing,
    scarcity_kappa::Union{Nothing,Float64}=nothing,
    peak_kappa::Union{Nothing,Float64}=nothing,
    peak_exponent::Union{Nothing,Float64}=nothing,
    water_value_base::Union{Nothing,Float64}=nothing,
    water_value_dry_boost::Union{Nothing,Float64}=nothing,
    water_value_span::Union{Nothing,Float64}=nothing,
    demand_elastic_share::Union{Nothing,Float64}=nothing,
    demand_elastic_price::Union{Nothing,Float64}=nothing,
    price_cap::Union{Nothing,Float64}=nothing,
    include_net_imports::Bool=true,
    net_import_exclude::Vector{String}=String[],
    net_import_import_only::Vector{String}=String[],
    target_resolution_minutes::Union{Int,Nothing}=nothing,
    fleet_completion::Union{Nothing,Bool}=nothing,
    fleet_truthing::Union{Nothing,Bool}=nothing,
    derate_headroom::Union{Nothing,Float64}=nothing,
    thermal_srmc_multiplier::Union{Nothing,Float64}=nothing,
    hydro_model::Union{Nothing,Symbol}=nothing,
    nuclear_srmc_floor::Union{Nothing,Float64}=nothing,
    opportunity_anchor::Union{Nothing,Symbol}=nothing,
    anchor_share::Union{Nothing,Float64}=nothing,
    anchor_prices::Union{Nothing,Dict{String,Float64}}=nothing,
    anchor_export_mw::Dict{Int,Float64}=Dict{Int,Float64}(),
    res_coalesce_missing::Bool=false,
    load_modifier::Union{Nothing,Function}=nothing,
    renewable_modifier::Union{Nothing,Function}=nothing,
    extra_orders::Union{Nothing,Function}=nothing,
    strategist::Union{Nothing,Function}=nothing
)
    # Resolve every bid parameter from the profile, letting an explicit keyword
    # override its profile field. With no overrides and the default SEE_PROFILE
    # this reproduces the pre-abstraction defaults exactly (byte-identical).
    tranches = tranches === nothing ? profile.tranches : tranches
    must_run_price_factor = must_run_price_factor === nothing ? profile.must_run_price_factor : must_run_price_factor
    must_run_srmc_threshold = must_run_srmc_threshold === nothing ? profile.must_run_srmc_threshold : must_run_srmc_threshold
    availability_factor = availability_factor === nothing ? profile.availability_factor : availability_factor
    scarcity_threshold = scarcity_threshold === nothing ? profile.scarcity_threshold : scarcity_threshold
    scarcity_kappa = scarcity_kappa === nothing ? profile.scarcity_kappa : scarcity_kappa
    peak_kappa = peak_kappa === nothing ? profile.peak_kappa : peak_kappa
    peak_exponent = peak_exponent === nothing ? profile.peak_exponent : peak_exponent
    water_value_base = water_value_base === nothing ? profile.water_value_base : water_value_base
    water_value_dry_boost = water_value_dry_boost === nothing ? profile.water_value_dry_boost : water_value_dry_boost
    water_value_span = water_value_span === nothing ? profile.water_value_span : water_value_span
    demand_elastic_share = demand_elastic_share === nothing ? profile.demand_elastic_share : demand_elastic_share
    demand_elastic_price = demand_elastic_price === nothing ? profile.demand_elastic_price : demand_elastic_price
    price_cap = price_cap === nothing ? profile.price_cap : price_cap
    fleet_completion = fleet_completion === nothing ? profile.fleet_completion : fleet_completion
    fleet_truthing = fleet_truthing === nothing ? profile.fleet_truthing : fleet_truthing
    derate_headroom = derate_headroom === nothing ? profile.derate_headroom : derate_headroom
    thermal_srmc_multiplier = thermal_srmc_multiplier === nothing ? profile.thermal_srmc_multiplier : thermal_srmc_multiplier
    hydro_model = hydro_model === nothing ? profile.hydro_model : hydro_model
    nuclear_srmc_floor = nuclear_srmc_floor === nothing ? profile.nuclear_srmc_floor : nuclear_srmc_floor
    opportunity_anchor = opportunity_anchor === nothing ? profile.opportunity_anchor : opportunity_anchor
    anchor_share = anchor_share === nothing ? profile.anchor_share : anchor_share
    # The opportunity anchor is active only when BOTH the profile opts in AND
    # pass-1 reference prices were supplied (two-pass clearing, pass 2). With
    # either missing the whole mechanism is dead code — pass 1 and every
    # single-pass path (incl. SEE) are unchanged.
    anchor_active = opportunity_anchor != :none && anchor_prices !== nothing

    try
        println("📊 Creating merit-order order book for $bidding_zone on $day")

        generators = get_generators(bidding_zone, day)

        # Fleet completion: ENTSO-E's unit-level table only lists larger
        # units, so for some zones (RO, BG, RS) the fleet is structurally
        # undersized and the book clears at spurious shortage-cap prices.
        # When the zone's recent per-type actual output (p95, trailing 30
        # days — strictly historical) exceeds the unit-level capacity of
        # that type, the missing capacity demonstrably exists and produces:
        # add it as one aggregate generator per fuel type. Wind/solar are
        # excluded (netted via the RES forecast). Harmless for zones with
        # good unit coverage — the gap is ~0 there (verified on GR).
        # Shared by fleet completion (upward) and fleet-truthing derate
        # (downward); keys normalized once to canonical fuel names
        type_p95_raw = (fleet_completion || fleet_truthing) ?
                       get_type_output_p95(bidding_zone, day) : Dict{String,Float64}()
        type_p95 = Dict{String,Float64}(
            normalize_fuel_type_name(k) => v for (k, v) in type_p95_raw)
        if fleet_completion
            for (ptype, p95) in type_p95
                ptype in ("Wind Onshore", "Wind Offshore", "Solar") && continue
                fleet = sum((g.p_max for g in generators
                             if g.fuel_type == Symbol(ptype)); init=0.0)
                gap = p95 - fleet
                gap > 100.0 || continue
                push!(generators, Generator(
                    "AGG-$(bidding_zone)-$(replace(ptype, " " => "_"))",
                    "Aggregate small units: $ptype",
                    Symbol(ptype),
                    bidding_zone,
                    gap,
                    0.0,
                    bidding_zone,
                    get_marginal_cost(day, ptype, bidding_zone)))
                println("  ➕ Fleet completion: +$(round(Int, gap)) MW $ptype " *
                        "(recent p95 $(round(Int, p95)) MW vs $(round(Int, fleet)) MW unit-level)")
            end
        end

        # Fleet-truthing derate — the symmetric case of fleet completion.
        # When the unit-level fleet (after outage filtering) far exceeds
        # what the type has recently delivered, the excess is phantom
        # capacity: unfiled long-term derates, fuel-supply constraints, or
        # stale unit records. 2022 GR lignite is the canonical case — the
        # book offered ~2.2 GW at lignite SRMC while the real fleet's p95
        # was ~1.2 GW, so cheap phantom lignite displaced gas from the
        # margin and the whole crisis year cleared ~140 €/MWh low. Thermal
        # types only: hydro availability is handled by the water-value
        # offer scale, and RES never enters the thermal stack. The signal
        # (trailing 30-day p95, strictly historical) is ex-ante; 15%
        # headroom above p95 leaves room for genuinely tight days to call
        # on more of the fleet than it recently ran.
        #
        # Baseload/fuel-constrained types ONLY. For a fuel whose SRMC sits
        # below the market price, running under its capacity means it
        # genuinely could not run (mining limits, fuel supply, unfiled
        # derates) — it would have been dispatched otherwise. Mid-merit
        # and peaking fuels (gas, oil) run below capacity simply because
        # of their merit-order position; their capacity IS available at
        # its SRMC, and derating them manufactures phantom scarcity.
        derate_types = ("Fossil Brown coal/Lignite", "Fossil Hard coal",
                        "Fossil Oil shale", "Fossil Coal-derived gas",
                        "Fossil Peat", "Nuclear")
        # One scale per fuel type, applied in a single pass. Iterates the
        # FLEET's types (not type_p95's keys): a derate-listed type with a
        # p95 of zero is a fully offline fleet and derates all the way
        # down, while a type entirely absent from the aggregate table is
        # ambiguous (never-reporting type vs ETL gap) and is skipped
        # loudly rather than silently zeroed. Thermal orders offer raw
        # p_max (availability_factor only shapes the scarcity margin), so
        # the target compares against the raw fleet sum. p_min scales
        # proportionally with p_max — clamping instead would balloon the
        # must-run fraction of every derated unit.
        derate_scale = Dict{Symbol,Float64}()
        if fleet_truthing
            for ptype in derate_types
                fsym = Symbol(ptype)
                fleet_raw = sum((g.p_max for g in generators if g.fuel_type == fsym); init=0.0)
                fleet_raw > 0 || continue
                if !haskey(type_p95, ptype)
                    println("  ⚠️  Fleet-truthing: no recent output data for $ptype " *
                            "($(round(Int, fleet_raw)) MW fleet) — derate skipped")
                    continue
                end
                target = derate_headroom * type_p95[ptype]
                fleet_raw > target + 100.0 || continue
                derate_scale[fsym] = target / fleet_raw
                println("  ➖ Fleet-truthing derate: $ptype ×$(round(target / fleet_raw, digits=2)) " *
                        "(fleet $(round(Int, fleet_raw)) MW vs recent p95 $(round(Int, type_p95[ptype])) MW)")
            end
        end
        # Thermal SRMC premium (ITALY_PROFILE): scale the marginal cost of
        # thermal fuels only — hydro/storage price at water value, not fuel
        # cost, and RES never enters the thermal stack. gas_srmc (the hydro
        # anchor) is computed separately and is unaffected. Default multiplier
        # 1.0 leaves every cost untouched (byte-identical for SEE).
        srmc_exempt_fuels = Set{Symbol}(vcat(WATER_VALUE_FUEL_TYPES,
            [Symbol("Hydro Run-of-river and pondage"), Symbol("Energy storage")]))
        apply_srmc_premium = thermal_srmc_multiplier != 1.0
        # Nuclear bid-position floor (FRANCE_PROFILE): raise the nuclear bid
        # base to at least this level — nuclear-dominated exporters price their
        # modulating fleet at opportunity cost, not fuel SRMC. Default 0.0 is a
        # no-op (byte-identical for SEE).
        # When the :nuclear anchor is ACTIVE the static floor is replaced by the
        # per-slot anchor floor in the order loop (a static floor would hold the
        # price up in exactly the RES-surplus hours where the coupled price —
        # and EDF's opportunity cost — collapses: 2026-04 weekends, FR actual
        # €9 vs the €55 floor).
        apply_nuclear_floor = nuclear_srmc_floor > 0.0 &&
                              !(anchor_active && opportunity_anchor == :nuclear)
        if !isempty(derate_scale) || apply_srmc_premium || apply_nuclear_floor
            generators = [begin
                s = get(derate_scale, g.fuel_type, 1.0)
                m = (apply_srmc_premium && !(g.fuel_type in srmc_exempt_fuels)) ?
                    thermal_srmc_multiplier : 1.0
                mc = g.marginal_cost * m
                if apply_nuclear_floor && g.fuel_type == Symbol("Nuclear")
                    mc = max(mc, nuclear_srmc_floor)
                end
                (s < 1.0 || mc != g.marginal_cost) ?
                    Generator(g.code, g.name, g.fuel_type, g.location,
                              g.p_max * s, g.p_min * s,
                              g.bidding_zone, mc,
                              g.ramp_up, g.ramp_down, g.min_uptime, g.min_downtime) :
                    g
            end for g in generators]
        end
        loads = get_loads(bidding_zone, day)
        renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day;
            coalesce_missing=res_coalesce_missing)

        if isempty(generators)
            return AdjustedOrderBookResult(false, "No generators found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        if isempty(loads)
            return AdjustedOrderBookResult(false, "No load data found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end

        target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
            disaggregate_temporal_data(loads, renewables)

        # Resolution harmonization for multi-zone books: zones publish at
        # different resolutions (e.g. RO/HU 15-min, GR/BG hourly) and a
        # combined book with mixed timeslots isolates the hourly zones in
        # sub-hour slots. Aggregate MW values to the coarser target by
        # averaging sub-slots (MW is power — averaging preserves energy).
        if target_resolution_minutes !== nothing && resolution_minutes < target_resolution_minutes
            target_resolution_minutes == 60 ||
                error("Only hourly (60) target resolution is supported, got $target_resolution_minutes")
            hour_key(ts) = ts[1:11] * "00"
            function aggregate_to_hours(d::Dict{String,Float64})
                sums = Dict{String,Tuple{Float64,Int}}()
                for (ts, v) in d
                    k = hour_key(ts)
                    s, n = get(sums, k, (0.0, 0))
                    sums[k] = (s + v, n + 1)
                end
                return Dict{String,Float64}(k => s / n for (k, (s, n)) in sums)
            end
            load_by_time = aggregate_to_hours(load_by_time)
            renewable_by_time = aggregate_to_hours(renewable_by_time)
            target_timeslots = sort(collect(keys(load_by_time)))
            println("  🕐 Aggregated $(resolution_minutes)-min data to hourly ($(length(target_timeslots)) slots)")
            resolution_minutes = target_resolution_minutes
        end

        # Scenario demand/supply modifiers, applied at the SOURCE dictionaries
        # (after disaggregation and any hourly aggregation) so the change
        # propagates to net demand, scarcity margin, water value and demand
        # orders. No-op when the hooks are nothing.
        if load_modifier !== nothing
            for ts in keys(load_by_time)
                load_by_time[ts] = load_modifier(ts, load_by_time[ts])
            end
        end
        if renewable_modifier !== nothing
            for ts in keys(renewable_by_time)
                renewable_by_time[ts] = renewable_modifier(ts, renewable_by_time[ts])
            end
        end

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
                      get_net_imports(bidding_zone, day;
                          exclude_counterparties=net_import_exclude,
                          import_only_counterparties=net_import_import_only) :
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
                      g.fuel_type == Symbol("Hydro Run-of-river and pondage")
        hydro_pmax = sum((g.p_max for g in generators if is_hydro(g)); init=0.0)
        hydro_scale = 1.0   # offered-quantity cap (fraction of nameplate)
        hydro_dryness = 0.0 # 0 = normal water conditions, →1 = severe drought
        if hydro_pmax > 1.0
            hydro_avail = get_hydro_availability(bidding_zone, day)
            hydro_norm = get_hydro_availability(bidding_zone, day; lookback_days=365)
            if hydro_avail !== nothing
                hydro_scale = clamp(hydro_avail / hydro_pmax, 0.2, 1.0)
            end
            # Dryness: prefer reservoir filling levels vs seasonal norm
            # (measures the water itself); fall back to recent-vs-1y output
            # when filling data is unavailable for the zone. Output-based
            # dryness is confounded by dispatch incentive: hydro running
            # hard because prices are high looks "wet" while reservoirs
            # are actually draining.
            reservoir_dryness = get_reservoir_dryness(bidding_zone, day)
            if reservoir_dryness !== nothing
                hydro_dryness = reservoir_dryness
            elseif hydro_avail !== nothing && hydro_norm !== nothing && hydro_norm > 1.0
                hydro_dryness = clamp(1.0 - hydro_avail / hydro_norm, 0.0, 1.0)
            end
            # Reservoir-opportunity zones (Nordic) govern offered hydro QUANTITY
            # by reservoir level, not by recent output. The p95-output cap above
            # is a gas-world energy-limited heuristic; in a hydro-dominated,
            # capacity-rich system it spuriously starves the book (e.g. NO1's
            # standalone supply/demand ratio ≈ 0.95 → phantom shortage at the
            # cap) even when reservoirs are full. Tie the offered fraction to
            # reservoir fullness instead: full → near-nameplate, severe drought
            # → half (inflow-only). Scarcity here is priced through the water
            # value, not rationed through quantity.
            if hydro_model == :reservoir_opportunity
                hydro_scale = clamp(1.0 - hydro_dryness, 0.5, 1.0)
            end
            println("  💧 Hydro: offer scale $(round(hydro_scale, digits=2)), " *
                    "dryness $(round(hydro_dryness, digits=2))" *
                    (reservoir_dryness !== nothing ? " (reservoir levels)" : " (output-based fallback)") *
                    (hydro_model == :reservoir_opportunity ? " [reservoir-opportunity]" : ""))
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

        # Every order is tagged with an owner (Feature 5, strategist hook):
        # the generator code for unit orders, "RES" for the renewable
        # forecast, "IMPORT" for net-import injections, "DEMAND" for demand
        # orders, "EXTRA" for extra_orders, "STRATEGIST" for strategist
        # replacements. Tags never affect the SimpleOrder values, so with no
        # hooks the merged book is byte-identical to before.
        tagged = Tuple{SimpleOrder,String}[]
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
                push!(tagged, (SimpleOrder(:supply, 1.0, res_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "RES"))
                supply_orders_count += 1
                total_supply_capacity += res_qty
            end

            # Net imports as price-taking supply (imports) or firm extra
            # demand (exports) — scheduled flows are committed either way
            ni = slot_import(ts)
            if ni > 0.1
                # :hydro-anchored zones (pass 2): observed imports arrive at
                # the BORDER price, not free — pricing them near zero lets the
                # import block set near-zero clearing prices in every
                # import-covered hour (NO1's flat undershoot: sim ≈ €3 at
                # night vs actual ≈ €88 tracking its neighbors). Priced at the
                # anchor level the import-marginal hours clear at the coupled
                # reference, as they do in reality. Everywhere else imports
                # stay price-taking at €1 (unchanged).
                import_price = (anchor_active && opportunity_anchor == :hydro &&
                                haskey(anchor_prices, ts)) ?
                               clamp(anchor_share * anchor_prices[ts], 1.0, gas_srmc) : 1.0
                push!(tagged, (SimpleOrder(:supply, import_price, ni,
                    Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                supply_orders_count += 1
                total_supply_capacity += ni
            elseif ni < -0.1
                push!(tagged, (SimpleOrder(:demand, price_cap, -ni,
                    Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                demand_orders_count += 1
                total_demand_quantity += -ni
            end

            # :hydro-anchored zones (pass 2): the export volume observed over
            # the DROPPED flow-based borders re-enters as demand priced at the
            # coupled reference — NOT the cap. NO5 is the measured case: a
            # structural exporter whose import-only clamp removed the export
            # outlet entirely, collapsing its surplus onto a tiny local load
            # (sim €36 vs actual €104). Ref-priced demand clears only when the
            # zone's price is at/below the coupled price, so it cannot
            # manufacture cap scarcity; and it is SEPARATE from the clamped
            # import supply, so it cannot net away import energy either
            # (measured failure mode of netting: NO1 −23 → +134).
            if anchor_active && opportunity_anchor == :hydro &&
               haskey(anchor_prices, ts) && !isempty(anchor_export_mw)
                ex_mw = get(anchor_export_mw, Dates.hour(date_time), 0.0)
                if ex_mw > 0.1
                    push!(tagged, (SimpleOrder(:demand, max(anchor_prices[ts], 1.0),
                        ex_mw, Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                    demand_orders_count += 1
                    total_demand_quantity += ex_mw
                end
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
                    # Hydro water value. Two models:
                    #
                    # :gas_anchored (SEE default) — opportunity cost tied to gas
                    # SRMC: cheap relative to gas off-peak, premium over gas at
                    # the peak, boosted in dry periods. Correct where hydro
                    # competes against a gas-set margin.
                    #
                    # :reservoir_opportunity (Nordic) — in a hydro-dominated
                    # zone the price is the shadow value of stored water, NOT a
                    # gas anchor: near-free when reservoirs are full, rising
                    # toward the continental thermal alternative (gas SRMC as a
                    # proxy for the export-market price) as they empty. This
                    # stops full Nordic reservoirs from slamming into scarcity/
                    # cap prices.
                    # :hydro opportunity anchor (two-pass, pass 2): stored
                    # water prices at the export opportunity — the pass-1
                    # coupled reference price (level AND hourly shape) — times
                    # a share slightly below 1 when reservoirs are full
                    # (willing to undercut the continent to export), rising
                    # with dryness. Clamped to [2, gas SRMC].
                    water_value = if anchor_active && opportunity_anchor == :hydro &&
                                     haskey(anchor_prices, ts)
                        clamp(anchor_prices[ts] *
                              (anchor_share + water_value_dry_boost * hydro_dryness),
                              2.0, gas_srmc)
                    elseif hydro_model == :reservoir_opportunity
                        # Stored water is worth a FRACTION of the continental
                        # thermal price (gas SRMC proxy): an export-opportunity
                        # floor (~0.35×) when reservoirs are full, rising to the
                        # full thermal alternative (1.0×) as they empty. Then
                        # shaped by within-day demand. NOT gas-anchored at parity
                        # — full Nordic reservoirs price well below gas, which is
                        # what stops the scarcity/cap blow-up.
                        wv_frac = 0.35 + 0.65 * hydro_dryness
                        gas_srmc * wv_frac * (water_value_base + water_value_span * norm_demand)
                    else
                        gas_srmc * (1.0 + water_value_dry_boost * hydro_dryness) *
                        (water_value_base + water_value_span * norm_demand)
                    end
                    push!(tagged, (SimpleOrder(:supply, water_value, offered_pmax(g),
                        Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                    supply_orders_count += 1
                    total_supply_capacity += offered_pmax(g)
                else
                    # :nuclear opportunity anchor (two-pass, pass 2): nuclear's
                    # effective bid base per slot is the export opportunity —
                    # anchor_share × the pass-1 coupled reference price —
                    # floored at fuel SRMC. It rises with the coupled price on
                    # weekday nights and COLLAPSES with it in RES-surplus hours
                    # (weekends/midday), which a static floor cannot do.
                    # Everywhere else gmc ≡ g.marginal_cost.
                    gmc = (anchor_active && opportunity_anchor == :nuclear &&
                           g.fuel_type == Symbol("Nuclear") &&
                           haskey(anchor_prices, ts)) ?
                          max(g.marginal_cost, anchor_share * anchor_prices[ts]) :
                          g.marginal_cost
                    # Must-run self-scheduling: baseload-ish units (SRMC not
                    # far above gas) bid their minimum-load block near zero —
                    # shutting down and restarting costs more than running a
                    # few hours below cost. This is what lets midday prices
                    # collapse below thermal SRMC in renewable-surplus hours.
                    must_run_qty = 0.0
                    if g.code in committed
                        must_run_qty = min(g.p_min, offered_pmax(g))
                        # Graduated self-scheduling: the deepest block is
                        # near-free (never shut down), the rest bids below
                        # cost — real curves are convex, not a cliff. The
                        # below-cost discount is ABSOLUTE (startup-cost
                        # amortization is €/MWh over the p_min hours, not a
                        # fraction of fuel cost): a proportional 0.5×SRMC
                        # discount is benign at gas ≈ 90 (−45) but capped
                        # crisis evenings at half the real gas cost
                        # (−212 at TTF 218, 2022) and sank the whole year.
                        deep_qty = must_run_qty * 0.6
                        push!(tagged, (SimpleOrder(:supply,
                            gmc * must_run_price_factor, deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        push!(tagged, (SimpleOrder(:supply,
                            max(gmc * 0.5, gmc - 40.0),
                            must_run_qty - deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        supply_orders_count += 2
                        total_supply_capacity += must_run_qty
                    end

                    # Remaining capacity: tranche ladder on SRMC, scarcity
                    # markup on the upper tranches (first tranche stays at
                    # cost so mid-merit keeps clearing)
                    flexible_capacity = max(offered_pmax(g) - must_run_qty, 0.0)
                    for (i, (share, mult)) in enumerate(tranches)
                        price = gmc * mult * (i == 1 ? 1.0 : scarcity)
                        qty = flexible_capacity * share
                        qty < 0.1 && continue
                        push!(tagged, (SimpleOrder(:supply, price, qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
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
            push!(tagged, (SimpleOrder(:demand, price_cap, inelastic_qty,
                Symbol(bidding_zone), date_time, resolution_minutes), "DEMAND"))
            demand_orders_count += 1

            elastic_qty = gd * demand_elastic_share
            if elastic_qty > 0.1
                push!(tagged, (SimpleOrder(:demand, demand_elastic_price, elastic_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "DEMAND"))
                demand_orders_count += 1
            end
            total_demand_quantity += gd
        end

        # Feature 3/4: extra scenario orders appended after all standard
        # orders and BEFORE merging. Both :supply and :demand are allowed.
        if extra_orders !== nothing
            ctx = (zone=bidding_zone, day=day, timeslots=target_timeslots,
                   resolution_minutes=resolution_minutes,
                   load_by_time=load_by_time, renewable_by_time=renewable_by_time)
            for o in extra_orders(ctx)
                push!(tagged, (o, "EXTRA"))
                if o.type == :supply
                    supply_orders_count += 1
                    total_supply_capacity += o.quantity
                else
                    demand_orders_count += 1
                    total_demand_quantity += o.quantity
                end
            end
        end

        # Feature 5: strategist hook, called after extra_orders and before
        # merging. It receives the full tagged order list plus a unit→firm
        # map and RETURNS the replacement tagged list.
        if strategist !== nothing
            firm_of = get_firm_of(bidding_zone)
            sctx = (tagged_orders=tagged, zone=bidding_zone, day=day,
                    timeslots=target_timeslots, load_by_time=load_by_time,
                    renewable_by_time=renewable_by_time, firm_of=firm_of)
            result = strategist(sctx)
            # Accept either Vector{Tuple{SimpleOrder,String}} or a plain
            # Vector{SimpleOrder} (re-tagged "STRATEGIST").
            tagged = Tuple{SimpleOrder,String}[
                x isa Tuple ? (x[1], x[2]) : (x, "STRATEGIST") for x in result]
            # Recount from the replacement set so summary stats stay accurate
            supply_orders_count = count(t -> t[1].type == :supply, tagged)
            demand_orders_count = count(t -> t[1].type == :demand, tagged)
            total_supply_capacity = sum((t[1].quantity for t in tagged if t[1].type == :supply); init=0.0)
            total_demand_quantity = sum((t[1].quantity for t in tagged if t[1].type == :demand); init=0.0)
        end

        orders = SimpleOrder[t[1] for t in tagged]

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
