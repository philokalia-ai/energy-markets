# Calibration Atlas — how the EU-wide competitive counterfactual is built

Synthesis of calibration iterations 1–5 (PRs #91–#95, #97; released as v0.2.0).
This is the single reference page; the chronological record with every measured
sub-iteration, failure mode, and audit lives in `docs/eu-calibration-iter1..5.md`.

> **Note — this page describes the v0.2.0 (cv14) state.** It documents *how* the
> EU footprint is built and is accurate for that; the numbers below are the
> 5-day v0.2.0 snapshot. The **current canonical record is cv22**
> (2023-01-01…2026-07-24, 1,301 days): comparable full-year mean corr **0.67** /
> MAE **€27.4**. See the README headline and `docs/reproducibility.md`.

**State at v0.2.0** (39 zones, 5-day window 2026-04-01…05, resolution-aware
methodology, bias = sim − actual): mean MAE **23.9 €/MWh**, mean corr **0.79**,
mean bias **−2.5**, no zone above 36 MAE, zero regression flags, GR/SEE product
byte-identical throughout.

---

## 1. The clearing workflow

One pipeline per market day:

1. **Network build.** Implicit ATC (`offered_transfer_capacities_implicit`),
   plus three enrichments gated behind `enrich_network`:
   - **Explicit-ATC union** — CH is outside SDAC implicit coupling and Serbia's
     borders are auction-allocated; both live only in
     `offered_transfer_capacities_explicit` (Day-ahead rows).
   - **Aggregate→sub-zone remap** — Italy's continental borders are filed under
     the aggregate `IT` control-area code (0 generators, so it is never a
     footprint node). `IT↔X` is rewritten to `IT-NORTH↔X` unless X already
     borders an IT sub-zone directly (GR↔IT is physically GR↔IT-SOUTH).
   - **Flow-based border drops** (`flow_based_drop_borders`) — borders inside a
     flow-based capacity-calculation domain publish stale residual "offered
     ATC" far below physical capacity (measured: SE2→SE3 at 118 MW vs ~5,015 MW
     physical; DE_LU→BE at 0–1 MW at peak vs 1.4–1.9 GW; NO import ATC ~1.25 GW
     vs ~2.3 GW real imports; HU evening imports at 37–112 MW). Keeping such a
     border endogenous starves the importer into phantom scarcity. Dropped
     borders fall back to **observed flows, import-only**
     (`GREATEST(flow, 0)`) — the import supplies the starving zone, but the
     export never becomes firm cap-priced demand against a thin fleet.
     Current drop set: Nordic-internal borders touching NO zones, FI's imports
     from SE1/SE3, HU–AT/SK, SE2–SE3, SE3–SE4, BE–FR/NL/DE_LU.
2. **Per-zone book construction.** Each zone resolves its `ZoneProfile`
   (registry `ZONE_PROFILES`, default `SEE_PROFILE`) and builds a merit-order
   book from fundamentals: SRMC supply tranches (daily TTF gas + EUA carbon),
   must-run self-scheduling, a hydro model, RES forecast at ~€1, scarcity/peak
   markups, demand ≈98% at the €3000 cap plus a small elastic tail. Borders
   made endogenous by the network build are excluded from the observed
   net-import injection (border-aware exclusion).
3. **Pass-1 MPCC clear.** One MILP across the footprint: complementarity with
   **exact per-order Big-M** (`q·(bid − floor)` supply / `q·(ceiling − bid)`
   demand — a proof, not a tuning), the market-coupling condition
   λ_sink − λ_source = ρ⁺ − ρ⁻ per endogenous border, MIP gap 1e-6,
   deterministic component-wise price reconstruction. ~10 s/day (Gurobi) for
   39 zones.
4. **Anchor extraction.** For zones whose profile sets `opportunity_anchor`,
   compute per-hour reference prices from pass-1 coupled prices: the
   capacity-weighted mean of endogenous, well-calibrated neighbors (DE_LU/NL
   proxy for Norway). All inputs are model-internal — the counterfactual stays
   **no-fit and ex-ante**; realized prices never enter.
