# multi_zone_books.jl — Multi-zone order-book construction: network enrichment (ATC union, aggregate remap, flow-based drops), opportunity-anchor refs, and the exposed mz_* pipeline stages.
# Included by ../Euphemia.jl inside `module Euphemia` (definition order preserved).

# =============================================================================
# MULTI-ZONE MARKET CLEARING WITH TRANSMISSION FLOWS
# =============================================================================

"""
    _create_multi_zone_order_book_alternative(zones::Vector{String}, day::Date; random_seed=nothing)

Internal helper to create a multi-zone order book using the alternative (faster) order generation method.
Uses `create_adjusted_order_book` for each zone and combines the results.
"""
function _create_multi_zone_order_book_alternative(zones::Vector{String}, day::Date; random_seed::Union{Int,Nothing}=nothing)
    if isempty(zones)
        error("At least one bidding zone must be specified")
    end

    println("🌍 Creating multi-zone order book (alternative method) for $(length(zones)) zones")

    # Aggregate orders from all zones
    all_orders = Vector{MarketOrders.MarketOrder}()
    all_periods = Set{String}()
    failed_zones = String[]

    for zone in zones
        try
            println("   📊 Processing zone $zone...")

            # Generate orders using alternative order book method
            result = create_adjusted_order_book(zone, day; random_seed=random_seed)

            if !result.success
                @warn "Failed to generate orders for zone $zone: $(result.message)"
                push!(failed_zones, zone)
                continue
            end

            # Extract orders from the result's order book
            append!(all_orders, result.order_book.orders)

            # Collect time periods
            for period in result.order_book.periods
                push!(all_periods, period)
            end

            println("      ✅ Added $(result.supply_orders) supply + $(result.demand_orders) demand orders")

        catch e
            @error "Error processing zone $zone: $e"
            push!(failed_zones, zone)
        end
    end

    # Determine successful zones
    successful_zones = filter(z -> !(z in failed_zones), zones)

    if isempty(successful_zones)
        error("Failed to generate orders for any zone")
    end

    if !isempty(failed_zones)
        @warn "Some zones failed: $(join(failed_zones, ", ")). Proceeding with: $(join(successful_zones, ", "))"
    end

    # Convert periods to sorted vector
    periods_vector = sort(collect(all_periods))

    if isempty(periods_vector)
        periods_vector = [string(h) for h in 1:24]
        @warn "No periods found in orders, defaulting to 24 hourly periods"
    end

    println("   📊 Detected $(length(periods_vector)) time periods")

    # Fetch transfer capacity from ENTSO-E for connections between these zones
    println("   🔌 Fetching transfer capacities between zones...")
    transfer_capacity = Network.create_transfer_capacity_from_entsoe(day, successful_zones)

    # Log connectivity info
    zone_pairs = Network.get_zone_pairs(transfer_capacity)
    println("   ✅ Found $(length(zone_pairs)) directional transfer capacity links")

    # Create the multi-zone order book
    order_book = MPCC.MPCCOrderBook(
        all_orders,
        successful_zones,
        periods_vector,
        (0.0, 500.0),           # Price limits (€/MWh)
        transfer_capacity       # Attach transfer capacity for multi-zone clearing
    )

    println("✅ Created multi-zone order book (alternative):")
    println("   🌍 Zones: $(length(successful_zones))")
    println("   📝 Total orders: $(length(all_orders))")
    println("   🕐 Time periods: $(length(periods_vector))")
    println("   🔌 Transfer links: $(length(zone_pairs))")

    return order_book
end

"""
    shadowed_aggregate_codes(footprint) -> Vector{String}

When a country is represented in the clearing footprint by its bidding-zone
sub-nodes (Italy: `IT-*`; Denmark: `DK1`/`DK2`), the ENTSO-E *aggregate* alias
for the same physical area (`IT`, `DK`) — and, for the German bidding zone
`DE_LU`, the four TSO control-area aliases — must never re-enter a footprint
zone's observed net imports. If they did, that country's cross-border energy
would be double-counted: once endogenously through the sub-node's power balance
and cross-border flow variables, and once again as a fixed observed injection
over the same physical interconnector filed under the aggregate code.

Returns the set of aggregate/alias map codes to exclude from observed net
imports for *every* footprint zone, given which sub-nodes are present. Codes
that are themselves footprint nodes are never returned.

Empirically these aliases are published at CTA/CTY area-type level and are
therefore already dropped by `get_net_imports`' `BZN`-both-sides filter, so this
is a defensive belt-and-suspenders layer: it is a no-op for the current data and
for any footprint without split-country sub-zones (e.g. the 5-zone SEE set,
which yields an empty result and is thus byte-identical to the prior behaviour).
"""
function shadowed_aggregate_codes(footprint::AbstractVector{<:AbstractString})
    fp = Set(String.(footprint))
    shadows = Set{String}()
    # Italy: any IT sub-zone present → the aggregate "IT" is a shadow alias
    any(z -> startswith(z, "IT-"), fp) && push!(shadows, "IT")
    # Denmark: DK1/DK2 present → the aggregate "DK" is a shadow alias
    (("DK1" in fp) || ("DK2" in fp)) && push!(shadows, "DK")
    # Germany: DE_LU bidding zone present → its TSO control-area aliases are shadows
    if "DE_LU" in fp
        for c in ("DE_50HzT", "DE_Amprion", "DE_TenneT_GER", "DE_TransnetBW")
            push!(shadows, c)
        end
    end
    # Never shadow a code that is itself a real footprint node
    return sort(collect(setdiff(shadows, fp)))
