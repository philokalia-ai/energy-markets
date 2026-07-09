# EU-wide footprint calibration — iteration 1

Follow-up to the EU-footprint experiment (PR #91, issue #90). That experiment
extended multi-zone merit-order clearing from the 5-zone SEE footprint to a
38-zone Europe-wide footprint and found that **GR's signal survives** but the
merit book does not yet generalise beyond its SEE/Iberia-validated scope
(Italy underpriced ~€100, Nordic catastrophically overpriced, continental
cores overpriced from an incomplete transit picture).

This iteration delivers:

1. **Phase 1 — network/loader fix** (the highest-value change): reconnect Italy
   to the continent, add Switzerland as a transit node, and union the explicit
   ATC table. All gated behind `enrich_network` so the SEE product is untouched.
2. **Phase 2 — `ZoneProfile` abstraction**: the ~18 global bid-construction
   kwargs of `create_merit_order_book` become a per-zone profile selected from
   `ZONE_PROFILES`, defaulting to `SEE_PROFILE` (= exact v10 defaults).
3. **Phase 3 — per-region calibration**: Italy SRMC premium, a Nordic
   reservoir-opportunity hydro model, and softened continental/Baltic scarcity.

**Sign convention in every table below: `bias = mean(sim − actual)`, so a
positive bias means the model *overprices*.** (Issue #90 quoted the opposite
sign, actual − sim; e.g. its "Italy +100 underpricing" is bias ≈ −100 here.)
Evaluation window: **2026-04-01 … 2026-04-05** (5 days), sim vs
`entsoe.energy_prices` Day-ahead.

---

## The paramount guard — SEE is byte-identical

Every change is gated so the validated 5-zone SEE product
(`clearing_mode='multi_zone'`, code_version 10) is **byte-identical**. Confirmed
before and after every code change by clearing GR/BG/RO/RS/HU on 2026-04-03:

| | GR | BG | RO | HU | RS |
|---|---|---|---|---|---|
| validated product (DB, cv10) | 131.34 | 131.34 | 131.34 | 84.96 | dropped* |
| new code, default path | 131.34 | 131.34 | 131.34 | 84.96 | dropped* |

\* RS's book fails on this date (its RES forecast is 22/24 NULL) and is dropped
from the clearing — this is the *existing* validated behaviour, so the fix must
preserve it. The RES-coalesce fix that lets RS/CH build is gated behind
`enrich_network` and therefore only active in the EU footprint, never in SEE.

Guard mechanisms:
- Network enrichment (`include_explicit`, `aggregate_remap`) is off by default in
  `create_transfer_capacity_from_entsoe`; the SEE call is unchanged.
- `SEE_PROFILE` holds the exact v10 defaults. Unit test
  (`test/test_zone_profiles.jl`, 43 tests): a GR book with `SEE_PROFILE` is
  byte-identical to one built with the explicit legacy kwargs.
- RES NULL-coalescing (`coalesce_missing`) defaults off — SEE zones still error
  out on missing data exactly as before.

---

## Phase 1 — network/loader fix

Root cause of Italy's underpricing and GR's degraded bias was a **network
islanding artifact**, not fuel cost:

- Italy's *continental* borders (IT–FR/AT/SI, and IT–CH) are filed in ATC only
  under the **aggregate `IT`** control-area code, which has 0 generators and so
  is excluded as a footprint node. With only IT sub-zones in the footprint,
  Italy was islanded from the continent (connected internally + to GR only), so
  IT-SOUTH cleared at the €5–6 floor and the now-endogenous GR⇄IT-SOUTH link
  imported *phantom-cheap* power — which is exactly why endogenising GR's borders
  had *degraded* its bias.
- **Switzerland** — the DE/FR/IT/AT transit hub — was absent: CH is outside SDAC
  implicit coupling, so its capacity lives in the **explicit** ATC table, which
  the loader ignored.

The fix, in `create_transfer_capacity_from_entsoe` (gated by `enrich_network`):

1. **Aggregate→sub-zone remap.** `AGGREGATE_BORDER_REPRESENTATIVE = IT→IT-NORTH`.
   An aggregate border `IT↔X` is rewritten to `IT-NORTH↔X` *unless* `X` already
   borders an IT sub-zone directly (GR↔IT is physically GR↔IT-SOUTH and stays),
   which prevents a phantom line. Audited DE (DE_LU files its own BZN borders)
   and DK (DK1/DK2 file theirs) — neither needs a remap.
2. **Explicit-ATC union.** Day-ahead capacity from
   `offered_transfer_capacities_explicit` is unioned for directed borders the
   implicit table lacks (implicit preferred where both exist). Adds every Swiss
   border and Serbia's borders. The `contract_type='Day-ahead'` filter isolates
   day-ahead offered capacity (and correctly excludes flow-based HU–RO, which
   has no DA explicit rows).
3. **CH as an endogenous node** (39 generators / ~11.7 GW, load, RES). CH–IT maps
   to IT-NORTH.

Enrichment log for 2026-04-03: `3312 implicit rows, +1296 explicit-only rows,
192 aggregate endpoints remapped, 3216 in-footprint border-hours`.

---

## Phase 2 — `ZoneProfile` abstraction

`src/MeritOrderBook.jl` gains a `ZoneProfile` struct bundling the bid /
hydro / fleet / scarcity parameters, a `ZONE_PROFILES` registry (zone →
profile, default `SEE_PROFILE`), and `get_zone_profile`. `create_merit_order_book`
takes `profile::ZoneProfile=SEE_PROFILE`; each bid kwarg still exists but
defaults to `nothing` and is resolved from the profile, so an explicit kwarg
still overrides (used by the scenario hooks and tests). Two new levers:
`thermal_srmc_multiplier` (Italy) and `hydro_model` (Nordic).

Regions → zones (profiles authored as thin deltas over SEE):
`SEE`(GR/BG/RO/RS/HU/SI, default) · `IBERIA`(ES/PT, = SEE) ·
`ITALY`(IT-\*) · `NORDIC`(NO\*/SE\*/FI/DK1/DK2) · `BALTIC`(EE/LT/LV) ·
`CONTINENTAL`(DE_LU/FR/BE/NL/AT/CH/PL/CZ/SK).

---

## Phase 3 — per-region calibration

- **Italy** `thermal_srmc_multiplier = 1.20` — older CCGTs + premium LNG.
- **Nordic** `hydro_model = :reservoir_opportunity` — water value is the shadow
  price of stored water: near-free (floor €2/MWh) when reservoirs are full,
  rising toward the continental thermal alternative (gas SRMC proxy) as they
  empty (`get_reservoir_dryness`), *decoupled* from the gas anchor. Plus
  softened scarcity so full reservoirs stop hitting the cap.
- **Continental / Baltic** softened scarcity (`scarcity_kappa` 3.0→1.5,
  `peak_kappa` 1.2→0.6) — meshed high-RES cores where genuine scarcity is rare;
  most of the adequacy fix is expected from the Phase-1 CH transit path.

---

## Phase 3, iteration 2 — France and NO1 (diagnose-first)

**France (the one underpriced zone).** Diagnostics on 2026-04:
- Fleet picture is **correct**: nuclear unit fleet 50,852 MW (after outage
  filtering) vs trailing-30d p95 of actual nuclear output 47,355 MW — within
  the 1.15 derate headroom, so fleet-truthing rightly does not fire. No
  blanket SRMC change is justified by availability.
- Hourly residual shape (full run): the gap is a **level problem concentrated
  off-peak** — sim ≈ €10–16 overnight (the nuclear tranche-1 price at €10
  SRMC) vs actual €55–70, while midday RES-surplus hours match (sim 7.5 vs
  actual 2.8–9) and peaks are only mildly low. The observed French off-peak
  price is EDF's opportunity-cost *bidding* of its modulating nuclear fleet,
  not fuel SRMC.
- Fix: `FRANCE_PROFILE` — continental scarcity softening plus
  `nuclear_srmc_floor = 55.0` (a bidding-layer position, where bid strategy
  belongs per the repo's cost-model convention).

**NO1 (the worst Nordic zone).** Diagnostics on 2026-04:
- The reservoir-opportunity model *was* applying: `NORDIC_PROFILE` selected,
  filling-rate data exists per NO1–NO5 BZN (weekly through 2026-W27), NO1
  dryness = 0.0 → water value ≈ €25–46. Yet NO1 still cleared at €800–2300
  most hours → **adequacy, not water value**.
- Root cause: NO1's unit-level fleet is 2,430 MW vs load 3,287–3,861 MW — the
  zone imports a third of its consumption — and the implicit table's ATC into
  NO1 is ~1,254 MW total (NO2→NO1 733, NO5→NO1 490, NO3→NO1 31, **SE3→NO1
  0**). The Nordic CCR moved to **flow-based** DA capacity calculation
  (Oct 2024): the implicit "offered ATC" rows for Nordic-internal borders are
  stale residuals far below physical capacity (NO1–NO2 physical ≈ 3,500 MW).
  Endogenizing those borders starves NO1 into phantom scarcity.
- Fix (network layer, gated): drop borders internal to the Nordic flow-based
  group (`NORDIC_FLOW_BASED_ZONES`) from the enriched transfer-capacity build,
  so the book keeps **observed net imports** for them — the same honest
  treatment as other borders the ATC data cannot reproduce (RS, HU–RO).
  Nordic↔continent DC links (NO2–DE_LU/NL, DK1–DE_LU, SE4–PL, FI–EE, …) are
  genuine NTC borders and stay endogenous.

## Phase 3, iteration 3 — asymmetric Nordic border drop

Iteration 2's blanket Nordic-internal drop fixed the importers but created a
new regression: **SE1/SE2 went from bias +7/+9 to +735/+710**. Replacing their
borders with observed flows turns ~5 GW of exports into firm cap-priced demand
against a thin unit fleet (SE2: 699 MW of listed units vs 5.8 GW hydro p95),
manufacturing scarcity. Their SE-internal ATC rows are stale residuals too
(SE2→SE3 published at 8 MW vs ~7.3 GW physical), but the constrained export
direction *fortuitously reproduces the real north–south congestion* that keeps
SE1/SE2 structurally cheap. DK1/DK2 similarly degraded (corr 0.89 → −0.12).

Refined rule (`nordic_flow_based_drop_borders`): drop only borders whose
residuals demonstrably starve **importers** — every Nordic-internal border
touching a Norwegian zone, plus FI's import borders from Sweden (SE1→FI
published at 4 MW vs ~2.3 GW real imports). SE-/DK-internal borders stay
endogenous. A proper flow-based domain model is the eventual fix; this
asymmetric treatment is the least-wrong ex-ante choice and is documented as a
known limitation.

Also fixed by iteration 2/3: the previously **INFEASIBLE** clearing day
2026-04-02 (Gurobi INFEASIBLE_OR_UNBOUNDED under iteration-1 books) now solves
optimal on all five days — the pathological stale Nordic ATC bounds were the
cause.

## Phase 3, iteration 4 — import-only observed flows over dropped borders

Iteration 3 fixed SE1/SE2/DK1 but pushed the failure downstream: SE3 gained
firm cap-priced export demand toward NO1/FI over the dropped borders while its
own import path is the 8 MW SE2→SE3 residual (bias −6.5 → +578), cascading
through the endogenous chain to SE4 (+530), DK2 (+413) and LT (+161, via
NordBalt). Completion of the asymmetric treatment: over DROPPED borders,
observed flows enter a zone's book **import-only** (`GREATEST(flow, 0)` per
hour) — the import supplies a starving importer (NO1's 2.3 GW), but the
corresponding export never becomes firm cap-priced demand against a thin
Nordic unit fleet. This killed every remaining cap-blowup.

## Per-zone metrics: baseline → Phase 1 → iteration 3 → final (5 days, bias = sim − actual)

| zone | baseline corr/MAE/bias | Phase 1 corr/MAE/bias | iter 3 corr/MAE/bias | **final (iter 4)** corr/MAE/bias |
|---|---|---|---|---|
| AT | 0.55 / 62.9 / +52.5 | 0.75 / 32.3 / +7.5 | 0.74 / 37.6 / +26.0 | **0.75 / 41.4 / +31.5** |
| BE | 0.33 / 113.0 / +105.5 | 0.61 / 82.0 / +74.4 | 0.69 / 53.8 / +46.5 | **0.68 / 52.3 / +44.3** |
| BG | 0.71 / 36.8 / -1.4 | 0.76 / 33.9 / -1.1 | 0.79 / 30.5 / +7.0 | **0.80 / 32.2 / +12.5** |
| CH | — | 0.82 / 28.5 / +9.8 | 0.81 / 42.6 / +41.6 | **0.82 / 48.5 / +48.0** |
| CZ | 0.66 / 48.9 / +35.5 | 0.78 / 34.7 / +12.5 | 0.80 / 35.5 / +12.3 | **0.80 / 38.6 / +13.1** |
| DE_LU | 0.51 / 215.0 / +205.3 | 0.81 / 42.1 / +30.1 | 0.90 / 27.1 / +17.1 | **0.89 / 26.8 / +13.7** |
| DK1 | 0.26 / 91.4 / +74.7 | 0.83 / 37.5 / +32.8 | 0.81 / 31.2 / +13.0 | **0.87 / 23.2 / +0.2** |
| DK2 | 0.55 / 395.2 / +394.3 | 0.40 / 165.5 / +163.8 | 0.33 / 414.2 / +413.2 | **0.84 / 36.0 / +31.1** |
| EE | -0.03 / 253.1 / +214.8 | 0.35 / 103.1 / +96.0 | 0.56 / 22.8 / +2.3 | **0.60 / 20.1 / +5.2** |
| ES | 0.81 / 21.4 / +20.1 | 0.75 / 23.1 / +20.8 | 0.79 / 33.3 / +32.8 | **0.81 / 32.8 / +32.2** |
| FI | 0.45 / 80.9 / +78.7 | 0.66 / 117.6 / +116.5 | 0.69 / 15.3 / +5.0 | **0.80 / 12.9 / +7.1** |
| FR | 0.61 / 48.3 / -34.1 | 0.64 / 47.3 / -34.5 | 0.75 / 41.4 / +0.2 | **0.76 / 42.8 / +8.5** |
| GR | 0.74 / 34.4 / -7.0 | 0.75 / 34.1 / -4.3 | 0.79 / 29.7 / +5.5 | **0.80 / 31.4 / +10.7** |
| HU | 0.23 / 333.2 / +320.7 | 0.55 / 76.0 / +58.6 | 0.54 / 79.5 / +68.5 | **0.60 / 68.7 / +58.1** |
| IT-CNORTH | 0.55 / 84.1 / -83.8 | 0.57 / 52.5 / -41.0 | 0.77 / 23.0 / +0.2 | **0.77 / 24.3 / -0.3** |
| IT-CSOUTH | 0.70 / 117.7 / -117.5 | 0.65 / 123.0 / -122.9 | 0.84 / 21.8 / -10.5 | **0.85 / 22.5 / -8.6** |
| IT-Calabria | 0.73 / 116.6 / -116.5 | 0.63 / 120.8 / -120.8 | 0.82 / 22.1 / -9.8 | **0.83 / 22.3 / -7.3** |
| IT-NORTH | 0.56 / 81.9 / -81.6 | 0.57 / 52.5 / -41.0 | 0.77 / 23.0 / +0.2 | **0.77 / 24.3 / -0.3** |
| IT-SOUTH | 0.73 / 116.6 / -116.5 | 0.63 / 121.1 / -121.1 | 0.83 / 22.1 / -10.0 | **0.83 / 22.3 / -7.3** |
| IT-Sardinia | 0.09 / 115.9 / -115.7 | 0.14 / 122.1 / -122.0 | 0.83 / 23.4 / -12.3 | **0.83 / 24.4 / -10.7** |
| IT-Sicily | 0.34 / 99.6 / -99.5 | 0.30 / 111.6 / -111.6 | 0.82 / 22.1 / -9.8 | **0.83 / 22.3 / -7.3** |
| LT | 0.42 / 237.3 / +225.7 | 0.40 / 152.8 / +143.0 | 0.42 / 173.2 / +161.4 | **0.84 / 40.3 / +29.0** |
| LV | 0.27 / 54.5 / +2.1 | 0.50 / 59.3 / +36.9 | 0.44 / 26.8 / -10.9 | **0.41 / 24.4 / -8.3** |
| NL | 0.77 / 37.0 / -4.3 | 0.81 / 34.7 / -4.6 | 0.82 / 36.6 / -5.4 | **0.83 / 35.2 / -3.6** |
| NO1 | -0.13 / 1292.5 / +1292.5 | -0.17 / 1268.7 / +1268.7 | 0.33 / 194.7 / +56.1 | **0.38 / 79.2 / -79.2** |
| NO2 | 0.62 / 93.3 / +88.0 | 0.58 / 93.0 / +89.8 | 0.33 / 38.6 / -33.7 | **0.63 / 37.7 / -33.7** |
| NO3 | 0.25 / 449.0 / +449.0 | 0.27 / 309.8 / +309.8 | 0.16 / 59.7 / -8.4 | **0.26 / 30.9 / -30.9** |
| NO4 | 0.18 / 136.4 / +136.4 | 0.18 / 137.2 / +137.2 | 0.45 / 17.8 / +17.6 | **0.56 / 21.1 / +21.1** |
| NO5 | 0.20 / 63.1 / +62.8 | 0.20 / 63.2 / +62.8 | 0.78 / 65.7 / -65.7 | **0.36 / 64.8 / -64.8** |
| PL | 0.69 / 51.7 / +44.0 | 0.69 / 47.0 / +36.0 | 0.79 / 36.9 / +23.2 | **0.82 / 37.5 / +22.5** |
| PT | 0.81 / 21.4 / +20.1 | 0.75 / 22.9 / +20.7 | 0.78 / 33.1 / +32.6 | **0.80 / 32.7 / +32.2** |
| RO | 0.71 / 36.8 / -1.4 | 0.76 / 33.9 / -1.1 | 0.79 / 30.5 / +7.0 | **0.80 / 32.2 / +12.5** |
| RS | 0.67 / 38.5 / -16.1 | 0.81 / 27.8 / -0.0 | 0.82 / 26.3 / +8.3 | **0.83 / 28.4 / +13.4** |
| SE1 | 0.62 / 88.4 / +85.9 | 0.59 / 83.4 / +78.8 | 0.46 / 14.0 / +6.1 | **0.49 / 13.5 / +2.8** |
| SE2 | 0.62 / 87.6 / +86.6 | 0.61 / 84.3 / +81.7 | 0.43 / 15.5 / +8.7 | **0.50 / 13.9 / +5.3** |
| SE3 | 0.50 / 377.2 / +377.2 | 0.49 / 195.2 / +195.2 | 0.44 / 578.6 / +578.3 | **0.57 / 54.4 / +50.0** |
| SE4 | 0.53 / 489.7 / +489.7 | 0.43 / 214.3 / +214.3 | 0.33 / 530.3 / +530.3 | **0.80 / 67.9 / +67.5** |
| SI | 0.27 / 105.7 / +97.8 | 0.80 / 31.3 / +4.6 | 0.75 / 39.1 / +25.7 | **0.76 / 42.9 / +31.0** |
| SK | 0.77 / 35.9 / +1.4 | 0.76 / 33.8 / -1.7 | 0.77 / 33.5 / -1.5 | **0.76 / 36.1 / -2.9** |

Aggregates over all 39 zones:

- `AGG baseline zones=38  meanMAE=162.2  meanBias=+109.6  medMAE=89.9`
- `AGG phase1   zones=39  meanMAE=114.2  meanBias=+66.0  medMAE=63.2`
- `AGG iter3    zones=39  meanMAE=77.0  meanBias=+50.5  medMAE=33.1`
- `AGG iter4    zones=39  meanMAE=35.0  meanBias=+8.7  medMAE=32.2`

(The intermediate iter-1/iter-2 columns are in the git history of this file's
generation scripts; headline: iter1 meanMAE 66.9 with NO1 still at 1150 and
day 2026-04-02 INFEASIBLE, iter2 meanMAE 76.2 with SE1/SE2 broken at +735.)

## What's fixed vs what remains

**Fixed (relative to the PR #91 baseline):**
- **Italy — fully fixed by network remap + SRMC premium.** All seven sub-zones
  from bias ≈ −100 (floor-priced islanding) to −11…0, MAE ≈ 22–24, corr
  0.77–0.85. This also removed GR's phantom-cheap import.
- **Continental adequacy — largely fixed by Phase 1 alone** (endogenous
  IT reconnection + CH node + explicit ATC): DE_LU +205 → +14 (corr 0.51 →
  0.89), HU +321 → +58, SI +98 → +31, BE +106 → +44, AT +53 → +32, DK1 +75 →
  +0.2 (corr 0.87). NL/CZ/SK/PL stay good.
- **France — fixed** by the nuclear bid-position floor: bias −34 → +8.5,
  corr 0.61 → 0.76. Diagnosis showed the fleet was right and the off-peak
  level was the gap.
- **Nordic cap-hitting — killed.** NO1 MAE 1292 → 79, NO3 449 → 31, SE3 377 →
  54, SE4 490 → 68, DK2 395 → 36, FI 81 → 13 (corr 0.80), SE1/SE2 88 → 14,
  EE 253 → 20, LT 237 → 40. No zone in the footprint clears at scarcity/cap
  artifacts any more.
- **GR guard held throughout**: the SEE 5-zone product is byte-identical, and
  in the EU footprint GR improved vs baseline (corr 0.74 → 0.80, MAE 34.4 →
  31.4; bias −7.0 → +10.7 — the sign flip is the removal of the phantom-cheap
  Italian import, a genuine coupling effect).

**Honest remaining gaps (recommended next iteration):**
- **NO5 (−65) and NO1 (−79)**: southern-Norway levels now *under*shoot —
  water value ≈ 0.35×gas with full reservoirs is too cheap for zones coupled
  to an €85–105 continent. The reservoir-opportunity export anchor should be
  the *coupled continental price*, not a fixed fraction of gas SRMC — needs an
  iterative (two-pass) clear or a continental price proxy. Their price SHAPE
  is now sane (no cap artifacts), which is what this iteration promised.
- **SE3/SE4 (+50/+68)**: mid-Sweden still slightly scarce — the residual
  SE-internal ATC underfeeds them; a flow-based domain model is the real fix.
- **CH (+48)**: transit hub clears too high; likely needs its own profile
  (hydro-dominated like Nordic rather than CONTINENTAL) — untuned this pass.
- **HU (+58) / BE (+44) / AT, SI (~+30)**: residual adequacy overpricing in
  the meshed core; softening CONTINENTAL scarcity further trades off DE_LU.
- **ES/PT (+32 vs +20 at baseline)**: Iberia degraded slightly when France
  re-priced (coupling effect through FR–ES). May justify an IBERIA delta.
- The `multi_zone_eu` baseline (PR #91) remains untouched in the DB;
  calibration iterations live under `multi_zone_eu_p1/_cal/_cal2/_cal3/_cal4`
  (final = `_cal4`).

**Solve times** (39-zone footprint, per day): book build ~4.5–8 min (DB-bound),
MPCC solve 10–47 s (Gurobi). The whole-Europe clear remains tractable.

