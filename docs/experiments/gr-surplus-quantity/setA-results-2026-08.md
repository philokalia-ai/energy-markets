# GR surplus-quantity package — Set A results (2026-08-09): NO-SHIP

Prereg: [prereg-2026-08.md](prereg-2026-08.md) (merged #322, gates frozen).
Arms: 39-zone pipelined coupled clear, offline extract, Set A window
2025-08-01..2026-01-31, fresh base + T1 (GR floor via
`EUPHEMIA_SOLAR_REGIME_ZONES+GR`) + T2 (`EUPHEMIA_ENABLE_GRSQ_T2`) + combo,
labels `grsq_{baseA,t1A,t2A,comboA}` in results.duckdb; 163 common days.
Evaluation regime (pre-declared, derived from the frozen lever gates before
any treated score was seen): share ≥ 0.4 OR (04–13 UTC AND share ≥ 0.25);
1,230 regime hours, 273 collapse (settled ≤5€) hours.

## Gate table (GR, within regime)

| arm | MAE | bias | collapse hit % | phantoms | outside MAE |
|---|---|---|---|---|---|
| base | **18.46** | −4.46 | 87.2 | 62 | 19.46 |
| T1 floor | 23.02 | −10.25 | 87.2 | 63 | 19.46 |
| T2 valley | 26.91 | −21.78 | 99.3 | **315** | 19.46 |
| combo | 36.85 | −32.51 | 99.3 | 318 | 19.46 |

Guards: outside-regime MAE identical in all arms (gating airtight); zero new
caps; envelope breaches 0/0/1 (combo breaches on GR itself). Footprint dMAE
+0.04/+0.11/+0.16.

**Every arm fails the primary** (required: MAE −1.0 AND hit +10 pts AND
phantoms not up). T2 delivers the hit-rate (+12.1 pts) but multiplies
phantom collapses 5× (62 → 315) and worsens regime MAE +8.5. NO-SHIP; no
Set B run (Set B fires only on an A-pass). Branch `feat/gr-surplus-levers`
stays unmerged as the archive.

## The finding that matters: the diagnosis did not transfer

Phase 0 measured the SINGLE-ZONE GR book: 28% of collapse hours unreachable,
morning CCGTs stuck at SRMC. The COUPLED record path shows none of that
severity: the base arm already captures **87.2%** of regime collapse hours —
imports/neighbor books absorb most of what the single-zone book cannot. The
single-zone deficit is real but the coupled clear already compensates for
most of it, so levers sized to the single-zone gap OVERSHOOT: both push the
regime bias deeper negative (−4.5 → −10/−22/−33) and T2's blunt ex-ante
valley gate collapses hours the market didn't.

**Methodology lesson (the cv18 lesson's diagnostic twin):** censuses and
anatomy for a coupled-path package must run ON the coupled path. Single-zone
Phase-0 evidence is a hypothesis generator, not a sizing basis. Recorded for
the R-harness.

Secondary observations kept for later programs:
- T2's 99.3% hit-rate shows the valley-continuation mechanism CAN collapse
  the right hours — its failure is selectivity (which hours), not power. A
  future variant needs a sharper in-regime signal (e.g. coupled-model
  surplus, not share×window alone) and cycling-economics limits (see the
  block-order pilot, same directory: true Gurobi block orders are
  price-identical to the projection at limit = floor, and only differentiate
  with limits derived from start-cost amortization).
- The base's regime bias is already NEGATIVE (−4.5): the coupled GR book
  does not have a systematic in-regime overpricing problem on Set A; the
  residual is dispersion, not level.

## Artifacts

Arms in `data/results.duckdb` (labels above); runner/orchestrator/scorer in
session scratchpad `grsq/`; block-order pilot doc + scripts in this
directory (Gurobi path gated behind `EUPHEMIA_ENABLE_GRSQ_BLOCKS`, per the
owner's flag directive).
