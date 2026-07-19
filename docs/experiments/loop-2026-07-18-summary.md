# Improvement loop — 2026-07-18 21:01 → 2026-07-19 05:01 UTC (8 h)

Self-paced improvement loop on `feat/strategic-layer-phase-b` (PR #161):
collect → study → prototype → A/B → record, every result committed as it
landed. All experiments offline (read-only extract, `save_to_db=false`),
paired A/B against same-day baselines, runtime overrides only — **no src/
product changes, no cv bump**. 14 commits.

## Findings, ranked by measured effect

1. **IT flat-line solved in prototype — per-unit SRMC spread.** The night's
   headline. Chain of evidence: (α) naive fine-tranche ladder = dead end
   (0/20 days, sim-std unchanged); (β) marginal-attribution probe → every
   hour pinned at 90.90 by FOUR different gas units whose tranches price
   identically (one type-level SRMC aligns the whole fleet into a multi-GW
   flat step); (γ) stable ±8 % per-unit repricing → **IT-CSOUTH corr
   0.307→0.680, MAE 21.81→20.05, 19/20 days; IT-NORTH corr 0.747→0.820,
   MAE −1.9, 17/20**; magnitude sweep: corr plateaus at ±8 %, MAE keeps
   improving to ±12 % (19.35).
2. **DK1 valley mechanism found — export-absorption ladder.** Elastic export
   demand steps (30/15/5 € × 400 MW): **corr 0.495→0.569, MAE −2.0**, binding
   only in RES-surplus hours (10/20 days — the expected signature). Combo
   with unit spread: 0.553 / −1.8 but **14/20** — more consistent, slightly
   diluted. Unit spread alone: marginal (0.521). cv18 DK1 package =
   export-absorption pricing primary, spread optional.
3. **HU pilot — closest non-GR call, gate still fails.** big3 (MVM+MET+Mátra)
   at 25 % beats the additive null out-of-sample (36.11 vs 36.60, 155 days)
   but 56 % consistency < the 60 % gate; closes only ~⅓ of HU's +12.5
   residual. HU's residual is at least half a model problem (2-zone baseline
   corr 0.54 vs 0.71 coupled) — re-test after the import-model iteration.
4. **SE3 — two honest negatives.** `water_value_base` 0.85→0.65/0.50 barely
   moves the price (wrong scalar), and the 2-zone harness distorts SE3
   (resid −45.6 vs −30 coupled): SE3 calibration **must run on the coupled
   footprint**. Its problem remains the night-time hydro floor (precisely
   characterized: −39…−41 € at night vs −21 at peak).
5. **Firm maps wave 3**: ES hydro rules (Oriol/Muela/Aldeadávila → Iberdrola,
   Mequinenza/Ribarroja → Endesa) lift ES dispatchable coverage 46 %→57 % —
   gate (70 %) still open; the CCGT short-code tail remains.

## Four real bugs caught by the loop's own review discipline

1. `counterfactual_bid` band floor anchored to target — provable no-op at
   headroom ≥ 0.33 (fixed earlier in the day, confirmed tonight).
2. "topslice" mislabel (deep-must-run anchor made it near-uniform) — the
   corrected instrument flipped the GR mechanism story (committed earlier).
3. **DK1 EIC prefix**: the spread only repriced `26W*` (Italian) tags —
   Danish units untouched, first DK1 "negative" invalidated; rerun valid.
4. **Strategist ctx has no `resolution_minutes`** — a closure referencing it
   throws and the per-zone build silently drops the zone (B-arm returned
   zero prices). Same silent-drop failure mode as the July OPS incident;
   worth a loud warning in `mz_build_books` (small src fix for the PR).

## cv18 candidate list (ranked, with tonight's measured expectations)

1. **Per-unit SRMC spread ±10 % for the IT zones** (ideally inferred heat
   rates): expect IT corr +0.1…+0.37 per zone, MAE −1.5…−2.5.
2. **RES-surplus export-absorption pricing for DK1** (and candidate DK2/NL):
   expect corr +0.07, MAE −2.
3. **SE3 reservoir-model recalibration on the coupled footprint** (night
   floor; `water_value_base` alone is not the lever).
4. **HU import-model iteration**, then re-run the markup pilot.

All four ship with the standard guards: SEE byte-identity, per-zone held-out
A/B, additive-null comparison, cv bump + backfill + Metabase link.

## Open items (Phase C/D, unchanged)

Phase C (EU strategic counterfactual, GR-only layer) and Phase D (per-slot
bid ladders + commentary) as scoped in the roadmap; ES/IT firm-map gates and
the HU re-test feed Phase B round 2.
