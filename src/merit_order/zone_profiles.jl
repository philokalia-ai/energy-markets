# zone_profiles.jl — ZoneProfile struct + every zone profile constant + ZONE_PROFILES registry + ZoneScenario hooks.
# Included by ../MeritOrderBook.jl inside `module MeritOrderBook` (definition order preserved).

const WATER_VALUE_FUEL_TYPES =
    [Symbol("Hydro Water Reservoir"), Symbol("Hydro Pumped Storage")]

"""
    _unit_hash01(code) -> Float64 in [0, 1)

Deterministic per-unit draw for `unit_srmc_spread` (FNV-1a over the code's
bytes). Stable across sessions, processes and Julia versions — Base.hash is
not guaranteed stable across versions, and reproducibility of the priced book
is a hard requirement (same day + same code ⇒ bit-identical prices).
"""
function _unit_hash01(code::AbstractString)
    h = 0xcbf29ce484222325
    for b in codeunits(code)
        h = (h ⊻ UInt64(b)) * 0x00000100000001b3
    end
    return (h % UInt64(1000)) / 1000.0
end

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
"""
Base.@kwdef struct BoundaryBook
    counterparty::String
    flow_codes::Vector{String}
    anchor::Symbol
    anchor_mult::Float64 = 1.0
    imp_ladder::Vector{Tuple{Float64,Float64}}
    exp_ladder::Vector{Tuple{Float64,Float64}}
end

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
    # Per-unit SRMC spread (cv18): decorrelate thermal unit costs by a stable
    # per-unit factor 1 ± spread (deterministic FNV-1a hash of the unit code —
    # to be replaced by inferred heat rates once history supports them).
    # Without it every unit of a fuel type shares one type-level SRMC, so all
    # their same-multiplier tranches align into ONE flat multi-GW step and the
    # marginal price cannot move intraday — the measured cause of the flat
    # Italian zones (docs/experiments/it-flatline-diagnosis.md: every hour of
    # the probe day pinned at 90.90 by four units priced identically; ±8%
    # prototype corr 0.31→0.68 CSOUTH, 0.75→0.82 NORTH, 0.49→0.72 Sicily;
    # Sardinia the measured exception). 0 = off (byte-identical).
    unit_srmc_spread::Float64 = 0.0
    # Export-absorption ladder (cv18): elastic demand steps (price €/MWh, MW)
    # appended every timeslot — export/flexibility absorption of RES-surplus
    # generation below the thermal band. Without it a wind-heavy zone's price
    # stays pinned at the thermal marginal in surplus hours (DK1: prototype
    # 30/15/5 € × 400 MW → corr 0.495→0.569, MAE −2.0, binding only on
    # surplus days). Empty = off (byte-identical).
    export_absorption_steps::Vector{Tuple{Float64,Float64}} = Tuple{Float64,Float64}[]
    hydro_model::Symbol = :gas_anchored
    nuclear_srmc_floor::Float64 = 0.0
    opportunity_anchor::Symbol = :none
    anchor_share::Float64 = 0.9
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
    backstop_weeks::Int = 8
    backstop_price_mult::Float64 = 1.8
    # Fraction of the hourly backstop quantity credited into the scarcity
    # margin (the backstop analogue of `scarcity_import_credit`): the scarcity
    # MARKUP otherwise cannot see the backstop supply, so restored-import days
    # can keep a residual markup overshoot. 0 = off (default).
    backstop_scarcity_credit::Float64 = 0.0
    # Two-pass anchor refs over DROPPED borders: include dropped in-footprint
    # borders in the opportunity-anchor reference, weighted by observed
    # climatology import flow. SE3's case: its real marginal supplier is
    # Norrland hydro over the dropped SE2–SE3 cut (~5 GW observed) while the
    # endogenous ref saw only DK1's ~0.3 GW border, pinning SE3 to DK1's
    # night price. Off by default.
    anchor_include_dropped::Bool = false
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
const SWEDEN_SOUTH_PROFILE = NORWAY_PROFILE

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
const SE3_PROFILE = with_profile(SWEDEN_SOUTH_PROFILE;
    import_backstop = true,
    # anchor_include_dropped measured and GATED OUT (28-day production
    # benchmark): the SE2-dominated ref (~5 GW climatology weight vs DK1's
    # ~0.3 GW ATC) pinned SE3 at SE2's level — bias flipped +13 → −24 and
    # corr fell 0.55 → 0.31 vs the backstop-only configuration. The
    # mechanism stays available on the profile for future calibration
    # (e.g. a tempered weight); SE3's §4b night-shape problem remains open.
    anchor_include_dropped = false)

"""
IT-CNORTH (cv17). ITALY plus the import backstop: episodic
IT-CSOUTH→IT-CNORTH offered-ATC dips (95 MW offered vs 1.2 GW physical on
spike hours; avg ~3 GW) starve it a few days a year — backstop, not drop.
"""
const ITALY_CNORTH_PROFILE = with_profile(ITALY_PROFILE; import_backstop = true)

"""
Romania / Serbia / Hungary (cv17). SEE calibration (exact v10 parameters)
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
both. These profiles apply ONLY on the EU-footprint path
(`enrich_network=true`); the legacy SEE single-zone and 5-zone products force
SEE_PROFILE and remain byte-identical.
"""
const ROMANIA_PROFILE = with_profile(SEE_PROFILE;
    import_backstop = true, backstop_scarcity_credit = 1.0)
const SERBIA_PROFILE = with_profile(SEE_PROFILE;
    import_backstop = true, backstop_scarcity_credit = 1.0)
const HUNGARY_PROFILE = with_profile(SEE_PROFILE;
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
    "GR" => SEE_PROFILE, "BG" => SEE_PROFILE, "RO" => ROMANIA_PROFILE,
    "RS" => SERBIA_PROFILE, "HU" => HUNGARY_PROFILE, "SI" => SLOVENIA_PROFILE,
    # Iberia
    "ES" => IBERIA_PROFILE, "PT" => IBERIA_PROFILE,
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
    # coupled footprint. Fields + EUPHEMIA_DISABLE_CV18 infrastructure stay.
    "IT-NORTH" => ITALY_PROFILE, "IT-CNORTH" => ITALY_CNORTH_PROFILE,
    "IT-CSOUTH" => ITALY_PROFILE, "IT-SOUTH" => ITALY_PROFILE,
    "IT-Calabria" => ITALY_PROFILE, "IT-Sicily" => ITALY_PROFILE,
    "IT-Sardinia" => ITALY_PROFILE,
    # Norway — southern/mid zones carry the :hydro opportunity anchor;
    # NO4 (far north, not continentally coupled) stays plain NORDIC
    "NO1" => NORWAY_PROFILE, "NO2" => NORWAY_PROFILE, "NO3" => NORWAY_PROFILE,
    "NO4" => NO4_PROFILE, "NO5" => NORWAY_PROFILE,
    "SE1" => NORDIC_PROFILE, "SE2" => NORDIC_PROFILE,
    # SE3/SE4: anchored after the iter5 SE2–SE3/SE3–SE4 border drop (see
    # SWEDEN_SOUTH_PROFILE docstring); SE3 adds the cv17 backstop + the
    # dropped-border (SE2-weighted) anchor ref
    "SE3" => SE3_PROFILE, "SE4" => SWEDEN_SOUTH_PROFILE,
    "FI" => NORDIC_PROFILE,
    # DK1/DK2: + cv17 import backstop (episodic starvation — see DENMARK_PROFILE).
    # cv18: DK1 adds the export-absorption ladder (prototype corr 0.495→0.569,
    # MAE −2.0, binds only in RES-surplus hours). DK2 unchanged pending its own A/B.
    # DK1 adds the cv21 Viking-Link (DK1–GB) boundary book; DK2 stays plain.
    "DK1" => DK1_PROFILE, "DK2" => DENMARK_PROFILE,
    # Baltic
    "EE" => BALTIC_PROFILE, "LT" => BALTIC_PROFILE, "LV" => BALTIC_PROFILE,
    # France (nuclear-heavy: continental scarcity + nuclear bid position)
    "FR" => FRANCE_PROFILE,
    # Alpine hydro (CH + AT): reservoir-opportunity + :hydro anchor, rolled out
    # together (iter4) so the AT–CH border is anchored consistently; AT carries
    # its own anchor_share for the Core-FBMC premium (iter5)
    "CH" => SWISS_PROFILE, "AT" => AUSTRIA_PROFILE,
    # Continental core
    "DE_LU" => CONTINENTAL_PROFILE,
    # BE: dropped Core borders + :hydro anchor for import pricing (iter5)
    "BE" => BELGIUM_PROFILE, "NL" => CONTINENTAL_PROFILE,
    "PL" => CONTINENTAL_PROFILE, "CZ" => CONTINENTAL_PROFILE,
    # SK: dropped Core import borders (CZ–SK, PL–SK) + :hydro anchor for import
    # pricing (iter6) — the HU treatment applied to SK's own residual borders
    "SK" => SLOVAKIA_PROFILE,
)

"""
    get_zone_profile(zone) -> ZoneProfile

