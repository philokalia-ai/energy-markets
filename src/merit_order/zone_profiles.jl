# zone_profiles.jl — ZoneProfile struct + every zone profile constant + ZONE_PROFILES registry + ZoneScenario hooks.
# Included by ../MeritOrderBook.jl inside `module MeritOrderBook` (definition order preserved).

const WATER_VALUE_FUEL_TYPES =
    [Symbol("Hydro Water Reservoir"), Symbol("Hydro Pumped Storage")]


# ENTSO-E production_type strings for hydro availability lookup
const HYDRO_PRODUCTION_TYPES =
    ["Hydro Water Reservoir", "Hydro Pumped Storage", "Hydro Run-of-river and pondage"]

# =============================================================================
# VIRTUAL BOUNDARY-COUNTERPARTY BOOK (cv21) — model the country, not the flow
# =============================================================================
"""
    BoundaryBook

Configuration for a modeled out-of-footprint neighbor on ONE physical border
(the virtual-boundary-zone program, docs/experiments/cv21-dk1-viking.md). When
a zone's profile carries a `BoundaryBook`, `create_merit_order_book`:

1. REMOVES the counterparty's fixed net-import injection (its `flow_codes` are
   excluded from `get_net_imports`) and its share of the import-backstop
   headroom — the elastic book replaces both; and
2. ADDS an elastic counterparty ladder — an **import supply** stack (the
   neighbor sells into the zone above its own marginal cost) and an **export
   demand** stack (the neighbor buys from the zone below it), laddered over the
   border's demonstrated interconnector capability (`get_boundary_capability`).

The neighbor's willingness to pay/sell is anchored on ITS OWN fundamental SRMC
(`anchor`, e.g. GB CCGT SRMC from TTF + EUA-proxied UK carbon), never on our
price and never a fixed multiple of our SRMC — the boundary-program standing
rule (roadmap §"Standing rules"). `anchor_mult` scales that anchor (the
measured sensitivity choice; documented not load-bearing between mid/high).

Fields:
- `counterparty` — label for tagging/logging (e.g. `"GB"`).
- `flow_codes`   — `entsoe.physical_flows` / offered-ATC map codes for the
  border, excluded from injections + backstop and measured for capability
  (DK1↔GB carries the single aggregate `"GB"` code).
- `anchor`       — which neighbor-fundamental SRMC to anchor on
  (`:gb_ccgt_srmc`).
- `anchor_mult`  — sensitivity multiplier on the anchor.
- `imp_ladder`   — import-supply rungs `(price_mult, capability_share)`: the
  neighbor sells to us at `price_mult × anchor × anchor_mult` for
  `capability_share ×` the demonstrated import capability.
- `exp_ladder`   — export-demand rungs `(price_mult, capability_share)`: the
  neighbor buys from us, symmetric.

`nothing` on a profile (every zone but DK1) ⇒ the mechanism is entirely dead
code and the book is byte-identical.

Additional fields (cv22, the UA firm-slice boundary treatment — a
war-constrained scarcity buyer on the HU/SK/RO/PL–UA borders,
docs/experiments/cv22.md):
- `capability_mode` — how `get_boundary_capability` sizes the border:
  `:atc_capped` (cv21/DK1: the day's offered DA explicit ATC capped at the
  trailing-366d demonstrated max, p95 floor on ATC gaps) or `:p95_block`
  (cv22/UA: the pure trailing-366d p95 gross flow per 4h block — the wave-1
  Mechanism-A definition; UA explicit ATC is stale/absent and understates
  realized flows ~4×, so the demonstrated-capability floor is used uniformly).
- `firm_slice` — when `true`, the export-demand stack is split into a FIRM
  cap-priced base slice (`firm_price`, a price-taker at the cap: the
  war-constrained structural import that does not curtail on price) sized by
  `get_boundary_firm` (trailing-`firm_window_days`-day `firm_quantile` of the
  daily 4h-block-mean gross export flow zone→counterparty), plus the elastic
  `exp_ladder` on the TAIL above it. `false` (DK1) ⇒ the whole export stack is
  elastic (byte-identical to cv21).
- `disable_env` — the env var whose non-empty value strips this book in
  `get_zone_profile` (Viking: `EUPHEMIA_DISABLE_CV21`; UA: `EUPHEMIA_DISABLE_CV22`),
  so each cv's byte-identity guard disables exactly its own books.
"""
Base.@kwdef struct BoundaryBook
    counterparty::String
    flow_codes::Vector{String}
    # Map codes stripped from `get_net_imports` + the import backstop (the
    # elastic ladder replaces both). Empty ⇒ defaults to `flow_codes`
    # (DK1/UA — a single netted code). **FR↔GB lists all four codes** (`GB`
    # AND the per-cable `GB_IFA`/`GB_IFA2`/`GB_ElecLink`): ENTSO-E publishes the
    # FR↔GB flow BOTH as the aggregate `GB` and as the three cables, so the
    # loader summed them ≈2× — the cv23 double-count fix (see GB_FR_BOOK,
    # docs/experiments/gb-borders-cv22.md). Excluding all four removes the
    # phantom AND the true injection; the ladder prices the border once.
    net_exclude_codes::Vector{String} = String[]
    # Offered-ATC map codes for capability sizing. Empty ⇒ defaults to
    # `flow_codes`. **FR↔GB has NO aggregate ATC** — it is published only
    # per-cable, so FR lists the three cables and `get_boundary_capability`
    # AVG-within-cable then SUMS across cables (a single-code border sums one
    # cable ⇒ byte-identical to the old per-(dir,hour) AVG).
    atc_codes::Vector{String} = String[]
    anchor::Symbol
    # Carbon leg of the `:gb_ccgt_srmc` anchor: `:eua` (DK1/Viking — its cv21
    # validated config) or `:uka` (FR — the correct UK-ETS price from
    # `carbon.uka_price`, falling back to EUA when the feed is unavailable, e.g.
    # the offline extract).
    carbon_source::Symbol = :eua
    anchor_mult::Float64 = 1.0
    imp_ladder::Vector{Tuple{Float64,Float64}}
    exp_ladder::Vector{Tuple{Float64,Float64}}
    capability_mode::Symbol = :atc_capped
    firm_slice::Bool = false
    firm_price::Float64 = 2999.0
    firm_window_days::Int = 28
    firm_quantile::Float64 = 0.10
    disable_env::String = "EUPHEMIA_DISABLE_CV21"
end

# Which map codes a boundary book strips from net imports / backstop, and which
# it sizes offered ATC on. Empty vectors default to `flow_codes` so DK1/Viking +
# the UA books (single netted code, no per-cable split) stay byte-identical.
boundary_net_exclude(b::BoundaryBook) =
    isempty(b.net_exclude_codes) ? b.flow_codes : b.net_exclude_codes
boundary_atc_codes(b::BoundaryBook) =
    isempty(b.atc_codes) ? b.flow_codes : b.atc_codes

"""
    VIKING_GB_BOOK

The DK1/Viking-Link (DK1–GB) boundary book shipped in cv21 — the boundary
program's cleanest single lever (confirm 2026-07-24: DK1 July MAE 31.5→28.3,
corr 0.90→0.93; March MAE 27.6→25.2, corr 0.55→0.80; no FR/NL/NO2 leakage —
docs/experiments/cv21-dk1-viking.md). GB is modeled as its own CCGT-marginal
counterparty on the Viking Link only; GB's other borders are untouched (GB the
zone is PARKED pending an Elexon/BMRS + UKA fundamentals feed).

Anchor: `1.15 × GB CCGT SRMC` (TTF/0.52 + EUA-proxied UK carbon/0.52 + €2 O&M).
The high multiplier is the wave-2/refine sensitivity choice — DK1 favored it
monotonically and the plain CCGT SRMC understates GB's willingness to pay; the
mid↔high difference on DK1 is within noise (documented not load-bearing).
Ladders are the wave-2 shapes: import supply `× [1.00, 1.15, 1.30]` (50/30/20),
export demand `× [1.05, 0.90]` (50/50).
"""
const VIKING_GB_BOOK = BoundaryBook(
    counterparty = "GB",
    flow_codes = ["GB"],
    anchor = :gb_ccgt_srmc,
    anchor_mult = 1.15,
    imp_ladder = [(1.00, 0.5), (1.15, 0.3), (1.30, 0.2)],
    exp_ladder = [(1.05, 0.5), (0.90, 0.5)],
)

