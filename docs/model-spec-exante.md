# The ex-ante day-ahead price model — standalone specification

This is the fully **ex-ante** configuration: every input is available before the
day-ahead auction closes at D-1 noon, so the model is a genuine *forecast* of
tomorrow, not a reconstruction.

## What it is

A simulation of the European day-ahead electricity auction across 39 bidding
zones. For each zone it reconstructs the *rational competitive bid* of every
market participant from fundamentals, assembles the resulting order books, and
clears all zones simultaneously through a EUPHEMIA-style coupled auction (a
MILP with complementarity conditions and cross-border capacity constraints).
The output is the hourly clearing price per zone. No parameter is fitted to
observed prices — prices only ever enter as *validation*.

## Inputs (all D-1-legal)

| Input | Source | Used for |
|---|---|---|
| Day-ahead load forecast | ENTSO-E, published D-1 | Demand curves, scarcity margin |
| Day-ahead wind/solar forecast | ENTSO-E, published D-1 | RES supply, residual demand |
| Offered transfer capacity (implicit + explicit auctions) | ENTSO-E, ex-ante | Network constraints on ATC borders |
| Flow-based maximum bilateral exchanges + hub net positions | JAO Publication Tool, published 10:30 CET on D-1 | Network constraints on Core and Nordic borders, which have no day-ahead ATC at all (cv35) |
| Transmission-grid outage messages | ENTSO-E | Capping a border at the TSO's remaining capacity |
| Unit registry + installed capacity per type + outages | ENTSO-E | The fleet: who can produce, how much |
| Historical unit/type output (trailing windows) | ENTSO-E | Activity gates, commitment state, fleet truthing |
| Weekly reservoir filling levels | ENTSO-E | Hydro water value |
| TTF gas & EUA carbon closes (last trading day *before* the market day) | market data | Marginal costs |
| Cross-border **ex-ante flow rule** (EU-path default `:v3`, cv19+: per-border mean of the D-1-load-analogue median and the D-2 observed flow) | derived, strictly pre-auction | Injections on borders outside the coupled network |

## The strategy classes — who bids what

**1. Renewables — price-takers.** The zone's wind/solar forecast is offered at
€1. Support schemes make output insensitive to price.