Profile for a zone, defaulting to `SEE_PROFILE` for any zone not in the registry.
"""
function get_zone_profile(zone::AbstractString)
    p = get(ZONE_PROFILES, String(zone), SEE_PROFILE)
    # Experiment-only lever kill-switch (attribution A/Bs): profile mutations
    # in the coordinator do NOT reach pipeline workers (fresh `using Euphemia`
    # rebuilds ZONE_PROFILES), so per-mechanism disabling must travel via ENV.
    # Unset in production; reads once per call, negligible cost.
    dis = get(ENV, "EUPHEMIA_DISABLE_CV18", "")
    if dis == "spread" && p.unit_srmc_spread > 0.0
        p = with_profile(p; unit_srmc_spread=0.0)
    elseif dis == "ladder" && !isempty(p.export_absorption_steps)
        p = with_profile(p; export_absorption_steps=Tuple{Float64,Float64}[])
    elseif dis == "all" && (p.unit_srmc_spread > 0.0 || !isempty(p.export_absorption_steps))
        p = with_profile(p; unit_srmc_spread=0.0,
                         export_absorption_steps=Tuple{Float64,Float64}[])
    end
    # cv21 boundary-book kill-switch (byte-identity guard + attribution A/Bs):
    # EUPHEMIA_DISABLE_CV21 strips the boundary book so the EU book with the
    # mechanism disabled is bit-identical to unmodified main. Travels via ENV
    # for the same worker-safety reason as EUPHEMIA_DISABLE_CV18. Any non-empty
    # value disables (there is one boundary book in cv21).
    if p.boundary_book !== nothing && !isempty(get(ENV, "EUPHEMIA_DISABLE_CV21", ""))
        p = with_profile(p; boundary_book=nothing)
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
    s.fleet_modifier === nothing

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