"""
    GB_FR_BOOK

The FR↔GB boundary book (cv23 — roadmap item 5, `docs/experiments/gb-borders-cv22.md`,
re-paired with the FR nuclear fix per that file's NO-SHIP verdict). Two bugs
paired into one lever (non-shippable alone):

1. **FR–GB flow double-count fix.** ENTSO-E publishes the FR↔GB physical flow
   BOTH as the aggregate `GB` code AND as the three cables `GB_IFA` / `GB_IFA2`
   / `GB_ElecLink`; `get_net_imports` summed all four ≈2× the true exchange
   (verified: aggregate `GB` = Σcables exactly, so the injection was doubled).
   `net_exclude_codes` lists all four ⇒ the whole GB injection (phantom + true)
   leaves the fixed schedule; the ladder prices the border once.
2. **The honest GB premium** the phantom was masking: GB is priced as an elastic
   CCGT-marginal counterparty on the Viking recipe — import supply + export
   demand laddered over the FR↔GB demonstrated capability, anchored on GB's own
   fundamental SRMC (`:uka` carbon: the correct UK-ETS price). Shipping (1)
   alone cost FR +4.2 July MAE (the double-count accidentally compensated
   France's too-cheap evening supply curve), so the pair ships together with the
   FR nuclear opportunity-cost fix that fixes that supply curve at the root.

Capability: FR↔GB flow is the aggregate `GB` (`flow_codes`); its offered ATC is
published only per-cable (no aggregate), so `atc_codes` lists the three cables
and their DA ATC is AVG-within-cable then SUMMED across cables. Anchor
`1.15 × GB CCGT SRMC` and the ladder shapes are the wave-2/cv21 Viking constants
(no price fit). Carried on `FR_PROFILE`, gated by `EUPHEMIA_DISABLE_CV23`
(strips it together with the FR nuclear scaling ⇒ cv22 main).
"""
const GB_FR_BOOK = BoundaryBook(
    counterparty = "GB",
    flow_codes = ["GB"],
    net_exclude_codes = ["GB", "GB_IFA", "GB_IFA2", "GB_ElecLink"],
    atc_codes = ["GB_IFA", "GB_IFA2", "GB_ElecLink"],
    anchor = :gb_ccgt_srmc,
    carbon_source = :uka,
    anchor_mult = 1.15,
    imp_ladder = [(1.00, 0.5), (1.15, 0.3), (1.30, 0.2)],
    exp_ladder = [(1.05, 0.5), (0.90, 0.5)],
    disable_env = "EUPHEMIA_DISABLE_CV23",
)

"""
    UA_BOOK(flow_codes)

The Ukraine boundary book shipped in cv22 (roadmap item 1, the firm-slice
refinement — docs/experiments/cv22.md + boundary-refine README). UA is modeled
as a WAR-CONSTRAINED SCARCITY BUYER on the HU/SK/RO/PL–UA borders: on the import
side it sells cheap surplus (nuclear/hydro marginal) into the footprint; on the
export side it buys with a FIRM cap-priced base slice (its demonstrated
persistent import need, which does not curtail on price — the mechanism that
killed the wave-2 HU March breach) plus an elastic tail at gas parity and above.

No UA fundamentals feed exists, so the anchor is `:zone_gas_srmc` (our OWN gas
SRMC) — the documented wave-1 generic-anchor risk, accepted here because the
firm slice, not the elastic anchor, does the load-bearing work. Import supply
`0.55 × gas × [0.85, 1.00, 1.20]` (baked into `imp_ladder` with `anchor_mult=1`);
export tail `gas × [1.20, 1.00]`; firm base = trailing-28-day p10 of the daily
4h-block-mean gross export flow zone→UA (`get_boundary_firm`), price-taker at the
cap. Capability = pure trailing-366d p95 gross flow per 4h block (`:p95_block`).

Confirm 2026-07-24 (24-day A/B): HU July MAE 72.3→57.1 / corr 0.69→0.79; March
MAE 28.24→28.29 (the breach dead); spillovers SK July eve bias −82→−73, SI July
MAE 80.7→70.1. Accepted residuals: HU March evening MAE 29.2→33.0, RO/BG March
~+1. PL additionally carries the UA_DobTPP radial in its flow codes.
"""
UA_BOOK(flow_codes::Vector{String}=["UA"]) = BoundaryBook(
    counterparty = "UA",
    flow_codes = flow_codes,
    anchor = :zone_gas_srmc,
    anchor_mult = 1.0,
    # 0.55 × gas × [0.85, 1.00, 1.20] baked in (anchor_mult = 1.0).
    imp_ladder = [(0.55 * 0.85, 0.5), (0.55 * 1.00, 0.3), (0.55 * 1.20, 0.2)],
    exp_ladder = [(1.20, 0.5), (1.00, 0.5)],
    capability_mode = :p95_block,
    firm_slice = true,
    firm_price = 2999.0,
    firm_window_days = 28,
    firm_quantile = 0.10,
    disable_env = "EUPHEMIA_DISABLE_CV22",
)
const UA_BOOK_DEFAULT = UA_BOOK(["UA"])            # HU / SK / RO
const UA_BOOK_PL = UA_BOOK(["UA", "UA_DobTPP"])    # PL adds the Dobrotvir radial

# =============================================================================
# ZONE PROFILES — per-region bid-construction calibration
# =============================================================================
# ---------------------------------------------------------------------------
# Model constants
# ---------------------------------------------------------------------------
# These were `ZoneProfile` fields, but they hold the same value in all 39 zones
# — constants wearing a parameter's clothes. A zone's PROFILE should carry only
# what actually differs between zones, so that the struct and the published
# zone-strategy table are the same object seen twice. Anything here that a
# future zone genuinely needs to vary comes back as a field, deliberately.

"SRMC tranches: (share of p_max, price multiplier), cheapest first."
const TRANCHES = [(0.55, 0.95), (0.20, 1.05), (0.15, 1.25), (0.10, 1.60)]
"Must-run blocks bid at this fraction of the unit's SRMC (absolute below-cost discount)."
const MUST_RUN_PRICE_FACTOR = 0.05
"A unit is must-run when its SRMC is below this multiple of the zone's gas SRMC."
const MUST_RUN_SRMC_THRESHOLD = 1.15
"Fraction of nameplate offered by default."
const AVAILABILITY_FACTOR = 0.80
"Exponent of the peak-hour scarcity markup."
const PEAK_EXPONENT = 4.0
"Dry-year multiplier on the water value."
const WATER_VALUE_DRY_BOOST = 1.0
"Share of demand bid elastically."
const DEMAND_ELASTIC_SHARE = 0.02
"Price of the elastic demand block (EUR/MWh)."
const DEMAND_ELASTIC_PRICE = 250.0
"Bid cap (EUR/MWh)."
const PRICE_CAP = 3000.0
"Complete the offered fleet up to the p95/installed truth target."
const FLEET_COMPLETION = true
"Derate baseload types to their demonstrated trailing capability."
const FLEET_TRUTHING = true
"Headroom multiplier on the fleet-truthing derate target."
const DERATE_HEADROOM = 1.15
"Import backstop: price multiple of the zone gas SRMC."
const BACKSTOP_PRICE_MULT = 1.8
"Import backstop: trailing same-weekday window (weeks)."
const BACKSTOP_WEEKS = 8
"Nuclear availability at/above which no opportunity premium applies."
const NUCLEAR_AVAIL_REF = 0.80
"Nuclear availability at/below which the premium saturates (crisis floor)."
const NUCLEAR_AVAIL_FLOOR = 0.50