end

# Aggregate country codes whose *external* borders are filed only under the
# aggregate (not the bidding-zone sub-nodes), mapped to the sub-node that
# physically carries those continental borders. Confirmed case: Italy — the
# aggregate `IT` holds IT–FR/AT/SI/CH, all on the northern border, so they
# remap onto `IT-NORTH`. (Germany's DE_LU and Denmark's DK1/DK2 file their own
# BZN borders directly and need no remap — audited.)
const AGGREGATE_BORDER_REPRESENTATIVE = Dict{String,String}("IT" => "IT-NORTH")

# Nordic flow-based border handling. The Nordic CCR moved to flow-based DA
# capacity calculation in Oct 2024, so the implicit table's "offered ATC" rows
# for Nordic-internal borders are stale residuals. Where a zone's IMPORT
# capability lives in those residuals, endogenizing the border starves it into
# phantom scarcity at the cap (audited 2026-04: NO1 — fleet 2.4 GW vs 3.3–3.9
# GW load, published import ATC ~1.25 GW incl. SE3→NO1 = 0 MW, vs real imports
# ~2.3 GW; FI — SE1→FI published as 4 MW vs real imports ~2.3 GW). Dropping
# those borders makes the book keep observed net imports for them — the same
# honest treatment as other borders the ATC data cannot reproduce (RS, HU–RO).
#
# Deliberately NOT dropped: SE- and DK-internal borders. Their published rows
# are residuals too (SE2→SE3 = 8 MW vs ~7.3 GW physical), but the constrained
# EXPORT direction they impose fortuitously reproduces the real north–south
# congestion that keeps SE1/SE2 structurally cheap; replacing them with
# observed flows turns ~5 GW of exports into firm cap-priced demand against a
# thin unit fleet and manufactures scarcity (measured: SE1/SE2 bias +7/+9 with
# the borders endogenous vs +735/+710 with observed exports). A proper
# flow-based domain model is the eventual fix; until then this asymmetric
# treatment is the least-wrong ex-ante choice.
const NORDIC_FB_ZONES = ["NO1", "NO2", "NO3", "NO4", "NO5",
                         "SE1", "SE2", "SE3", "SE4", "FI", "DK1", "DK2"]
const NORDIC_NO_ZONES = ["NO1", "NO2", "NO3", "NO4", "NO5"]