**2. Thermal units — cost-based ladders with self-scheduling.** Each unit's
marginal cost = fuel (daily TTF for gas) / efficiency + carbon + O&M. A
lightweight commitment rule decides who is "on": the cheapest units whose
capacity covers the day's peak residual demand. Committed units
*self-schedule* their minimum load — the deepest 60% at 5% of cost (never shut
down), the rest at cost minus an absolute startup-amortization discount —
which is what lets midday prices collapse below thermal cost in
renewable-surplus hours. All remaining capacity bids a four-step ladder
(55/20/15/10% of capacity at 0.95/1.05/1.25/1.60 × cost), with the upper steps
multiplied by a **scarcity factor**
`1 + κ_s·max(0, θ − margin)² + κ_p·d̂⁴`
when the zone's capacity margin genuinely tightens and in predictable peak
hours. The fleet itself is *truthed*: registry capacity per technology is
cross-checked against what has recently been active — idle-but-real capacity
counts toward adequacy (activity-gated so phantom registry entries don't), and
paper capacity that demonstrably no longer runs is derated. Since cv36 the
upper ladder can be *graded* into a piecewise-linear curve where a zone's real
supply stack is smooth rather than stepped (the Italian zones).

**2b. Deep-solar hours — a price-taker floor (cv31).** On the continental solar
group (DE_LU, FR, PL, BE, CZ, CH), when the day-ahead solar share of forecast
load clears an ex-ante threshold, the RES block, run-of-river and the deepest
must-run block price at €−20 instead of near zero, so the coupled clear can
genuinely fall below zero as the real market does. The gate is ex-ante and
regime-scoped: outside the regime the model is unchanged.

**3. Hydro reservoirs and pumped storage — opportunity-cost bidding.** Water
is never bid at its (trivial) variable cost; it is bid at what it could earn
instead. Three regimes:
- *Gas-anchored* (thermal-dominated zones): water value tracks gas cost,
  shaped by the day's demand curve and boosted by dryness.
- *Reservoir-opportunity* (hydro-dominated zones): water value is the shadow
  price of stored water — near-free with full reservoirs, rising toward the
  thermal alternative as they empty, with an absolute drawdown signal (stored
  vs trailing-year peak) so seasonal depletion prices in.
- *Export-anchored* (hydro exporters coupled to the continent): a first
  clearing pass produces coupled reference prices; stored water is then
  re-priced at a share of that reference (level *and* hourly shape) and the
  system re-clears. All anchor inputs are model-internal.

**4. Nuclear (France) — opportunity floor.** A modulating national fleet bids
its off-peak position at a share of the coupled reference, floored at fuel
cost — rising with the continent on winter nights, collapsing with it in
solar-surplus hours.

**5. Demand — near-inelastic.** ~98% of forecast load at the €3,000 cap, a 2%
elastic tail at €250.

**6. Borders.** Borders inside the footprint clear endogenously under their
capacity limit — offered ATC where the market really uses ATC, and since cv35
JAO's published flow-based maximum bilateral exchanges (scaled to each hub's
net-position range) on the Core and Nordic borders, which have no day-ahead ATC
at all. Borders to markets we do not model cannot emerge from the clear, so
they enter as data through the ex-ante flow rule `:v3`: the per-border mean of
the D-1-load-analogue median (the 16 trailing-year days whose D-1 load-forecast
vector is nearest the delivery day's) and the D-2 observed flow. Two neighbours
are instead modeled as elastic **boundary books** bidding their own
fundamentals — GB on the Viking link (cv21) and Ukraine as a war-constrained
firm buyer (cv22). Post-auction data (e.g. scheduled commercial exchanges) is
inadmissible by construction.

## Parameters (per-zone profile; a zone picks one named profile)

| Parameter group | Values |
|---|---|
| Tranche ladder | (55%, 0.95×) (20%, 1.05×) (15%, 1.25×) (10%, 1.60×) |
| Must-run | deep block 60% of p_min at 5%·SRMC; rest at max(0.5·SRMC, SRMC−40) |
| Scarcity | threshold 1.4 / κ 3.0 / peak κ 1.2 (gas-marginal) · 1.25/1.5/0.6 (meshed continental) · 1.2/1.0/0.5 (hydro-dominated) |
| Water value | gas-anchored: base 0.85, span 0.9, dry-boost 1.0 · reservoir-opportunity: 0.35→1.0 × thermal by dryness, drawdown term · anchored: share × pass-1 ref, clamped [€2, gas SRMC] |
| Anchor share | 0.9 (Norway, Sweden-south, CH) · 1.1 (AT) · 0.55 off-peak (FR nuclear) |
| Fleet truth | `:installed` activity-gated (continental + Baltic) · trailing-p95 (elsewhere) |
| Flow rule | `:v3` load-analogue + D-2 (EU-footprint default since cv19) |
| Demand | 98% @ €3000, 2% @ €250 |
| Since cv21 | `boundary_book` (GB/Viking, Ukraine), availability-scaled French nuclear share, `input_corrections` (island solar, cv32), `tranche_grading` (cv36), `wet_adjusted_drawdown` (cv37) |

`ZoneProfile` in `src/merit_order/zone_profiles.jl` is the authoritative list —
every field carries a docstring, and the values above are a summary, not a
second source of truth.

## Performance

Measured on the published cv37 record (`clearing_mode='multi_zone_eu'`): 786
delivery days 2024-07-01 → 2026-08-26, 39 zones, 734,640 hourly cells matched
against settled prices.

- **Ratified two-year ladder** (729 days 2024-07 → 2026-06, energy-weighted —
  the metric the version decisions were made on): footprint corr 0.740, MAE
  €25.22, with 90% of European energy in zones the model tracks at corr ≥ 0.70
  and 56% at ≥ 0.80. Mechanisms in `docs/experiments/cv36-graded-tranche/` and
  `docs/experiments/cv37-nordic-wet/`; the ratified table itself lands with the
  open PR #353.
- **Per zone, unweighted** (comparable 12 months 2025-07 → 2026-06, 341,160
  cells): footprint MAE €23.71, bias −€5.21, mean zone corr 0.770, median
  0.784. Strongest GR and DE_LU at 0.86; weakest SE4 at 0.42.

Reading it by strategy class: the **cost-ladder thermal strategy is the
strongest** — wherever gas or truthed thermal sets the price (Greece, Germany,
Iberia, Italy, France) correlation sits in the low 0.8s with MAE around €20.
**Hydro opportunity-cost bidding** is now solid where the export relationship
is stable and, since cv37 damped the winter water-value lift in wet years, in
the Nordic reservoir zones too. What remains is **level**, not shape: the
Baltics still clear ≈ €23/MWh below realized (winter import pricing) and the
Core evening belt €10–17 below — under this program's framing those are
candidate conduct signatures as much as model gaps
(`docs/experiments/conduct-probe-2026-08/`).

The single largest step was the **network, not the bids**: taking Core and
Nordic capacity from JAO's D-1 publication instead of the day-ahead-empty
ENTSO-E table moved the footprint from MAE €26.24 / corr 0.680 to €23.40 /
0.761 on 52 held-out Wednesdays (`docs/experiments/jao-maxbex-atc.md`). It cost
collapse-hour recall (43% → 14%, with false alarms 1019 → 174), which is the
open item.

See also: `docs/code-version-ledger.md` (what is in each version and what was
measured and rejected), `docs/ex-ante-flows.md` (per-border flow-rule
evidence), `docs/calibration-atlas.md` (how the footprint was first calibrated
— a July 2026 historical record).