"""
    FIELD_DESCRIPTIONS

One plain-language line per `ZoneProfile` field. Lives HERE, beside the fields, so
the generated calibration table (`bin/export_zone_strategies.jl`) and the test that
guards it read the same object — a second copy in either place could drift while
the test still passed, which is the exact failure this whole table exists to
prevent. `test_zone_strategy_export.jl` asserts the key set equals
`fieldnames(ZoneProfile)`, so adding a field without describing it fails there.
"""
const FIELD_DESCRIPTIONS = Dict{Symbol,String}(
    :scarcity_threshold => "supply margin below which offers start to steepen",
    :scarcity_kappa => "how hard offers steepen once the margin is thin",
    :peak_kappa => "extra uplift at the day's demand peak",
    :water_value_base => "reservoir hydro's opportunity cost, as a multiple of gas SRMC",
    :water_value_span => "how much the water value swings across the day's demand range",
    :thermal_srmc_multiplier => "premium on this zone's thermal running costs (Italy: 1.20)",
    :hydro_model => "gas-anchored water value, or reservoir-opportunity from weekly levels",
    :nuclear_srmc_floor => "floor under nuclear bids (EUR/MWh) — France's off-peak position",
    :opportunity_anchor => "which fleet re-bids in pass 2 against the coupled price",
    :anchor_share => "fraction of the coupled reference the anchored fleet asks for",
    :nuclear_avail_share_lo => "anchor share when the nuclear fleet is at its crisis floor",
    :nuclear_avail_share_hi => "anchor share when the fleet is fully available",
    :nuclear_bid_ref_ceiling => "cap on anchor-lifted nuclear bids, as a multiple of the reference",
    :scarcity_import_credit => "credit available import capacity against the scarcity margin",
    :fleet_truth_mode => "true the fleet to trailing p95 output, or to registry installed capacity",
    :seasonal_drawdown => "follow the seasonal reservoir drawdown cycle (Swedish north)",
    :import_backstop => "offer demonstrated import headroom as elastic supply",
    :backstop_scarcity_credit => "also credit that headroom in the scarcity margin",
    :ref_priced_exports => "price exports over retained borders at the coupled reference",
    :boundary_book => "an out-of-footprint neighbour modelled as an elastic counterparty",
)

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
    scarcity_threshold::Float64 = 1.4
    scarcity_kappa::Float64 = 3.0
    peak_kappa::Float64 = 1.2
    water_value_base::Float64 = 0.85
    water_value_span::Float64 = 0.9
    thermal_srmc_multiplier::Float64 = 1.0
    hydro_model::Symbol = :gas_anchored
    nuclear_srmc_floor::Float64 = 0.0
    opportunity_anchor::Symbol = :none
    anchor_share::Float64 = 0.9
    # Availability-scaled nuclear opportunity cost (cv23, the "nuclear water
    # value"). France's nuclear fleet is energy-constrained (summer maintenance
    # + river-temperature de-rating), so the opportunity cost of deploying a
    # scarce nuclear MWh rises as the fleet's energy budget tightens — the same
    # reservoir/water-value logic already used for hydro. When active AND the
    # `:nuclear` anchor is in force, the fixed `anchor_share` is REPLACED by a
    # share that scales with ex-ante nuclear availability tightness:
    #   a         = trailing-30d nuclear output p95 ÷ installed nuclear capacity
    #               (both already queried by fleet-truthing — ex-ante, no fit)
    #   tightness = clamp((nuclear_avail_ref − a) /
    #                     (nuclear_avail_ref − nuclear_avail_floor), 0, 1)
    #   share_eff = nuclear_avail_share_lo +
    #               (nuclear_avail_share_hi − nuclear_avail_share_lo) · tightness
    # Loose fleet (winter, a≈0.80) → share_lo (nuclear bids near fuel cost,
    # pulls the over-priced winter evenings down); tight fleet (summer, a≈0.60)
    # or crisis (2023, a≈0.53) → toward share_hi (scarce nuclear prices the
    # ramp/peak at high opportunity cost, lifts the under-priced summer ramp).
    # The water-value clamp is preserved (floored at fuel SRMC, capped by the
    # coupled reference), so this never manufactures scarcity — it only
    # redistributes the nuclear bid across the availability regime.
    # nuclear_avail_share_hi == 0 ⇒ OFF: the fixed anchor_share is used
    # (byte-identical). See docs/experiments/cv23-fr-nuclear.md.
    nuclear_avail_share_lo::Float64 = 0.0
    nuclear_avail_share_hi::Float64 = 0.0
    # cv23 FR-cap ceiling. When > 0 AND the :nuclear anchor is active, every
    # nuclear SUPPLY-order price (must-run + tranches, after the scarcity/peak
    # markup) is clamped to `nuclear_bid_ref_ceiling × coupled-reference` — nuclear
    # is an opportunity-cost price-TAKER on the export price, so it should never
    # bid more than a modest markup ABOVE the reference it is anchored on. Without
    # the clamp the upper-tranche scarcity markup amplifies the anchor-lifted base
    # to ≈1.85×ref, which on the crisis-tight winter day 2023-01-10 helped tip the
    # whole footprint to the €3000 cap (docs/experiments/cv23-fr-cap.md). At 1.3
    # it never bites on the summer gain days (which clear at ≈ the reference, well
    # below 1.3×ref) yet bounds the crisis explosion. 0 = off (byte-identical).
    nuclear_bid_ref_ceiling::Float64 = 0.0
    # Scarcity import credit (iter6): fraction of the zone's offered import ATC
    # to add to dispatchable capacity in the scarcity margin. A thermal zone with
    # GWs of available import capacity is NOT strategically scarce even when its
    # own derated fleet looks tight (DE_LU is a NET EXPORTER yet priced €178) —
    # the real scarcity, if any, arrives through the coupled import PRICE, not a
    # domestic mark-up. 0 = off (SEE/guard unchanged and byte-identical). Uses
    # offered ATC only (D-1 legal). Softens ONLY the scarcity margin; the actual
    # imports still clear through the MPCC.
    scarcity_import_credit::Float64 = 0.0
    # Fleet-truth mode (iter7). What each MARKET-ACTIVE fuel type's fleet is
    # trued to (completed up to by fleet completion, never derated below by
    # fleet truthing):
    #   :p95       — trailing-30d p95 (default; the byte-identical v10/iter6
    #                behaviour — GR/SEE must stay here: the crisis-honesty
    #                derate depends on it).
    #   :seasonal  — max(30d p95, trailing-365d p95): last-YEAR observed
    #                capability. Captures merit-order-idle capacity that ran in
    #                the previous winter but not the last 30 days, while
    #                excluding closed plants and grid-reserve units that never
    #                clear the market. Pure observed output, ex-ante.
    #   :installed — the ENTSO-E registry's installed capacity (activity-gated
    #                per type at 30d p95 > 100 MW). Largest fleet: also pulls
    #                in mothballed/reserve capacity with stale COMMISSIONED
    #                status (measured iter7: over-adds — broad negative bias).
    # Fixes the under-counted idle thermal of the meshed continental core:
    # units idle on merit order never enter the 30d-p95 completion, so the book
    # cleared deep in the expensive tranches (DE_LU sim €178 vs actual €109
    # with 44 GW modeled vs ~60 GW active-installed).
    fleet_truth_mode::Symbol = :p95
    # Seasonal water-value drawdown (reservoir_opportunity zones only): raise the
    # water-value floor with the absolute reservoir drawdown vs the trailing
    # 52-week peak, so winter depletion prices stored water as scarcer even when
    # the prior-year-relative dryness reads ~0. On for the mainland reservoir
    # zones (SE1/SE2); off for far-north export-congested NO4, whose low price
    # is set by export congestion, not the seasonal water value.
    seasonal_drawdown::Bool = true
    # --- cv17 import-fix mechanisms (weak-zone diagnosis,
    # docs/experiments/weak-zone-diagnosis). All defaults inert, so
    # SEE/guard/single-zone books stay byte-identical.
    #
    # Ex-ante elastic import backstop (P2 of the diagnosis). One extra supply
    # block per hour, sized by the zone's recently DEMONSTRATED import headroom
    # beyond the :v2 flow climatology the book already injects:
    #   qty(h) = max(0, max over trailing `backstop_weeks` same-weekday days of
    #                net import(h) − climatology median(h)
    #                − offered ENDOGENOUS import ATC(h))
    # (the last term avoids double counting capacity the MPCC flow variables
    # can already deliver), priced at `backstop_price_mult ×` gas SRMC — above
    # every domestic tranche multiplier (max 1.60), so it displaces nothing in
    # normal hours and only prevents the jump from ~1.6×gas straight to the
    # €3,000 cap on the ~2% tail days when the zone leans on its neighbors
    # beyond climatology (reality: more import arrives as the price rises).
    # All inputs strictly predate the D-1 auction (fully ex-ante).
    import_backstop::Bool = false
    # Fraction of the hourly backstop quantity credited into the scarcity
    # margin (the backstop analogue of `scarcity_import_credit`): the scarcity
    # MARKUP otherwise cannot see the backstop supply, so restored-import days
    # can keep a residual markup overshoot. 0 = off (default).
    backstop_scarcity_credit::Float64 = 0.0
    # Price RETAINED-border observed net exports at the coupled/anchor
    # reference instead of firm demand at the cap (pass 2, anchored zones
    # only): a real exporter curtails its export under domestic stress
    # (SI–HR, BE–GB) instead of serving it at any price — the demand-side
    # mirror of the dropped-border `anchor_export_mw` treatment. Off by
    # default (byte-identical cap-priced exports elsewhere).
    ref_priced_exports::Bool = false
    # cv21 virtual boundary-counterparty book (docs/experiments/cv21-dk1-viking.md).
    # When set, the out-of-footprint neighbor on ONE physical border is modeled as
    # an elastic counterparty (import-supply + export-demand ladders anchored on
    # the NEIGHBOR's own fundamental SRMC), and that counterparty's fixed flow
    # injection + import-backstop headroom are removed. `nothing` = off
    # (byte-identical). Only DK1 (Viking Link, GB) carries one in cv21; see
    # `BoundaryBook` / `VIKING_GB_BOOK`.
    boundary_book::Union{Nothing,BoundaryBook} = nothing