"""
    flow_based_drop_borders(footprint) -> Vector{Tuple{String,String}}

Undirected border pairs whose stale flow-based ATC residuals must be dropped
from the enriched network (falling back to observed net imports, import-only):

- **Nordic**: every Nordic-internal border touching a Norwegian zone, plus
  Finland's import borders from Sweden.
- **Hungary (Core FBMC)**: HU–AT and HU–SK. The `offered_transfer_capacities_implicit`
  values for HU are flow-based residual leftovers, not the real domain: measured
  2026-04-01..05, HU's import ATCs collapse to 37–112 MW at the evening peak (vs
  455–994 mid-morning) while the real Core domain carries GWs — the model starved
  HU exactly at the peak residual hours. Same treatment as the Nordic flow-based
  borders. HU–RO already moved to flow-based coupling (kept as observed imports),
  and HU–HR is not in the footprint, so those flows were already retained.
  HU–SI is deliberately KEPT endogenous: dropping it too (iter-4 cal11) fixed HU
  identically but regressed SI's shape (corr 0.79→0.58) by stripping SI's HU
  export outlet, while AT/SK-only (cal12) fixed HU (bias +70→+0.5, MAE 75→30)
  and left SI within tolerance (corr 0.79→0.75).

- **Belgium (Core FBMC)**: BE–FR, BE–NL, BE–DE_LU — import ATCs collapse to
  0–350 MW mid-morning while physical flows carry 1.4–1.9 GW (see inline
  comment); BE's +46 residual peaks exactly in the collapse hours.
- **Sweden-internal (SE2–SE3, SE3–SE4)**: the published implicit ATC into SE3
  collapses to ~118 MW average while the physical Norrland transfer carries
  ~5 GW (see inline comment) — the same flow-based-residual signature, starving
  SE3/SE4 into continental scarcity pricing. SE1–SE2 stays endogenous.

Only pairs with both endpoints in the footprint are returned; empty for
footprints without Nordic, Hungarian, or Swedish zones (e.g. the 5-zone SEE set).
"""
function flow_based_drop_borders(footprint::AbstractVector{<:AbstractString})
    fp = Set(String.(footprint))
    pairs = Set{Tuple{String,String}}()
    ordered(a, b) = a < b ? (a, b) : (b, a)
    for no in NORDIC_NO_ZONES
        no in fp || continue
        for z in NORDIC_FB_ZONES
            z != no && z in fp && push!(pairs, ordered(no, z))
        end
    end
    if "FI" in fp
        for se in ("SE1", "SE3")
            se in fp && push!(pairs, ordered("FI", se))
        end
    end
    if "HU" in fp
        for z in ("AT", "SK")
            z in fp && push!(pairs, ordered("HU", z))
        end
    end
    # Belgium's Core FBMC borders (BE–FR, BE–NL, BE–DE_LU). Same audit as HU:
    # measured 2026-04-01..05, the implicit import ATCs into BE collapse to
    # 0–1 MW (DE_LU→BE at h08–09) and ~50–350 MW (FR/NL→BE mid-morning
    # through midday) while the physical flows average 1.4–1.9 GW (max ~4.1
    # GW) — and BE's residual peaks exactly there (+68…+94 at h07–h11,
    # cal15 bias +46 all-day). GB is outside the footprint, so BE's observed
    # GB flows were already retained as injections.
    if "BE" in fp
        for z in ("FR", "NL", "DE_LU")
            z in fp && push!(pairs, ordered("BE", z))
        end
    end
    # Swedish-internal flow-based cuts (SE2–SE3, SE3–SE4). The implicit
    # offered ATC into SE3 from SE2 averages ~118 MW over 2026-04-01..05
    # (min 0) while the physical flow averages 5,015 MW (max 7,759) — the
    # model starves SE3/SE4 of the real Norrland hydro transfer and prices
    # them at continental scarcity (cal13 bias +128/+147). SE3–SE4 shows the
    # same signature (ATC avg 1,241 vs physical max 3,995), and the unused
    # reverse directions are wide open (SE3→SE2 ATC avg 4,594, physical 0) —
    # classic flow-based residual leftovers. SE1–SE2 is deliberately KEPT
    # endogenous (its ATC is real: SE2→SE1 avg 2,702; SE1/SE2 sit at
    # +0.4/+3.4 bias).
    if "SE3" in fp
        "SE2" in fp && push!(pairs, ordered("SE2", "SE3"))
        "SE4" in fp && push!(pairs, ordered("SE3", "SE4"))
    end
    # Slovakia (Core FBMC). Same flow-based-residual signature as HU, on SK's
    # own import borders: measured 2026-01-20/02-03/12-04, the implicit offered
    # ATC CZ→SK / PL→SK average 64/24, 60/75, 128/158 MW while the physical
    # flows carry ~2,054/1,069, 1,715/1,043, 962/263 MW — SK is a transit hub
    # that physically imports ~3 GW from CZ+PL and exports ~2 GW to HU+UA, yet
    # the model saw only ~90 MW of import capacity against a 4.15 GW fleet /
    # 4.37 GW peak load, so it priced structural scarcity (iter6 sample: SK sim
    # €313 vs actual €118, bias +195, cap-clearing in winter peaks). HU–SK was
    # already dropped for HU's sake (iter4), but SK exports to HU so that gave
    # SK no import help. Dropping CZ–SK and PL–SK restores the real import
    # supply as observed import-only flows; SK carries the :hydro opportunity
    # anchor (SK_PROFILE) so those imports price at the coupled Core reference
    # instead of the €1 price-taker block (which would invert SK to a deep
    # negative bias — the NO1/BE failure mode) — the drop and the anchor are
    # ONE treatment.
    if "SK" in fp
        for z in ("CZ", "PL")
            z in fp && push!(pairs, ordered("SK", z))
        end
    end
    # Austria + Slovenia (Core FBMC, cv17 — weak-zone diagnosis §2b). The same
    # chronic flow-based-residual signature on AT's remaining Core import
    # borders and on SI's import border from AT: offered implicit ATC CZ→AT
    # averages ~110–360 MW per quarter with p10 = 0 (19 MW on the spike-hour
    # sample) vs ~1.6 GW physical; DE_LU→AT avg 52–355 / p10 = 0 (1 MW vs
    # 2.0 GW); AT→SI avg 83–285 / p10 = 0 (3 MW vs 1.3 GW). AT capped on 7/730
    # baseline days and SI on 47/730 — the worst phantom-scarcity zone —
    # exactly in the starved hours. HU–AT was already dropped for HU's sake
    # (iter3); these drops restore AT's and SI's own import supply as observed
    # import-only flows, priced at the coupled Core reference through the
    # :hydro anchors both zones carry (AUSTRIA_PROFILE, SLOVENIA_PROFILE).
    # Measured (28-day benchmark, P1): AT corr 0.17→0.75 / MAE 85.3→28.9,
    # SI 0.28→0.70 / 64.5→41.1; the v3 attribution control shows the SI drop
    # is strictly necessary (backstop-only leaves SI at corr 0.33).
    if "AT" in fp
        for z in ("CZ", "DE_LU", "SI")
            z in fp && push!(pairs, ordered("AT", z))
        end
    end
    return sort(collect(pairs))