5. **Pass-2 re-clear** (`passes=2`). Rebuild only the anchored zones' books —
   water value or nuclear floor repositioned to `anchor_share × ref`,
   dropped-border observed imports priced at the ref — and re-clear. All other
   books are reused from pass 1.

Every mechanism is opt-in; the default path (single-zone and 5-zone SEE) is
byte-identical to the validated v10 product and unit-tested as such.

## 2. Region strategies — who sets the price, and how we model it

The clearing machinery is region-agnostic; what differs is the **marginal
price-setter and the alternative it prices against**.

| Region (zones) | Price-forming force | Model |
|---|---|---|
| **SEE** (GR, BG, RO, RS, HU, SI) | Gas-marginal thermal; hydro shadows gas | `SEE_PROFILE` — exact v10 baseline (SRMC tranches, gas-anchored water value, full scarcity markups) |
| **Iberia** (ES, PT) | Same as SEE; near-isolated, solar-heavy | `IBERIA_PROFILE` ≡ SEE (verified identical) |
| **Italy** (7 sub-zones) | Gas at a premium — older CCGTs, LNG import costs | SEE + `thermal_srmc_multiplier = 1.20`; the decisive fix was the network remap, not fuel cost |
| **Continental core** (DE_LU, NL, PL, CZ, SK) | High-RES meshed thermal transit; genuine scarcity rare | `CONTINENTAL_PROFILE`: softened scarcity (threshold 1.25, κ 1.5, peak κ 0.6); adequacy from endogenous flows + CH transit node |
| **France** | EDF's opportunity-cost bidding of modulating nuclear — not fuel SRMC (the fleet was proven correct; the gap was off-peak bid *position*) | `FRANCE_PROFILE`: nuclear bid floor €55 + `:nuclear` anchor at `anchor_share = 0.55` of the coupled off-peak reference |
| **Nordic hydro** (NO4, SE1, SE2, FI, DK1, DK2) | Shadow value of stored water (reservoir levels) | `NORDIC_PROFILE`: `hydro_model = :reservoir_opportunity` — water value from weekly reservoir dryness, decoupled from gas; soft scarcity |
| **Southern/mid Norway** (NO1, NO2, NO3, NO5) | Stored water priced against the **export opportunity to the continent** | `NORWAY_PROFILE` = Nordic + `:hydro` anchor at 0.9 × pass-1 continental ref |
| **South/mid Sweden** (SE3, SE4) | Same object as southern Norway, once the stale internal borders stop starving them | `SWEDEN_SOUTH_PROFILE` ≡ NORWAY_PROFILE, paired with the SE2–SE3/SE3–SE4 drop (one treatment) |
| **Alpine** (CH, AT) | Reservoir storage against the continent — hydro-dominated transit hubs | `SWISS_PROFILE` / `AUSTRIA_PROFILE`: reservoir-opportunity + `:hydro` anchor; AT at `anchor_share = 1.1` (its observed Core premium), CH at 0.9. Rolled out **jointly** — fixing CH alone broke AT through their border |
| **Belgium** | Continental thermal, but its Core-FBMC import ATC collapses exactly at its residual peak hours | `BELGIUM_PROFILE`: BE–FR/NL/DE_LU dropped + observed imports priced at the anchor ref (corr 0.68 → 0.95) |
| **Baltic** (EE, LT, LV) | Thermally thin, rides the Nordic system | `BALTIC_PROFILE`: softened scarcity. LT and DK2 were cured purely by the SE fix propagating — no local change |

## 3. The bid skeleton — what each unit offers, and why not UC