end

"""
    with_profile(p::ZoneProfile; overrides...) -> ZoneProfile

Copy of `p` with the given fields replaced — used to author zone variants of a
shared regional profile (e.g. DK1/DK2 = NORDIC + import backstop) without
duplicating the base calibration.
"""
function with_profile(p::ZoneProfile; overrides...)
    nt = NamedTuple{fieldnames(ZoneProfile)}(
        ntuple(i -> getfield(p, i), fieldcount(ZoneProfile)))
    return ZoneProfile(; merge(nt, values(overrides))...)
end

"""
    FLEET_TRUTH_OVERRIDE

Process-wide override of every profile's `fleet_truth_mode` (`nothing` = use
the profile's own mode). Set to `:p95` by the multi-zone per-day robustness
fallback: when the coupled MPCC stays infeasible through the whole retry
ladder, the day is re-cleared with baseline v10 fleet truth rather than
shipped missing. Always reset in a `finally` — never left set.
"""
const FLEET_TRUTH_OVERRIDE = Ref{Union{Nothing,Symbol}}(nothing)

_effective_fleet_truth_mode(profile) =
    something(FLEET_TRUTH_OVERRIDE[], profile.fleet_truth_mode)

"SEE / default profile — the exact v10 parameters (regression baseline)."
const SEE_PROFILE = ZoneProfile()


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
    # iter6: DE_LU/NL/PL/CZ are meshed thermal zones with GWs of import capacity
    # and are frequently net exporters — the domestic scarcity mark-up mis-fired
    # (DE_LU +70, a NET EXPORTER, priced €178). Credit available import ATC.
    scarcity_import_credit = 1.0,
    # iter7: idle-but-existing thermal (merit-order idle, not closed) never
    # appears in the 30d-p95 completion, so the book cleared deep in the
    # expensive tranches (DE_LU modeled 44 GW vs ~60 GW active-installed;
    # measured gaps: DE hard coal 21.0 installed vs 9.8 GW modeled, lignite
    # 19.6 vs 11.2, gas 19.5 vs 15.2; PL hard coal 18.6 vs 14.1).
    #
    # iter7 measured :installed here at a TRANSFORMATIVE gain (DE_LU MAE 73→22
    # corr 0.62→0.80, PL 86→30, aggregate meanMAE 45→32) but parked it: the
    # DE_LU book made 1/36 sample days FALSELY infeasible — Big-M q×price-span
    # constants up to ~2.6e8 on multi-GW cap-priced demand blocks leak through
    # the integrality tolerance and produce false certificates that survived
    # the numeric retry ladder. iter8 fixes that at the root: a final MPCC
    # retry rung swaps the Big-M complementarity for EXACT Gurobi indicator
    # constraints (no constants), plus a per-day :p95-books fallback in
    # run_multi_zone_market_clearing as the safety net — so :installed is now
    # enabled. :seasonal (trailing-365d p95) was measured a NO-OP on winter
    # failure days (idle capacity never generates even across a year;
    # :installed stands in for offered-but-undispatched units and the unlisted
    # <100 MW CHP fleet). Evidence: docs/eu-calibration-iter7.md + iter8.
    fleet_truth_mode = :installed,
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
Far-north Norway (NO4). Same reservoir-opportunity hydro as NORDIC but with the
seasonal drawdown OFF: NO4 is congestion-isolated (actuals ≈ €29 year-round —
it exports into a constrained grid, so its price is set by the export bottleneck,
not by the winter shadow value of its still-brimming reservoirs, which stay near
80% full in February). With the drawdown on (iter6 c2), NO4 over-priced by +8.6
in winter; off, it stays centered (+0.2) while SE1/SE2 keep the drawdown lift.
"""
const NO4_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    seasonal_drawdown = false,
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
    # neighbor price. cv23: this fixed share is REPLACED at runtime by the
    # availability-scaled band [nuclear_avail_share_lo, nuclear_avail_share_hi]
    # below (a strict generalization — lo=hi=0.55 reproduces this exactly).
    anchor_share = 0.55,
    # cv23 availability-scaled nuclear opportunity cost. Endpoints read off the
    # fleet's demonstrated availability envelope + the opportunity-cost economics
    # (no price fit): winter-loose nuclear (a≈0.80) bids at share_lo=0.40 — below
    # the old 0.55, pulling the over-priced winter/morning peaks down; summer- or
    # crisis-tight nuclear (a≈0.50–0.66) scales toward share_hi=0.95, the near-
    # full export/opportunity value of a budget-limited MWh, lifting the €15–21
    # under-priced summer late-afternoon ramp. a_ref=0.80 (winter-peak observed
    # 0.74–0.86), a_floor=0.50 (2023-crisis / deep-maintenance floor). See
    # docs/experiments/cv23-fr-nuclear.md §"the designed rule".
    nuclear_avail_share_lo = 0.40,
    nuclear_avail_share_hi = 0.95,
)

"""
FR (cv23). FRANCE_PROFILE (nuclear opportunity-cost bidding) plus the FR↔GB
boundary book (`GB_FR_BOOK`): GB is modeled as its own CCGT-marginal counterparty
on the FR↔GB interconnectors (IFA/IFA2/ElecLink), replacing the double-counted
fixed GB flow injection with an elastic ladder anchored on GB's own fundamental
SRMC (UK-ETS carbon). The FR nuclear fix (availability-scaled opportunity cost)
and the GB pair (double-count fix + honest GB premium) are the two coupled cv23
components — shipped together per the cv22 GB-pair NO-SHIP verdict ("fix France's
supply curve first, then re-run this exact A/B"). Both gated by
`EUPHEMIA_DISABLE_CV23` (docs/experiments/cv23-fr-nuclear.md).

**cv23 FR-cap fix (post-merge, `docs/experiments/cv23-fr-cap.md`).** The
availability-scaled nuclear share + the GB export-demand ladder together tipped
the crisis-tight winter day 2023-01-10 into a footprint-wide €3000 phantom cap
(19 zones capped, DE_LU mean 89→211/cap, FR 137→270/cap; the base cv22 day is
normal). Diagnosis: FR's *single-zone* book clears fine that day (mean 200, max
540) — the cap is purely the COUPLED pass-2 mechanism. In pass 2 the nuclear
anchor lifts nuclear's bid base to `share·coupled-ref` (0.67·high-crisis-ref),
and the **scarcity markup** on the upper tranches — which cannot see any relief —
then amplifies that elevated base into the €3000 cap and cascades the coupled
clear. The fix is the program's established two-part pattern (exactly the
RO/RS/HU treatment): (1) the ex-ante elastic **import backstop** — FR's
demonstrated import headroom (~4–9 GW in the 2022–23 crisis, when FR imported
heavily) offered as supply at `1.8 × gas SRMC`, above every domestic tranche so
it binds only near the cap, self-scaling with gas so it never clips the
legitimate crisis-summer nuclear lift; and (2) **`backstop_scarcity_credit = 1.0`**
— the same demonstrated import headroom credited into the scarcity margin, so the
markup can SEE the available imports and no longer explodes the nuclear tranches
(the mechanism RO/RS/HU added for precisely this "scarcity markup can't see the
backstop supply" overshoot). Gated by `EUPHEMIA_DISABLE_FRCAP` (byte-identity:
reverts FR to the cv23 no-backstop profile; non-FR zones untouched). Verified:
2023-01-10 clears sanely, the 5 clean 2023 days keep their gains.
"""
const FR_PROFILE = with_profile(FRANCE_PROFILE;
    boundary_book = GB_FR_BOOK, import_backstop = true, backstop_scarcity_credit = 1.0,
    nuclear_bid_ref_ceiling = 1.3)

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
Interior Norway (NO1/NO3, cv23). NORWAY_PROFILE plus the ex-ante `import_backstop`
(docs/experiments/norwegian-hydro/DIAGNOSIS.md + results.md).

The interior hydro pockets (NO1/NO3) reach the continent only through NO2, and
every Norwegian-internal border is a dropped flow-based residual
(`flow_based_drop_borders`), so their only non-hydro supply is the clamped
observed import-only flow. In the spring-drawdown weeks (reservoir at its
seasonal low before the snowmelt refill) the dryness-rationed hydro-quantity
heuristic tightens the book until the coupled clear sits at supply ≈ demand on a
phantom-scarcity knife-edge and tips to the price cap — a genuine, reproducible
instability (NO1 May-2026 base flips €91↔€2045 on adjacent days for the same
water outturn ≈ €110; the frozen cv22 Postgres record and the live extract cap on
different May days for the same reason). The ex-ante import backstop restores the
zone's demonstrated tail-day import capability as elastic supply above the
tranches (the identical cv17 fix DK1/DK2/CH/AT/SI carry), de-risking the
knife-edge: measured A/B NO1 MAE 340→73, bias +298→+30; NO3 MAE 314→46, corr
0.16→0.48; dry-spring NO1 MAE 883→162; ALL other zones byte-identical (the
backstop is priced above every tranche, so it is inert on non-tail hours).

**Deliberately does NOT touch the anchor.** Two re-anchoring attempts (blunt
`anchor_include_dropped`, and a gateway anchor to NO2) were built and measured
NEGATIVE — anchoring the hydro OFFER is not the same as transplanting NO2's
clearing price, and the gas-SRMC water-value clamp only lets re-anchoring push
the genuinely-scarce winter further down (NO1 winter bias −55→−102). So the
backstop ships alone and the full-year NO1 corr≈0 (seasonal level inversion +
gas-SRMC ceiling) stays an open problem with a specified mechanism/data gap
(DIAGNOSIS.md §7). NO2 (the gateway, fits well), NO4 (isolated) and NO5 (measured
worse under any treatment) stay on their own profiles. Gated by
`EUPHEMIA_DISABLE_CV23` (byte-identity guard).
"""
const NORWAY_ANCHORED_PROFILE = with_profile(NORWAY_PROFILE; import_backstop = true)