end

"""
    build_aggregate_remap(footprint) -> Dict{String,String}

Aggregate→representative-sub-zone remap entries applicable to a footprint: an
entry `agg => rep` is included only when the footprint contains `rep` (so the
representative exists as a node) but not `agg` itself. Empty for footprints
without split-country sub-zones (e.g. the 5-zone SEE set), so the enriched
network loader is a no-op there.
"""
function build_aggregate_remap(footprint::AbstractVector{<:AbstractString})
    fp = Set(String.(footprint))
    remap = Dict{String,String}()
    for (agg, rep) in AGGREGATE_BORDER_REPRESENTATIVE
        (rep in fp) && !(agg in fp) && (remap[agg] = rep)
    end
    return remap
end

"""
    compute_opportunity_anchor_refs(anchored_zones, market_prices, transfer_capacity)
        -> Dict{String,Dict{String,Float64}}

Per-zone reference prices for the two-pass opportunity anchor, extracted from
pass-1 clearing prices: for each anchored zone, the capacity-weighted average
pass-1 price of its ENDOGENOUS neighbors per timeslot (weight = total border
ATC over the day, both directions). Zones without endogenous neighbors (the
Norwegian zones — their flow-based borders are dropped) fall back to the
continental proxy: the DE_LU/NL average. The result carries both the daily
level and the hourly shape of the coupled price. All inputs are
model-internal (pass-1 output), so the anchor keeps the counterfactual
ex-ante — no observed prices enter.

`extra_weights` (cv17, `anchor_include_dropped` profiles) adds per-zone
neighbor weights for DROPPED in-footprint borders — observed climatology
import flow summed over the day, commensurate with the ATC weights (both MW
summed over the day's periods). SE3's case: after the iter5 drops its
endogenous ref was essentially only DK1 (~0.3 GW border) while its real
marginal supply is Norrland hydro over the dropped SE2–SE3 cut (~5 GW), so
the ref becomes SE2-dominated. The climatology is strictly ex-ante.
"""
function compute_opportunity_anchor_refs(anchored_zones::Vector{String},
    market_prices::Dict{String,Dict{String,Float64}},
    transfer_capacity;
    extra_weights::Dict{String,Dict{String,Float64}}=Dict{String,Dict{String,Float64}}())

    proxy_zones = [z for z in ("DE_LU", "NL") if haskey(market_prices, z)]
    refs = Dict{String,Dict{String,Float64}}()
    for z in anchored_zones
        # Border-capacity weights toward endogenous neighbors
        w = Dict{String,Float64}()
        if transfer_capacity !== nothing
            for ((a, b, _), cap) in transfer_capacity.capacity_forward
                other = a == z ? b : (b == z ? a : nothing)
                other === nothing && continue
                haskey(market_prices, other) || continue
                w[other] = get(w, other, 0.0) + max(cap, 0.0)
            end
        end
        # cv17: dropped-border neighbors, climatology-flow-weighted (gated —
        # empty for every zone whose profile does not opt in)
        for (other, wt) in get(extra_weights, z, Dict{String,Float64}())
            haskey(market_prices, other) || continue
            w[other] = get(w, other, 0.0) + wt
        end
        sources = if !isempty(w) && sum(values(w)) > 0
            w
        else
            Dict{String,Float64}(pz => 1.0 for pz in proxy_zones)
        end
        isempty(sources) && continue
        ref = Dict{String,Float64}()
        # Weighted mean per timeslot over the sources that price that slot
        slots = union((Set(keys(market_prices[src])) for src in keys(sources))...)
        for ts in slots
            num = 0.0; den = 0.0
            for (src, wt) in sources
                haskey(market_prices[src], ts) || continue
                num += wt * market_prices[src][ts]; den += wt
            end
            den > 0 && (ref[ts] = num / den)
        end
        isempty(ref) || (refs[z] = ref)
        src_desc = isempty(w) ? "continental proxy $(join(proxy_zones, "/"))" :
                   join(sort(collect(keys(w))), ",")
        println("   ⚓ Anchor ref for $z from $src_desc: " *
                "mean=$(round(sum(values(ref))/max(length(ref),1), digits=1)) €/MWh")
    end
    return refs
end