The merit-order path does **not** run unit commitment. The counterfactual wants
each unit's *rational competitive bid*, not a simulated central dispatch (UC
answers "what would a planner run", pins prices to the most expensive committed
unit, and is ~100× slower — impractical for a 39-zone two-pass clear). The one
piece of dispatch logic that survives is **UC-lite commitment**: thermal units
with SRMC ≤ `must_run_srmc_threshold` × gas-SRMC are stacked by marginal cost
until derated capacity covers 1.05 × the day's **peak** residual demand; that
set is "committed" (commitment follows the peak), so its minimum load is
must-run through the overnight trough — which is what lets prices collapse
below thermal SRMC in RES-surplus hours, as real self-scheduling does.

Every zone-slot book uses the same skeleton; regions only change parameters:

| Unit class | Quantity offered | Price rule |
|---|---|---|
| Wind / solar | Zone-level forecast (units excluded from the stack) | €1 — price-taker |
| Reservoir & pumped hydro | p_max × hydro scale (reservoir levels / recent output) | **Water value** (three models, §2), never variable cost |
| Committed thermal — minimum load | p_min in two blocks | Deepest 60% at 5% of SRMC; rest at max(0.5·SRMC, SRMC − 40) — an *absolute* startup-amortization discount (a proportional one sank crisis-2022 evenings) |
| Same unit — flexible capacity | (p_max − p_min) × tranches 55/20/15/10% | Ladder at 0.95/1.05/1.25/1.60 × SRMC; tranche 1 at cost, upper tranches × the scarcity factor |
| Uncommitted thermal | p_max × same tranches | Same ladder + scarcity |
| Observed imports (non-endogenous borders) | Hourly net flow | €1 price-taker — anchored zones price them at the coupled reference instead |
| Observed exports | Hourly net flow | Firm demand at the cap — over *dropped* borders, demand at the reference (cannot manufacture scarcity) |
| Demand | 98% of gross load / 2% tail | €3,000 cap / €250 elastic |

Scarcity factor on upper tranches:
`1 + scarcity_kappa · max(0, scarcity_threshold − margin)² + peak_kappa · norm_demand^peak_exponent`
— the first term fires when the derated capacity margin over residual demand
genuinely tightens; the second is peak-hour strategic bidding (participants
know when the peak is; the 4th power concentrates it there).

Fleet honesty runs before any bidding: **fleet completion** (per-type aggregate
capacity missing from the unit list is added back) and **fleet truthing**
(baseload types derated to `derate_headroom` × trailing-30-day p95 output when
the paper fleet exceeds what actually runs).

