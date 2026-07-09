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

## Per-zone metrics: baseline → Phase 1 → full (5 days, sim − actual)

<!-- FILLED FROM compare.jl AFTER RUNS -->
_(table inserted below once the 5-day runs complete)_

## What's fixed vs what remains

_(summary inserted below)_