"""
    _create_multi_zone_order_book_merit(zones::Vector{String}, day::Date)

Multi-zone order book built from per-zone merit-order books.

Flows over borders that have ATC data inside the clearing set are endogenous
(ATC-constrained MPCC flow variables), so observed net-import injections are
excluded for exactly those borders. In-set borders WITHOUT ATC links keep
their observed injections: implicit-coupling capacity data does not exist for
them (e.g. RS has no implicitly coupled borders, HU–RO moved to flow-based
coupling in June 2022), so the model cannot reproduce those flows
endogenously — excluding them would silently remove real energy from the
books and price phantom scarcity.
"""
function _create_multi_zone_order_book_merit(zones::Vector{String}, day::Date;
    enrich_network::Bool=false, apply_zone_profiles::Bool=true,
    anchor_refs::Dict{String,Dict{String,Float64}}=Dict{String,Dict{String,Float64}}(),
    cached_zone_orders::Dict{String,Vector{MarketOrders.MarketOrder}}=Dict{String,Vector{MarketOrders.MarketOrder}}(),
    clear_resolution_minutes::Int=60,
    scenario::Union{Nothing,ZoneScenario,Dict{String,ZoneScenario}}=nothing)
    isempty(zones) && error("At least one bidding zone must be specified")

    println("🌍 Creating multi-zone order book (merit-order method) for $(length(zones)) zones")

    # Network enrichment (opt-in, EU-footprint only): union explicit ATC (adds
    # CH + Serbia borders) and remap aggregate borders onto sub-zones (adds
    # Italy's continental IT-NORTH↔FR/AT/SI/CH). Also coalesces missing RES
    # forecasts so partial-coverage zones (CH, RS) build a book instead of
    # failing. Left off by default so the 5-zone SEE product is byte-identical.
    aggregate_remap = enrich_network ? build_aggregate_remap(zones) : Dict{String,String}()

    drop_borders = enrich_network ? flow_based_drop_borders(zones) :
                   Tuple{String,String}[]

    println("   🔌 Fetching transfer capacities between zones...")
    transfer_capacity = Network.create_transfer_capacity_from_entsoe(day, zones;
        include_explicit=enrich_network, aggregate_remap=aggregate_remap,
        drop_borders=drop_borders)
    zone_pairs = Network.get_zone_pairs(transfer_capacity)
    # A border only counts as endogenous if it can actually carry flow:
    # ATC rows with zero capacity in both directions all day (e.g. an
    # interconnector on full-day outage) bound the flow variable to zero,
    # so excluding observed imports over such a border would remove real
    # energy with no endogenous substitute
    can_carry_flow = Set{Tuple{String,String}}()
    for ((s, d, _), cap) in transfer_capacity.capacity_forward
        cap > 0 && push!(can_carry_flow, (s, d))
    end
    for ((s, d, _), cap) in transfer_capacity.capacity_backward
        cap > 0 && push!(can_carry_flow, (s, d))
    end
    atc_linked = Dict{String,Set{String}}(z => Set{String}() for z in zones)
    for (a, b) in zone_pairs
        (a in zones && b in zones && (a, b) in can_carry_flow) || continue
        push!(atc_linked[a], b)
        push!(atc_linked[b], a)
    end

    # Aggregate/alias codes for countries represented here by sub-zones must be
    # dropped from EVERY footprint zone's observed net imports (defensive — the
    # BZN-both-sides filter in get_net_imports already excludes them). Empty for
    # footprints without split-country sub-zones, so the 5-zone SEE path is
    # unchanged.
    shadow_codes = shadowed_aggregate_codes(zones)
    isempty(shadow_codes) ||
        println("   🚫 Shadowed aggregate codes excluded from observed imports: $(join(shadow_codes, ", "))")

    zone_exclude(keep::Vector{String}) = sort(unique(vcat(keep, shadow_codes)))

    function build_zone_book(zone::String, exclude::Vector{String})
        kept = sort([z for z in zones if z != zone && !(z in exclude)])
        isempty(kept) ||
            println("      ℹ️  No usable ATC link to $(join(kept, ", ")) — keeping observed net imports for those borders")
        # Per-zone region profile selects the bid-construction calibration.
        # In the SEE product (enrich_network=false) every zone resolves to
        # SEE_PROFILE, which equals the pre-abstraction defaults, so the call is
        # byte-identical; the EU footprint applies region-specific profiles.
        profile = (enrich_network && apply_zone_profiles) ?
                  MeritOrderBook.get_zone_profile(zone) : MeritOrderBook.SEE_PROFILE
        # Over DROPPED flow-based borders, observed flows enter import-only:
        # the import supplies a starving importer (NO1's 2.3 GW), but the
        # corresponding export must not become firm cap-priced demand in the
        # exporter's book (see get_net_imports docstring). Empty when no
        # borders were dropped, so the SEE path is unchanged.
        # All zones keep the import-only clamp on dropped borders (measured:
        # replacing it with net flows cost NO1 ~1 GW of import supply in
        # mixed-direction hours — bias −23 → +134). Hydro-anchored zones in
        # pass 2 additionally get their dropped-border EXPORT volume as a
        # separate ref-priced demand block (see anchor_export_mw), giving
        # structural exporters (NO5) their outlet without touching imports.
        import_only = sort([other for (a, b) in drop_borders
                            for other in ((a == zone) ? [b] : (b == zone) ? [a] : String[])])
        anchor_export_mw = haskey(anchor_refs, zone) && !isempty(import_only) ?
            MeritOrderBook.get_dropped_border_exports(zone, day, import_only) :
            Dict{Int,Float64}()
        # Per-zone counterfactual scenario (nothing ⇒ byte-identical no-scenario
        # book). Resolved for every (re)built zone, so an ANCHORED zone rebuilt
        # in pass 2 re-applies its own scenario, and a scenario that changed a
        # zone's pass-1 price propagates through the anchor refs to the pass-2
        # water values of every zone that references it — scenario-consistent
        # opportunity costs across the footprint.
        sc = MeritOrderBook.zone_scenario(scenario, zone)
        return create_merit_order_book(zone, day;
            profile=profile,
            net_import_exclude=exclude,
            net_import_import_only=import_only,
            target_resolution_minutes=clear_resolution_minutes,
            res_coalesce_missing=enrich_network,
            anchor_prices=get(anchor_refs, zone, nothing),
            anchor_export_mw=anchor_export_mw,
            load_modifier=(sc === nothing ? nothing : sc.load_modifier),
            renewable_modifier=(sc === nothing ? nothing : sc.renewable_modifier),
            extra_orders=(sc === nothing ? nothing : sc.extra_orders),
            strategist=(sc === nothing ? nothing : sc.strategist),
            fleet_modifier=(sc === nothing ? nothing : sc.fleet_modifier),
            load_fill=(sc === nothing ? nothing : sc.load_fill),
            res_fill=(sc === nothing ? nothing : sc.res_fill))
    end

    zone_orders = Dict{String,Vector{MarketOrders.MarketOrder}}()
    all_periods = Set{String}()
    failed_zones = String[]

    # Build phase — one task per zone. Zone books are fully independent (all
    # shared day-level caches carry locks: outages, flows, analogue days,
    # fleet-data, TTF/EUA, generator memo), so with JULIA_NUM_THREADS > 1 the
    # per-zone Postgres round-trips overlap instead of paying 39 x 2-pass
    # serial latency (~440 s of a ~464 s sequential day; the solves are
    # ~24 s). With 1 thread @spawn degrades to exact serial execution.
    # Determinism: each zone's book is computed by the same code on the same
    # inputs regardless of scheduling, and ASSEMBLY below walks `zones` in
    # order — the combined book is byte-identical to the serial build (the
    # guard recipe verifies this). Only log-line interleaving changes.
    build_one(zone) = begin
        if haskey(cached_zone_orders, zone) && !haskey(anchor_refs, zone)
            return (zone=zone, kind=:reused, result=nothing,
                    orders=cached_zone_orders[zone])
        end
        println("   📊 Processing zone $zone...")
        result = build_zone_book(zone, zone_exclude(sort(collect(atc_linked[zone]))))
        return (zone=zone, kind=:built, result=result, orders=nothing)
    end
    tasks = [(zone, Threads.@spawn build_one(zone)) for zone in zones]

    # Assembly phase — strictly in `zones` order, same effects as the old
    # serial loop (including per-zone error handling; a failed task counts
    # as a failed zone, InterruptException always rethrows).
    for (zone, task) in tasks
        try
            r = fetch(task)
            if r.kind == :reused
                zone_orders[zone] = r.orders
                for o in r.orders
                    push!(all_periods, Dates.format(o.date_time, "yyyymmdd-HHMM"))
                end
                println("   ♻️  Zone $zone: reusing pass-1 book ($(length(r.orders)) orders)")
                continue
            end
            result = r.result
            if !result.success
                @warn "Failed to generate merit orders for zone $zone: $(result.message)"
                push!(failed_zones, zone)
                continue
            end
            zone_orders[zone] = result.order_book.orders
            for period in result.order_book.periods
                push!(all_periods, period)
            end
            println("      ✅ Added $(result.supply_orders) supply + $(result.demand_orders) demand orders")
        catch e
            e isa InterruptException && rethrow()
            (e isa TaskFailedException && e.task.exception isa InterruptException) && rethrow()
            @error "Error processing zone $zone: $e"
            push!(failed_zones, zone)
        end
    end

    successful_zones = filter(z -> !(z in failed_zones), zones)
    isempty(successful_zones) && error("Failed to generate merit orders for any zone")
    if !isempty(failed_zones)
        @warn "Some zones failed: $(join(failed_zones, ", ")). Proceeding with: $(join(successful_zones, ", "))"
        # A failed zone contributes no node to the book, so the MPCC drops
        # its flow variables — any surviving zone that excluded observed
        # imports over a border to it would lose that border's energy
        # entirely. Rebuild those zones' books keeping the observed imports.
        for zone in successful_zones
            affected = sort([c for c in atc_linked[zone] if c in failed_zones])
            isempty(affected) && continue
            @warn "Rebuilding $zone book: ATC-linked zone(s) $(join(affected, ", ")) failed — restoring their observed net imports"
            exclude = zone_exclude(sort([c for c in atc_linked[zone] if !(c in failed_zones)]))
            result = build_zone_book(zone, exclude)
            result.success || error("Rebuild of $zone book failed: $(result.message)")
            zone_orders[zone] = result.order_book.orders
            for period in result.order_book.periods
                push!(all_periods, period)
            end
        end
    end

    # Trim the coupled grid to periods EVERY zone covers. A zone whose load
    # forecast is missing a period builds no orders there — most commonly the
    # last UTC hours of a day, which belong to the NEXT CET market day and are
    # not yet published at D-1 (GR/BG/RS lose 22:00–23:00 UTC while EET zones
    # like RO keep them). Left in the union grid, such a period is an EMPTY node
    # for the uncovered zone and clears at the −500 floor. Intersection drops
    # these incomplete boundary hours cleanly. No-op when every zone covers the
    # same periods (fully-published days share 24 hourly slots), so complete
    # historical clears stay byte-identical.
    zone_periods = Dict(z => Set(Dates.format(o.date_time, "yyyymmdd-HHMM")
                                 for o in zone_orders[z]) for z in successful_zones)
    common_periods = reduce(intersect, values(zone_periods))
    dropped_periods = setdiff(all_periods, common_periods)
    if !isempty(dropped_periods)
        @warn "Coupled clear: dropping $(length(dropped_periods)) period(s) not covered by all zones " *
              "(incomplete inputs — e.g. unpublished next-CET-day tail): " *
              "$(join(sort(collect(dropped_periods)), ", "))"
        for z in successful_zones
            zone_orders[z] = filter(
                o -> Dates.format(o.date_time, "yyyymmdd-HHMM") in common_periods,
                zone_orders[z])
        end
        all_periods = common_periods
    end

    all_orders = Vector{MarketOrders.MarketOrder}()
    for zone in successful_zones
        append!(all_orders, zone_orders[zone])
    end

    periods_vector = sort(collect(all_periods))

    # Transfer capacities were fetched up front (to decide which borders'
    # observed net imports to exclude); links to failed zones are filtered
    # out by the MPCC solver, which restricts pairs to the book's nodes.
    println("   ✅ Found $(length(zone_pairs)) directional transfer capacity links")

    order_book = MPCC.MPCCOrderBook(
        all_orders,
        successful_zones,
        periods_vector,
        (-500.0, 3000.0),       # EU day-ahead floor / merit demand cap
        transfer_capacity
    )

    println("✅ Created multi-zone order book (merit-order):")
    println("   🌍 Zones: $(length(successful_zones))  📝 Orders: $(length(all_orders))  🕐 Periods: $(length(periods_vector))  🔌 Links: $(length(zone_pairs))")

    return order_book