"Interior-Norway zones carrying the cv23 import-backstop treatment (kill-switch scope)."
const CV23_NO_ZONES = Set(["NO1", "NO3"])

"""
Mid/south Sweden (SE3/SE4). Same structural object as southern Norway once
their flow-based-residual borders are dropped (iter5: SE2–SE3, SE3–SE4 in
`flow_based_drop_borders`): the drop cured the +128/+147 continental-scarcity
bias (MAE −99/−103) but reproduced NO1's iteration-2 failure mode — the €1
observed-import block became price-setting (SE3 sim €1–9.5 all day vs actual
€15–70, corr 0.51→−0.25). The `:hydro` opportunity anchor is the built cure:
dropped-border imports price at the border price (`share × ref`), water value
clamps to the coupled reference, and dropped-border exports re-enter as
ref-priced demand. Anchor refs come from the remaining endogenous neighbors —
DK1 for SE3, DK2/LT for SE4 — all well-calibrated after the SE drop.
"""

"""
Switzerland. Hydro-storage dominated (large reservoir + pumped fleet, thin
thermal) but was on CONTINENTAL_PROFILE, so its storage was priced
gas-anchored (~€119 base with scarcity markup) — measured cal8 residual +28
to +78 in EVERY hour, worst at peaks and in RES-surplus midday where the
actual price collapses to ~0 but the sim stays ~47. Same structural object
as Norway: storage prices at the export opportunity. NORDIC-style
reservoir-opportunity hydro plus the two-pass :hydro anchor; CH's neighbors
(DE_LU, FR, IT-NORTH) are all endogenous and well-calibrated, so the anchor
ref is the border-capacity-weighted mean of their pass-1 prices. Swiss
reservoir filling data exists in entsoe.aggregated_hydro_storage_filling_rate
(590 weekly rows, current), so dryness is real, not a proxy.

SHARED WITH AUSTRIA (iteration 4). AT is also alpine-hydro dominated (~60%
reservoir + run-of-river + pumped) and sits on the AT–CH border, so when CH
alone carried the :hydro anchor (iter3 cal10) the anchored CH book propagated a
shape regression into AT (corr 0.77→0.57). The iteration-4 fix is to roll CH
and AT out TOGETHER on the same reservoir-opportunity :hydro anchor — AT's
storage prices at the same coupled continental opportunity cost, so the two
alpine zones are anchored consistently in the same pass instead of one dragging
the other. Measured cumulatively on the HU-drop baseline (cal12→cal13):
CH corr 0.82→0.86 / MAE 40→27 / bias +39→+10; AT held at corr 0.85 with bias
improved (see docs/eu-calibration-iter4.md). Swiss/Austrian reservoir filling
data exists in entsoe.aggregated_hydro_storage_filling_rate (weekly BZN rows).
"""
const SWISS_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    opportunity_anchor = :hydro,
    # cv17: CH starves episodically (FR→CH holiday auction gaps, e.g. the
    # 2025-01-01 DE_Amprion zero-offer day), not chronically — no border drop
    # is justified; the ex-ante backstop covers the tail days. Measured
    # (28-day benchmark): corr 0.11 → 0.74, MAE 49.9 → 24.1.
    import_backstop = true,
)

"""
Austria. Same alpine reservoir-opportunity + `:hydro` anchor as CH (the iter4
joint rollout), but with its own `anchor_share` (iter5): measured on
2026-04-01..05, CH's actual level sits AT its coupled reference (share 0.9 →
bias −2.3, near-perfect) while AT's actual (≈€100) trades ~€19 ABOVE its
coupled neighbors (DE_LU ≈€81) — a Core-FBMC premium the capacity-weighted ref
cannot see. At the shared share 0.9 AT under-priced (bias −17.9) and its
too-cheap hydro exports dragged IT-NORTH (−9.0) and SK (−11.0) negative — the
iter4 "alpine-cheapening spillover". From the measured share→bias point
(0.9 → −17.9 at sim ≈ 82), share 1.1 puts the AT hydro bid base at its
observed premium — a calibrated bidding position like FRANCE_PROFILE's 0.55
in the other direction. The water value stays clamped at gas SRMC, so a
share > 1 cannot manufacture scarcity.
"""
const AUSTRIA_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    opportunity_anchor = :hydro,
    # iter8 re-tune attempt, measured and REJECTED: with the installed-fleet
    # fix the coupled DE ref dropped to its true level and AT under-prices
    # (bias −13.5); raising the share 1.1 → 1.25 moved AT only −0.4 MAE /
    # +0.6 bias — the water value clamps at gas SRMC, so the share is no
    # longer the binding lever under the corrected ref. AT's residual is
    # shape (corr), queued for iteration 9; the share stays at its iter5
    # calibration.
    anchor_share = 1.1,
    # cv17: AT's remaining Core import borders (CZ–AT, DE_LU–AT) carry the
    # chronic flow-based-residual ATC (p10 = 0 vs 1.6–2.0 GW physical) and are
    # now DROPPED (see flow_based_drop_borders); the backstop covers the
    # residual tail days beyond the restored climatology injection. Measured
    # (28-day production benchmark): corr 0.17 → 0.77, MAE 85.3 → 28.3.
    # The backstop scarcity credit was measured here and NOT adopted (moved
    # no target metric; cost SK/SE4 ~0.05 corr via their anchor refs).
    import_backstop = true,
)

