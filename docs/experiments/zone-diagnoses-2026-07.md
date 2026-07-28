# PL / NL / IT-NORTH diagnoses (July 2026) — three measured negatives and a converging positive finding

Three parallel investigations into the largest energy-weighted zones below the
corr-0.75 bar on the cv24 record: **PL** (0.70 in 2025, 158 TWh), **NL** (0.73,
117 TWh), **IT-NORTH** (0.67, 156 TWh). Each followed the standing discipline —
residual regime diagnosis → spec-compliance-ranked mechanism candidates →
pre-registered gate → blind coupled 39-zone A/B → honest verdict. Full records:
[pl-diagnosis/](pl-diagnosis/DIAGNOSIS.md) ·
[nl-diagnosis/](nl-diagnosis/DIAGNOSIS.md) ·
[itnorth-diagnosis/](itnorth-diagnosis/DIAGNOSIS.md).

## Verdicts (all three NO-SHIP; cv stays 24)

| zone | mechanism measured | result vs pre-registered gate |
|---|---|---|
| PL | PL-scoped `unit_srmc_spread=0.10` (heterogeneous coal heat rates) | winter corr **+0.047** (gate +0.05), summer +0.017, MAE flat; Nordic cap-day guard clean (0→0 — the cv18 explosion does NOT reappear under single-zone scoping, though not stress-tested on a cap-prone day). Safe, correct **component**, sub-gate standalone. |
| NL | BritNed NL↔GB `BoundaryBook` (cv21/cv23 GB CCGT recipe) | a favorable 2+2-day pilot (NL summer corr +0.088 / MAE −15.5%) was **overturned by the blind 8+8-day confirm**: NL effect ≈0 in summer, winter MAE +11%, and **FR winter corr −0.189** breaches the neighbor gate. |
| IT-NORTH | cv25 all-hours-inframarginal must-run floor (daily-min p5 sizing, €0 bid, IT-scoped) — the corrected mechanism on the corrected (post-registry-fix) base | fixed cv24's evening-thinning failure (evening bias +17.9→+9.3, MAE −6.4%) but no corr gain (−0.021) and a new coupled leak: **over-floors the small southern/island zones** (Sardinia MAE +5.6). Third and final NO-SHIP for the floor family. |

## The converging positive finding

All three residuals decompose into the SAME two footprint-wide **form** gaps,
plus per-zone conduct candidates:

1. **Systemic evening under-pricing** (~−26 €/MWh continental evening bias:
   DE_LU/BE/DK1/CZ/SK/LT/PL/NL all move together; PL h17–18 −47, NL h19 −36).
   Roughly half of each zone's evening error is imported through the coupling —
   per the cv18 lesson it cannot be fixed one zone at a time. This re-points at
   the **peak-scarcity form redesign** (the hyperbolic-scarcity candidate in
   docs/experiments/fit-scarcity) validated on the coupled footprint.
2. **The midday negative-price gap**: the merit book never clears below the
   must-run discount, while 17.8% of NL's settled midday hours (and a growing
   share of IT-NORTH's/PL's solar troughs) ARE negative or near-zero. This is
   the cv18 `export_absorption_steps` / deep-surplus-pricing territory — a
   book-form capability, not a data gap. No ex-ante feed is missing.

Per-zone candidate-conduct residuals (the program's research product, hedged as
hypotheses): **PL** settles ≈+17 €/MWh ABOVE its own peak import source
(DE_LU) while importing +3.5 GW — an import-congestion/conduct premium the
competitive counterfactual arguably should NOT reproduce; **IT-NORTH**'s
evening clears on the real GME cap tail above every SRMC
(docs/experiments/gme-book-comparison) — to be measured, not reproduced.

## Secondary deliverables

- **NEEDS-DATA-FEED (PL)**: API2 (ARA) front-month or Polish PSCMI-1 coal feed,
  threaded exactly like TTF (no-lookahead close cache, fallback to the static
  `FUEL_SRMC_BASE`, byte-identical when absent). Corrects the emerging 2026
  night-level gap (−13), not the evening shape. Spec in
  [pl-diagnosis/DIAGNOSIS.md](pl-diagnosis/DIAGNOSIS.md).
- **Mechanism findings from the IT build** (kept on the experiment branch, not
  shipped): Italy's 1.20× thermal SRMC premium keeps ALL Italian gas below the
  UC-lite commitment threshold (zero must-run trough coverage today), and the
  single-zone `create_merit_order_book` path defaults to `SEE_PROFILE`.
- **Registry-fix attribution**: a large part of the IT "degradation" chased
  here was the corrupt 13 TW unit healed by cv24 (#205) — the corrected
  IT-NORTH trajectory is 0.79 → 0.72 → 0.67 → 0.64, still degrading on the
  solar duck curve.

## Methodology note (twice-confirmed)

Small pilots on coupled mechanisms mislead in BOTH directions: NL's 2+2-day
pilot showed a large clean win that the blind 8+8 confirm erased, and cv18's
history shows the mirror case. The standing bar: blind calendar-picked windows,
≥8 days/season, full 39-zone coupled footprint, neighbors (and Nordic cap-day
counts, for supply-curve levers) inside the pre-registered gate.

Experiment code (harnesses, A/B raw prices, the NO-SHIP src implementations)
lives on the un-merged branches `exp/pl-diagnosis`, `exp/nl-diagnosis`,
`exp/itnorth-diagnosis`; the committed artifact dirs here carry the DIAGNOSIS
records and scored results.