end

# ---------------------------------------------------------------------------
# Exposed multi-zone merit-order clearing STAGES.
#
# These are thin, behaviour-equivalent wrappers over the existing building
# blocks (`_create_multi_zone_order_book_merit`, `MPCC.solve_mpcc_market_clearing`,
# `compute_opportunity_anchor_refs`). The sequential two-pass path inside
# `run_multi_zone_market_clearing` calls them, and the pipelined backfill
# (`src/PipelinedBackfill.jl`) reuses the SAME functions on distributed workers —
# so a pipelined day produces byte-identical books, anchors, and prices to the
# sequential `passes=2` path. Only orchestration lives in the pipeline; all
# model/book logic stays here.
# ---------------------------------------------------------------------------

"""
    mz_build_books(zones, date; enrich_network, apply_zone_profiles) -> MPCCOrderBook

Pass-1 multi-zone merit-order book build — identical to what
`run_multi_zone_market_clearing` constructs for `order_method=:merit_order`.
"""
function mz_build_books(zones::Vector{String}, date::Date;
    enrich_network::Bool=false, apply_zone_profiles::Bool=true,
    clear_resolution_minutes::Int=60,
    scenario::Union{Nothing,ZoneScenario,Dict{String,ZoneScenario}}=nothing)
    return _create_multi_zone_order_book_merit(zones, date;
        enrich_network=enrich_network, apply_zone_profiles=apply_zone_profiles,
        clear_resolution_minutes=clear_resolution_minutes,
        scenario=scenario)