"""
Belgium. Continental thermal zone whose Core-FBMC borders are dropped
(iter5: BE–FR/NL/DE_LU in `flow_based_drop_borders` — import ATCs collapse to
0–350 MW mid-morning while physical flows carry 1.4–1.9 GW). The drop alone
(cal17) flipped BE from +46.5 starved-overpricing to −35 (the €1
observed-import block price-setting in import-covered hours — the NO1/SE3
failure mode). The `:hydro` opportunity anchor supplies the pricing half of
the treatment: dropped-border imports at the border price (`share × ref`,
ref = DE_LU/NL continental proxy since BE has no endogenous neighbors left;
GB is outside the footprint), dropped-border exports as ref-priced demand.
BE's actual mean (≈€77) sits at ~0.9× the proxy — the default share. The
hydro side of the anchor touches only BE's small pumped fleet (ref-priced
storage — if anything more honest than gas-anchored).
"""
const BELGIUM_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    opportunity_anchor = :hydro,
    # cv17: BE's tail-day import starvation (actual imports +2.1 GW over the
    # climatology on its spike hours) is covered by the ex-ante backstop.
    # Measured (28-day benchmark): corr 0.22 → 0.85, MAE 63.5 → 21.0. The
    # retained BE–GB border's observed exports re-price at the anchor
    # reference in pass 2 instead of firm cap-priced demand.
    import_backstop = true,
    ref_priced_exports = true,
)

"""
Slovakia (iter6). Core FBMC transit hub whose import borders' implicit offered
ATC are flow-based residuals (CZ→SK / PL→SK avg ~90 MW vs ~3 GW physical), so
the endogenous model starved SK's thin fleet (4.15 GW vs 4.37 GW peak) into
winter cap-clearing (sim €313 vs actual €118, bias +195 on the iter6 sample).
The paired treatment (see `flow_based_drop_borders`): CZ–SK and PL–SK are
dropped, restoring the real import supply as observed import-only flows, and
the `:hydro` opportunity anchor prices those imports at the coupled Core
reference (pass-1 CZ/PL/DE_LU proxy) rather than the €1 price-taker block —
which would invert SK to a deep negative bias (the NO1/BE/SE3 failure mode
seen three times when a border was dropped without re-pricing its flows).
Continental scarcity temperament otherwise; the water value clamp keeps the
anchor from manufacturing scarcity.
"""
const SLOVAKIA_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    opportunity_anchor = :hydro,
)

"""
Slovenia (cv17). Core-FBMC member whose AT import border carries the same
chronic flow-based-residual "offered ATC" documented and dropped for
HU (iter3), BE (iter5), SK (iter6) and now AT: AT→SI averages ~150 MW with
p10 = 0 while the physical flow carries ~1.3 GW — SI capped on 47/730 days of
the cv16 baseline, the worst phantom-scarcity zone in the footprint. The
Slovakia treatment: AT–SI dropped (`flow_based_drop_borders`), continental
scarcity temperament, and the `:hydro` opportunity anchor so the restored
imports price at the coupled Core reference instead of the €1 price-taker
block. Attribution-measured (weak-zone diagnosis v3): the drop is strictly
necessary — backstop-only leaves SI at corr 0.33 vs 0.70 with the drop.
Also carries the import backstop for residual tail days, and ref-priced
retained-border exports: SI's ~1 GW HR export outlet entered as firm demand
AT THE CAP, forcing the model to serve it at any price on tight days where a
real exporter would curtail (§2c of the diagnosis).
"""
const SLOVENIA_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    opportunity_anchor = :hydro,
    import_backstop = true,
    ref_priced_exports = true,
)

"""
Denmark (DK1/DK2, cv17). Plain NORDIC plus the ex-ante import backstop: their
starvation is EPISODIC (DE_LU→DK1 offered ATC averages ~2.5 GW but collapses
to ~295 MW exactly on tight hours; SE4→DK2 9 MW vs 698 MW physical on spike
hours), so a blanket border drop is not justified — the tail-day backstop is.
Measured (28-day benchmark): DK1 corr 0.11 → 0.75 / MAE 71.8 → 28.8,
DK2 0.32 → 0.76 / 82.6 → 29.4.
"""
const DENMARK_PROFILE = with_profile(NORDIC_PROFILE; import_backstop = true)

"""
DK1 (cv21). DENMARK_PROFILE plus the Viking-Link (DK1–GB) boundary book: GB is
modeled as its own CCGT-marginal counterparty on that single border (elastic
import supply + export demand replacing GB's fixed flow injection and its
backstop headroom — see `VIKING_GB_BOOK`). Confirm 2026-07-24: July MAE
31.5→28.3 / corr 0.90→0.93, March MAE 27.6→25.2 / corr 0.55→0.80, no FR/NL/NO2
leakage (docs/experiments/cv21-dk1-viking.md). DK2 stays on plain
DENMARK_PROFILE — its GB link (no Viking equivalent) is not treated.
"""
const DK1_PROFILE = with_profile(DENMARK_PROFILE; boundary_book = VIKING_GB_BOOK)

"""
SE3 (cv17). SWEDEN_SOUTH (anchored Nordic hydro) plus two cv17 mechanisms:
the import backstop (spike-hour imports ran +1.9 GW over climatology), and —
its structural fix — `anchor_include_dropped`: SE3's anchor reference was the
capacity-weighted price of its ENDOGENOUS neighbors, essentially only DK1
(~0.3 GW border, €82 night) after the iter5 drops, while its real marginal
supply is Norrland hydro over the dropped SE2–SE3 cut (~5 GW observed).
Including dropped in-footprint borders climatology-flow-weighted makes the
ref SE2-dominated, pulling SE3's level/shape toward its actual position
between SE2 and DK1. SE4 deliberately stays on plain SWEDEN_SOUTH (its
existing refs are already decent; measured as a gate on the benchmark).
"""
# anchor_include_dropped was measured and GATED OUT (28-day production
# benchmark): the SE2-dominated ref (~5 GW climatology weight vs DK1's ~0.3 GW
# ATC) pinned SE3 at SE2's level — bias flipped +13 → −24 and corr fell
# 0.55 → 0.31 vs the backstop-only configuration. It was OFF in every zone, so
# cv25's subtraction phase removed the field and the branch it fed; a tempered
# re-try is a re-implementation, not a flag flip. SE3's night-shape problem
# remains open.
const SE3_PROFILE = with_profile(NORWAY_PROFILE; import_backstop = true)

"""
IT-CNORTH (cv17). ITALY plus the import backstop: episodic
IT-CSOUTH→IT-CNORTH offered-ATC dips (95 MW offered vs 1.2 GW physical on
spike hours; avg ~3 GW) starve it a few days a year — backstop, not drop.
"""
const ITALY_CNORTH_PROFILE = with_profile(ITALY_PROFILE; import_backstop = true)

"""
SEE base + import backstop + full scarcity credit (cv17). SEE calibration (exact v10 parameters)
plus the ex-ante import backstop AND the backstop scarcity credit. RO is the
measured case for why the backstop must stay on in SEE's east: the June-2026
tight period (one Cernavoda unit partial, wind at 45% of 2025) was covered in
reality by BG/HU/UA imports above climatology — the model capped every day of
2026-06-15..30 while actuals stayed at €200–290. The full scarcity credit
(`backstop_scarcity_credit = 1.0`, same fundamentals as the iter6
`scarcity_import_credit`: demonstrated import capability means the zone is
not domestically scarce) addresses the measured residual overpricing of the
SEE cold-snap coupled block — with the backstop supply alone the cluster
still cleared €517–591 vs actual ~€380 because the scarcity MARKUP could not
see the restored imports; the credit only acts when the margin is below the
scarcity threshold, so normal hours are untouched. HU's membership was the
documented open calibration decision (P2 measured its bias drifting
−14.6 → −28.8 with an uncredited backstop): the production benchmark shows
HU's missing backstop left the coupled SEE cluster capping through the
2026-01 cold snap, and the credit is the mechanism P2 lacked — HU carries
both. This profile applies ONLY on the EU-footprint path
(`enrich_network=true`); the legacy SEE single-zone and 5-zone products force
SEE_PROFILE and remain byte-identical.
"""
const SEE_IMPORT_BACKED_PROFILE = with_profile(SEE_PROFILE;
    import_backstop = true, backstop_scarcity_credit = 1.0)