Reading the region table in §2 against this skeleton: regional strategies are
three families of deviation — (1) **cost truth** (Italy's SRMC multiplier,
France's nuclear floor), (2) **opportunity-cost repricing** of the dominant
flexible resource against the pass-1 coupled price (hydro anchors, the nuclear
anchor, Belgian import pricing — all the same mechanism), and (3) **scarcity
temperament** (how aggressively upper tranches mark up — a statement about how
often each region is genuinely tight).

## 4. Mechanism inventory

Four orthogonal mechanisms carry all of the above:

1. **`ZoneProfile`** (`src/MeritOrderBook.jl`) — ~23 data fields, no logic:
   tranches, must-run, scarcity/peak shape, water-value parameters,
   fleet-truthing, and the calibration levers (`thermal_srmc_multiplier`,
   `hydro_model`, `nuclear_srmc_floor`, `opportunity_anchor`, `anchor_share`).
   Profiles are thin deltas over SEE; every profile docstring records its
   diagnostic rationale and measured effect.
2. **Network treatments** (`src/Network.jl`, `src/Euphemia.jl`) — explicit
   union, aggregate remap, flow-based drops with import-only observed flows.
3. **Two-pass opportunity anchoring** (`src/Euphemia.jl`) — the general answer
   to "a resource priced at opportunity cost against the coupled system"; one
   mechanism serves Norwegian hydro, Swedish hydro, alpine storage, French
   nuclear, and Belgian import pricing.
4. **Solver exactness** (`src/MPCC.jl`) — exact per-order Big-M (also ~10–20%
   faster), gated INFEASIBLE retry ladder (NumericFocus first, seed last),
   IIS diagnostics printer.

## 5. Calibration doctrine (learned the hard way)

- **Calibrate in the coupled run, never per-zone in isolation.** Every failure
  migrated along a border chain (SE fixes cascading through DK/LT; CH's fix
  breaking AT; HU's drop moving SI).
- **A flow-based border drop and the pricing of its observed flows are ONE
  treatment.** Confirmed three times independently (Norway iter-2, HU/cal14,
  BE/cal17): dropping without re-anchoring inverts the error (+46 → −35)
  instead of fixing it.
- **Anchors must be model-internal.** The no-fit ex-ante property is
  non-negotiable; refs come from pass-1 model prices, never realized prices.
- **Costs vs bids:** fuel/carbon truth lives in the SRMC model; strategic
  *positions* (French nuclear floor, AT's Core premium) live in profiles.
- **One change per sub-iteration, measured, with an explicit acceptance rule**
  (target improves AND no good zone regresses >0.05 corr / 10 MAE AND the SEE
  guard is byte-identical).
- **A measured, documented dead end is a valid outcome.** The gated cal10 CH
  experiment became iteration 4's CH/AT win; rejected shapes (NO5's circular
  Nordic anchor) are recorded with the reason.

## 6. Evaluation methodology

Compare `simulations.energy_prices` (naive UTC) against `entsoe.energy_prices`
Day-ahead with **resolution-aware actuals**: dedup to the latest revision
`sequence`, use the hourly series where present, else the hourly mean of the
15-minute series (`test/scripts/eu_eval_metrics.jl`). The pre-iteration-4 JOIN
double-weighted :00 and diverges wildly for quarter-hourly zones (DK2, LT,
SE3/SE4) — cross-iteration comparisons must state which methodology they use.
Timezone rule everywhere: `entsoe_col = (sim_col AT TIME ZONE 'UTC')`.

## 7. Known limitations / iteration-6 queue

- **NO5 (−34) / NO4**: far-north storage arbitrages across days; a daily
  two-pass cannot represent the inter-day horizon. Candidate fixes: sequential
  third pass or a weekly water-value reference.
- **ES/PT (+33 level)**: drifted through FR coupling; actuals in the window
  averaged €14 (near-free solar), so relative error overstates it.
- **NO3 (corr 0.62), SE1/SE2 (corr ~0.5 on flat €20 prices, MAE only €13)**:
  correlation is a weak metric for flat-price zones.
- **Structural cleanup**: make ref-based import pricing the default for all
  dropped borders.
- **Offline reproduction (available)**: the full 39-zone EU merit-order clear now
  runs against a self-contained DuckDB extract (`bin/build_duckdb_extract.jl` with
  the 39-zone footprint + `AGEN_BACK_DAYS=90`, ~490 MB), reproducing Postgres
  prices to ≤2e-12 €/MWh (~98% of rows bit-identical; residual is last-ULP SQL
  aggregate-order noise) at ~4–5× lower wall time. Useful for fast iteration and
  for the multi-month backfill below without hammering the live DB.
- **Validation breadth**: all EU-footprint numbers above rest on a single
  5-day window and the SEE core's long history. **We still need to produce
  validated numbers across more than five regions over materially longer
  horizons** — a multi-month, all-region backfill (and per-year tables like
  the GR 2022–2026 ones) is the prerequisite before the EU footprint becomes
  the product.

## 8. Where the knowledge lives

- This page — the synthesis.
- `docs/eu-calibration-iter1..5.md` — chronological record: every audit,
  measured sub-iteration (cal1–cal18), failure mode, and rejection rationale.
- Profile docstrings in `src/MeritOrderBook.jl` — per-zone rationale next to
  the parameters.
- `docs/eu-footprint-experiment.md`, issue #90 (closed) — the original
  motivation: removing the forward-looking bias of observed-import fallbacks.
- Release v0.2.0 — the consolidated changelog.