end

"""
    mz_solve_pass(order_book; optimizer, silent, mpcc_time_limit, mpcc_mip_gap,
                  mpcc_heuristic_effort) -> MPCCResult

Solve one MPCC pass over an order book (pass 1 or pass 2). Identical call to the
one inside `run_multi_zone_market_clearing`.
"""
function mz_solve_pass(order_book::MPCC.MPCCOrderBook;
    optimizer::String="auto", silent::Bool=true,
    mpcc_time_limit::Float64=900.0, mpcc_mip_gap::Float64=1e-6,
    mpcc_heuristic_effort::Union{Float64,Nothing}=nothing,
    decompose_periods::Bool=false)
    return MPCC.solve_mpcc_market_clearing(order_book;
        preferred_solver=optimizer, silent=silent,
        time_limit=mpcc_time_limit, mip_gap=mpcc_mip_gap,
        heuristic_effort=mpcc_heuristic_effort,
        decompose_periods=decompose_periods)
end

"""
    mz_extract_anchor_inputs(order_book, mpcc_result; apply_zone_profiles)
        -> (anchored, refs, cached)

Compute the pass-2 inputs from a pass-1 order book + result:
- `anchored`  : zones whose profile opts into an opportunity anchor and were
  priced in pass 1 (empty ⇒ pass 2 is a no-op, exactly as sequential),
- `refs`      : their opportunity-anchor reference prices
  (`compute_opportunity_anchor_refs`),
- `cached`    : per-zone pass-1 orders, so pass 2 reuses every non-anchored
  zone's book verbatim.

Same computation as the sequential two-pass block; only lifted into a function
so the pipeline's solver worker can run it between the two solves.
"""
function mz_extract_anchor_inputs(order_book::MPCC.MPCCOrderBook,
    mpcc_result::MPCC.MPCCResult; apply_zone_profiles::Bool=true)
    anchored = apply_zone_profiles ?
        [z for z in order_book.nodes
         if MeritOrderBook.get_zone_profile(z).opportunity_anchor != :none &&
            haskey(mpcc_result.market_prices, z)] : String[]
    if isempty(anchored)
        return (anchored=anchored,
            refs=Dict{String,Dict{String,Float64}}(),
            cached=Dict{String,Vector{MarketOrders.MarketOrder}}())
    end
    # cv17: anchor refs over DROPPED borders (profile-gated via
    # `anchor_include_dropped` — currently SE3). For each flagged anchored
    # zone, weight each dropped in-footprint neighbor by its observed
    # climatology IMPORT flow summed over the day (MW·periods, commensurate
    # with the ATC weights). Ex-ante: the climatology uses only pre-auction
    # days; the day is recovered from the book's period grid.
    extra_w = Dict{String,Dict{String,Float64}}()
    flagged = [z for z in anchored
               if MeritOrderBook.get_zone_profile(z).anchor_include_dropped]
    if !isempty(flagged) && !isempty(order_book.periods)
        day = Date(String(order_book.periods[1])[1:8], dateformat"yyyymmdd")
        drops = flow_based_drop_borders([String(n) for n in order_book.nodes])
        for z in flagged
            clim = MeritOrderBook._zone_border_hourly_clim(z, day)
            w = Dict{String,Float64}()
            for (a, b) in drops
                other = a == z ? b : (b == z ? a : nothing)
                other === nothing && continue
                haskey(mpcc_result.market_prices, other) || continue
                s = sum((max(f, 0.0) for ((h, cp, dir), f) in clim
                         if cp == other && dir == 1); init=0.0)
                s > 0.0 && (w[other] = s)
            end
            isempty(w) || (extra_w[z] = w)
        end
    end
    refs = compute_opportunity_anchor_refs(anchored,
        mpcc_result.market_prices, order_book.network_topology;
        extra_weights=extra_w)
    cached = Dict{String,Vector{MarketOrders.MarketOrder}}(
        z => [o for o in order_book.orders if String(o.zone) == z]
        for z in order_book.nodes)
    return (anchored=anchored, refs=refs, cached=cached)
end

"""
    mz_rebuild_anchored(zones, date, refs, cached; enrich_network,
                        apply_zone_profiles) -> MPCCOrderBook

Pass-2 book build: rebuild ONLY the anchored zones (those present in `refs`),
reusing every other zone's pass-1 orders from `cached`. Identical to the
`order_book2` constructed inside `run_multi_zone_market_clearing`'s two-pass
block.
"""
function mz_rebuild_anchored(zones::Vector{String}, date::Date,
    refs::Dict{String,Dict{String,Float64}},
    cached::Dict{String,Vector{MarketOrders.MarketOrder}};
    enrich_network::Bool=false, apply_zone_profiles::Bool=true,
    clear_resolution_minutes::Int=60,
    scenario::Union{Nothing,ZoneScenario,Dict{String,ZoneScenario}}=nothing)
    return _create_multi_zone_order_book_merit(zones, date;
        enrich_network=enrich_network, apply_zone_profiles=apply_zone_profiles,
        anchor_refs=refs, cached_zone_orders=cached,
        clear_resolution_minutes=clear_resolution_minutes, scenario=scenario)
end