"""
Baltic (EE/LT/LV). Tightly coupled to the Nordic hydro system and thermally
thin; softened scarcity like the continental core. Left close to SEE otherwise —
their residual error is expected to shrink once the Nordic zones are corrected.
"""
const BALTIC_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    # iter6: EE/LT/LV are import-dependent (thin domestic thermal riding the
    # Nordic system via Estlink/NordBalt); the scarcity margin ignored those
    # imports and priced +78-87. Credit available import ATC.
    scarcity_import_credit = 1.0,
    # iter7: true active types to registry installed capacity (LT's Kruonis
    # pumped storage is 900 MW installed but only 450 MW unit-listed / 349
    # 30d-p95; EE oil shale 1,330 installed vs 1,060 listed).
    fleet_truth_mode = :installed,
)

"""
    ZONE_PROFILES

Registry mapping bidding-zone code → `ZoneProfile`. Zones absent from the
registry fall back to `SEE_PROFILE` via `get_zone_profile`, so the default is
always the validated SEE calibration.
"""
const ZONE_PROFILES = Dict{String,ZoneProfile}(
    # SEE core. GR/BG stay on the exact v10 SEE calibration; RO/RS/HU add the
    # cv17 import backstop + full scarcity credit (EU-footprint only — the
    # single-zone / 5-zone SEE products force SEE_PROFILE and stay
    # byte-identical). HU's membership was the documented calibration
    # decision: the production benchmark showed the coupled SEE cold-snap
    # cluster keeps capping without HU's backstop, and the scarcity credit is
    # the mechanism the P2 bias-drift caution lacked. SI moves to the
    # Slovakia treatment (cv17): AT–SI drop + :hydro anchor + backstop.
    # RO/HU add the cv22 UA firm-slice boundary book on top of their cv17
    # backstop (UA is excluded from injections + backstop headroom by the book).
    "GR" => SEE_PROFILE, "BG" => SEE_PROFILE,
    "RO" => with_profile(SEE_IMPORT_BACKED_PROFILE; boundary_book = UA_BOOK_DEFAULT),
    "RS" => SEE_IMPORT_BACKED_PROFILE,
    "HU" => with_profile(SEE_IMPORT_BACKED_PROFILE; boundary_book = UA_BOOK_DEFAULT),
    "SI" => SLOVENIA_PROFILE,
    # Iberia
    "ES" => SEE_PROFILE, "PT" => SEE_PROFILE,
    # Italy sub-zones (IT-CNORTH: + cv17 import backstop). cv18: the mainland
    # zones + Sicily add the per-unit SRMC spread (±10% — measured prototype
    # corr 0.31→0.68 CSOUTH / 0.75→0.82 NORTH / 0.49→0.72 Sicily, plateau
    # ±8–12%); Sardinia is the measured exception (spread WORSENED it 7/20 —
    # island/SAPEI import mix) and stays on the plain profile.
    # cv18 ACTIVATION HELD BACK: the 36-day attribution showed the two levers
    # interact strongly and non-locally through the coupled footprint (DK1
    # ladder: NO1 caps 15→0 but IT-CSOUTH 0.66→0.39 and SE3 0.56→0.10; spread:
    # benign continentally but NO1 caps 15→44). The 20-day/2-zone pilot gates
    # are structurally insufficient for coupled mechanisms — activation waits
    # for the border-scoped redesign (export backstop mirror) validated on the
    # coupled footprint. The fields and their kill-switch were removed in cv25's
    # subtraction phase — git holds the implementation if the redesign revives them.
    "IT-NORTH" => ITALY_PROFILE, "IT-CNORTH" => ITALY_CNORTH_PROFILE,
    "IT-CSOUTH" => ITALY_PROFILE, "IT-SOUTH" => ITALY_PROFILE,
    "IT-Calabria" => ITALY_PROFILE, "IT-Sicily" => ITALY_PROFILE,
    "IT-Sardinia" => ITALY_PROFILE,
    # Norway — NO2 is the export gateway (direct DE/NL/DK cables), fits well on
    # plain NORWAY_PROFILE. NO1/NO3 are interior hydro pockets behind NO2: cv23
    # gives them the ex-ante import backstop (NORWAY_ANCHORED_PROFILE,
    # docs/experiments/norwegian-hydro) to de-risk their spring-drawdown
    # phantom-cap knife-edge. NO5 measured WORSE under any treatment and stays
    # plain; NO4 (far north, congestion-isolated) stays plain NORDIC.
    "NO1" => NORWAY_ANCHORED_PROFILE, "NO2" => NORWAY_PROFILE,
    "NO3" => NORWAY_ANCHORED_PROFILE,
    "NO4" => NO4_PROFILE, "NO5" => NORWAY_PROFILE,
    "SE1" => NORDIC_PROFILE, "SE2" => NORDIC_PROFILE,
    # SE3/SE4: anchored after the iter5 SE2–SE3/SE3–SE4 border drop (see
    # NORWAY_PROFILE docstring); SE3 adds the cv17 backstop + the
    # dropped-border (SE2-weighted) anchor ref
    "SE3" => SE3_PROFILE, "SE4" => NORWAY_PROFILE,
    "FI" => NORDIC_PROFILE,
    # DK1/DK2: + cv17 import backstop (episodic starvation — see DENMARK_PROFILE).
    # cv18: DK1 adds the export-absorption ladder (prototype corr 0.495→0.569,
    # MAE −2.0, binds only in RES-surplus hours). DK2 unchanged pending its own A/B.
    # DK1 adds the cv21 Viking-Link (DK1–GB) boundary book; DK2 stays plain.
    "DK1" => DK1_PROFILE, "DK2" => DENMARK_PROFILE,
    # Baltic
    "EE" => BALTIC_PROFILE, "LT" => BALTIC_PROFILE, "LV" => BALTIC_PROFILE,
    # France (nuclear-heavy: continental scarcity + availability-scaled nuclear
    # opportunity cost). cv23: + the FR↔GB boundary book (double-count fix paired
    # with the honest GB premium — see FR_PROFILE / GB_FR_BOOK). Both cv23
    # mechanisms gated by EUPHEMIA_DISABLE_CV23.
    "FR" => FR_PROFILE,
    # Alpine hydro (CH + AT): reservoir-opportunity + :hydro anchor, rolled out
    # together (iter4) so the AT–CH border is anchored consistently; AT carries
    # its own anchor_share for the Core-FBMC premium (iter5)
    "CH" => SWISS_PROFILE, "AT" => AUSTRIA_PROFILE,
    # Continental core
    "DE_LU" => CONTINENTAL_PROFILE,
    # BE: dropped Core borders + :hydro anchor for import pricing (iter5)
    "BE" => BELGIUM_PROFILE, "NL" => CONTINENTAL_PROFILE,
    # PL/SK carry the cv22 UA firm-slice boundary book (PL adds the UA_DobTPP
    # radial to its flow codes); CZ/DE_LU/NL stay on plain CONTINENTAL.
    "PL" => with_profile(CONTINENTAL_PROFILE; boundary_book = UA_BOOK_PL),
    "CZ" => CONTINENTAL_PROFILE,
    # SK: dropped Core import borders (CZ–SK, PL–SK) + :hydro anchor for import
    # pricing (iter6) — the HU treatment applied to SK's own residual borders
    "SK" => with_profile(SLOVAKIA_PROFILE; boundary_book = UA_BOOK_DEFAULT),
)

