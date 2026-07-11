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
| Offered transfer capacity (implicit + explicit auctions) | ENTSO-E, ex-ante | Network constraints between zones |
| Unit registry + installed capacity per type + outages | ENTSO-E | The fleet: who can produce, how much |
| Historical unit/type output (trailing windows) | ENTSO-E | Activity gates, commitment state, fleet truthing |
| Weekly reservoir filling levels | ENTSO-E | Hydro water value |
| TTF gas & EUA carbon closes (last trading day *before* the market day) | market data | Marginal costs |
| Cross-border flow **climatology** (median of the trailing 8 same-weekday days) and D-7 flows | derived, strictly pre-auction | Injections on borders outside the coupled network |

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
paper capacity that demonstrably no longer runs is derated.

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

**6. External borders — the ex-ante flow rule.** Borders inside the footprint
are cleared endogenously (ATC-constrained). Borders that can't be — either
outside the footprint (Turkey, Ukraine, GB…) or whose published capacity is a
broken flow-based residual — enter as injections priced at the coupled
reference, using **flow climatology** (8-week same-weekday median; averages
away single-day noise) everywhere except the Norwegian borders, which use
**D-7 same-weekday flows** (reservoir regimes persist week-to-week; a median
mis-states them). Post-auction data (e.g. scheduled commercial exchanges) is
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
| Flow rule | climatology (default) · D-7 (NO borders) |
| Demand | 98% @ €3000, 2% @ €250 |

## Performance — fully ex-ante, 36-day full-year stratified sample (corr / MAE €/MWh / bias)

**Aggregate: mean corr 0.61, mean MAE 30.7, mean bias −8.5.** By strategy regime:

| Regime | Zone | corr | MAE | bias |
|---|---|---|---|---|
| Gas-marginal (SEE/Iberia) | **GR** | **0.82** | 23.3 | −6.7 |
| | BG | 0.79 | 30.3 | +6.4 |
| | ES / PT | 0.80 / 0.77 | 22 / 23 | +5 |
| | RS | 0.64 | 36.2 | +12.6 |
| | RO | 0.54 | 50.7 | +25.0 |
| Continental (installed-truthed) | **DE_LU** | **0.80** | 21.1 | −9.8 |
| | FR | 0.74 | 25.5 | +3.9 |
| | CZ / PL | 0.68 / 0.65 | 26 / 29 | −13 / −16 |
| | NL | 0.52 | 25.9 | −14.1 |
| | BE | 0.18 | 38.6 | −25.1 |
| Italy (gas + premium) | 7 zones | 0.64–0.76 | 19–24 | −14…+1 |
| Hydro, export-anchored | NO2 | **0.78** | 15.9 | −0.9 |
| | SE4 | 0.72 | 36.0 | −15.2 |
| | CH | 0.68 | 23.4 | −7.3 |
| | NO1 / NO3 / NO5 | 0.08 / 0.31 / 0.41 | 34–46 | mixed |
| Hydro, reservoir-only | FI | **0.85** | 35.1 | −27.9 |
| | DK1 | 0.69 | 26.7 | −14.6 |
| | SE1/SE2/SE3 | 0.44–0.49 | 30–39 | −13…+6 |
| Baltic (installed-truthed) | LT / LV / EE | **0.83 / 0.82 / 0.80** | 48–50 | ≈ −38 |
| Border-repaired transit | HU | 0.74 | 33.8 | −9.3 |
| | SK | 0.68 | 37.9 | −32.8 |
| | AT / DK2 / SI | 0.34 / 0.27 / 0.64 | 29–35 | −10…−12 |

Reading it by class: the **cost-ladder thermal strategy is the strongest** —
wherever gas or truthed thermal sets the price (Greece, Germany, Iberia,
Italy, France), correlation sits at 0.74–0.82 with MAE in the €20s. The
**export-anchored hydro strategy** works where the export relationship is
stable (NO2 0.78, SE4 0.72) and is weakest where flow *regimes flip week to
week* (NO1 at 0.08 — the known open problem; it needs a real flow input model
with reservoir-state features rather than a D-7 rule). The **Baltic zones
track shape excellently** (corr 0.80–0.83) but carry a systematic −€38 level
bias (winter import pricing, the next calibration target), and **BE/AT/DK2**
are the remaining shape problems in the meshed core.

Two context numbers: with *same-day observed* flows instead of climatology the
aggregate is corr 0.59 / MAE 31.9 — the ex-ante version is **not worse, it's
slightly better**, because an 8-week median is a cleaner estimate of
structural flows than any single noisy day. On 12 fully held-out days the
aggregate holds at corr 0.62 / MAE 35.3, with the degradation concentrated in
NO1.

See also: `docs/calibration-atlas.md` (the analytical-mode reference),
`docs/ex-ante-flows.md` (per-border strategy evidence).