"""
    get_zone_profile(zone) -> ZoneProfile

Profile for a zone, defaulting to `SEE_PROFILE` for any zone not in the registry.
"""
function get_zone_profile(zone::AbstractString)
    p = get(ZONE_PROFILES, String(zone), SEE_PROFILE)
    # cv23 interior-Norway kill-switch (byte-identity guard + attribution A/Bs):
    # revert the cv23 import_backstop on ONLY the cv23 NO zones, so a disabled
    # run is byte-identical to cv22 while other zones' own import_backstop
    # (SE3/DK1/DK2/CH/AT/SI/RO/RS/HU/IT-CNORTH) is untouched. Travels via ENV for
    # the same worker-safety reason as the other kill-switches.
    if String(zone) in CV23_NO_ZONES &&
       !isempty(get(ENV, "EUPHEMIA_DISABLE_CV23", ""))
        p = with_profile(p; import_backstop = false)
    end
    # Boundary-book kill-switch (byte-identity guard + attribution A/Bs): each
    # book names the env var that strips it (`disable_env`) — Viking →
    # EUPHEMIA_DISABLE_CV21, the UA books → EUPHEMIA_DISABLE_CV22 — so each cv's
    # guard disables exactly its own books (the cv22 guard leaves Viking ON,
    # matching cv21 main). Travels via ENV for the same worker-safety reason as
    # the other switches: any non-empty value disables.
    if p.boundary_book !== nothing &&
       !isempty(get(ENV, p.boundary_book.disable_env, ""))
        p = with_profile(p; boundary_book=nothing)
    end
    # cv23 kill-switch (byte-identity guard + attribution A/Bs). A non-empty
    # EUPHEMIA_DISABLE_CV23 strips BOTH cv23 mechanisms so the EU book reverts
    # exactly to cv22 main: (1) the availability-scaled nuclear share reverts to
    # the fixed anchor_share (share_hi=0 ⇒ OFF), and (2) the FR↔GB boundary book
    # is stripped (its disable_env is also EUPHEMIA_DISABLE_CV23, handled above).
    # Worker-safe via ENV like the other switches.
    if !isempty(get(ENV, "EUPHEMIA_DISABLE_CV23", "")) && p.nuclear_avail_share_hi > 0.0
        p = with_profile(p; nuclear_avail_share_lo=0.0, nuclear_avail_share_hi=0.0)
    end
    # cv23 FR-cap fix kill-switch (byte-identity guard + attribution A/Bs). A
    # non-empty EUPHEMIA_DISABLE_FRCAP strips the FR import backstop added by the
    # cap fix, reverting FR to the cv23-merged no-backstop profile (so the guard
    # shows FR-without-the-fix == cv23 main, and non-FR zones are untouched).
    # Scoped to FR by name: FR is the only zone whose backstop is the cap fix —
    # every other backstop zone (AT/BE/CH/DK/SI/RO/RS/HU) predates cv23 and must
    # NOT be disabled here. Worker-safe via ENV.
    # EUPHEMIA_DISABLE_CV23 also strips it: the cv23 comment above claims the
    # switch "reverts exactly to cv22 main", but the FR-cap half of cv23 (the
    # interior-Norway/FR import backstop, backstop_scarcity_credit and
    # nuclear_bid_ref_ceiling added to FR_PROFILE by the same version) was
    # reachable only through DISABLE_FRCAP. A cv23-off A/B or byte-identity
    # guard therefore left FR carrying a backstop cv22-FR never had, so every
    # conclusion drawn from that guard compared the wrong pair. Either switch
    # now strips it; DISABLE_FRCAP alone still strips ONLY the cap fix.
    if String(zone) == "FR" && (p.import_backstop || p.nuclear_bid_ref_ceiling > 0.0) &&
       (!isempty(get(ENV, "EUPHEMIA_DISABLE_FRCAP", "")) ||
        !isempty(get(ENV, "EUPHEMIA_DISABLE_CV23", "")))
        p = with_profile(p; import_backstop=false, backstop_scarcity_credit=0.0,
                         nuclear_bid_ref_ceiling=0.0)
    end
    return p
end

# =============================================================================
# ZONE SCENARIO — counterfactual hooks bundled per zone
# =============================================================================
"""
    ZoneScenario

Bundles the counterfactual hooks that `create_merit_order_book` accepts into one
named value, so a scenario can be attached to a zone on the multi-zone path
(`run_multi_zone_market_clearing(...; scenario=...)`) exactly as the loose
kwargs attach on the single-zone `generate_energy_prices` path.

All fields default to `nothing`; an all-`nothing` scenario is a no-op and the
built book is byte-identical to the no-scenario book (regression-guarded).

Fields (see `create_merit_order_book`'s "Scenario hooks" docstring for the exact
`ctx` shapes):
- `load_modifier(timeslot, load_mw) -> Float64`     — reshape demand at source
- `renewable_modifier(timeslot, mw) -> Float64`     — reshape RES at source
- `extra_orders(ctx) -> Vector{SimpleOrder}`        — add supply/demand orders
- `strategist(ctx) -> Vector{Tuple{SimpleOrder,String}}` — replace the tagged book
- `fleet_modifier(zone, gens::Vector{Generator}) -> Vector{Generator}` — add /
  remove / derate physical units. Runs AFTER fleet completion/truthing (see the
  `fleet_modifier` note in `create_merit_order_book`), so a removed unit is not
  silently re-added by the `:installed`/p95 truth-up.
- `load_fill(zone, day::Date) -> Union{Nothing,Dict{String,Float64}}` — SEED the
  zone's load series (timeslot `"yyyymmdd-HHMM"` → MW) when the TSO day-ahead
  load is absent. Used by the daily-forecast eligibility fill
  (`bin/daily_forecast.jl`): a returned non-empty dict REPLACES the DB load for
  that zone/day; `nothing` (default) leaves the DB load untouched (byte-identical).
  Unlike `load_modifier` (which only reshapes existing entries), this can provide
  load for a zone the TSO never published — the whole point of the fill.
- `res_fill(zone, day::Date) -> Union{Nothing,Dict{String,Float64}}` — the RES
  twin of `load_fill`: MERGE weather-model wind+solar (timeslot `"yyyymmdd-HHMM"`
  → MW) into the zone's renewable forecast for the hours the TSO 14.1.D forecast
  did NOT publish. A present TSO RES hour is never overridden; `nothing` (default)
  leaves the DB RES untouched (byte-identical). Used by the daily-forecast RES
  eligibility fill (`bin/daily_forecast.jl`).

The `extra_orders` and `strategist` `ctx` both carry `ctx.zone`, so a single
scenario object applied to a whole footprint can gate its edits on the zone
(one function serving many zones); `load_modifier`/`renewable_modifier` reshape
whatever zone they are attached to. To target specific zones with distinct
edits, pass a `Dict{String,ZoneScenario}` — each zone gets its own scenario.
"""
Base.@kwdef struct ZoneScenario
    load_modifier::Union{Nothing,Function} = nothing
    renewable_modifier::Union{Nothing,Function} = nothing
    extra_orders::Union{Nothing,Function} = nothing
    strategist::Union{Nothing,Function} = nothing
    fleet_modifier::Union{Nothing,Function} = nothing
    load_fill::Union{Nothing,Function} = nothing
    res_fill::Union{Nothing,Function} = nothing
end

"""
    is_empty_scenario(s) -> Bool

`true` when `s` is `nothing` or a `ZoneScenario` with every hook `nothing`
(so the no-scenario code path is byte-identical). A `Dict` scenario is never
"empty" here — emptiness is resolved per zone by `zone_scenario`.
"""
is_empty_scenario(::Nothing) = true
is_empty_scenario(s::ZoneScenario) =
    s.load_modifier === nothing && s.renewable_modifier === nothing &&
    s.extra_orders === nothing && s.strategist === nothing &&
    s.fleet_modifier === nothing && s.load_fill === nothing && s.res_fill === nothing

"""
    zone_scenario(scenario, zone) -> Union{Nothing,ZoneScenario}

Resolve the `ZoneScenario` that applies to `zone`:
- `nothing`                 → `nothing` (no scenario anywhere),
- a single `ZoneScenario`   → the same scenario for EVERY zone (hooks gate on
  `ctx.zone` themselves),
- a `Dict{String,ZoneScenario}` → `get(dict, zone, nothing)` (per-zone targeting).
An all-`nothing` `ZoneScenario` resolves to `nothing` so the byte-identical
no-scenario path is taken.
"""
zone_scenario(::Nothing, ::AbstractString) = nothing
function zone_scenario(s::ZoneScenario, ::AbstractString)
    return is_empty_scenario(s) ? nothing : s
end
function zone_scenario(d::Dict{String,ZoneScenario}, zone::AbstractString)
    s = get(d, String(zone), nothing)
    return (s === nothing || is_empty_scenario(s)) ? nothing : s
end

