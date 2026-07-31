# cv29 — the surplus-regime book: measured NO-SHIP, with the two redesign targets

Run 2026-07-31 per the frozen `docs/cv29-surplus-regime-prereg.md` (#239).
22,464 cells/arm, 24 Set-A days, all-off guard 1032/1032, polarity proven
(ES 7 surplus hours floor↔none; IT banded 8.4 GW; Sardinia ×0.5).

| arm | MAE | corr | Δ vs cv26 |
|---|---|---|---|
| cv26 | 31.58 | 0.692 | — |
| all | 39.46 | 0.317 | +7.89 / −0.375 |
| loo_T3 (no haircut) | **32.01** | **0.699** | +0.44 / +0.007 |
| loo_T1 / loo_T2 / loo_T4 | 38.97–39.66 | ~0.31 | (all contain T3) |

## Verdicts

- **T3 (small-IT domestic-offer haircut): CATASTROPHIC FAIL and the round's
  dominant error.** Sardinia +110 MAE, CSOUTH +84, CNORTH +81, 48 new cap
  hours. The design mistake, now measured: the public-book vol ratio compares
  our book to the GME *curve*, but self-scheduled units still PHYSICALLY
  generate — deleting their capacity deletes real energy and manufactures
  scarcity. **Redesign target: the self-scheduled share moves to the
  price-taker block (it runs regardless of price); it is never removed.**
- **T1 (conditional floor): conditionality insufficient.** Phantom rate 18%
  (cv28 blanket) → 16.4% — far above the 2% gate; hit-rate fell to 29%
  (140/489); the signal never fires in SE3 (whose negatives come with
  imports). **Redesign target: the surplus signal must include the import
  side, and the falsifier stands.**
- **T2 (banded placement): mildly positive** (−0.10 MAE inside the package;
  Iberia evening 27.6→26.7 with corr up) — direction confirmed twice now.
- **T4 (spill valley with floor, NO4 excluded): mildly positive** (−0.20 MAE,
  +0.007 corr) and **its shape gate now PASSES: NO3 median 0.417→0.551
  (≥0.55), NO4 unharmed (0.672 both).**
- The T1+T2+T4 combination without T3 is near-neutral overall (+0.44 MAE /
  +0.007 corr) — not shippable under the gates, but it carries the first
  passing NO3 shape gate of the program.

## Disposition

`feat/cv29-surplus-regime` UNMERGED; cv stays 26. Next round (one prereg,
two redesigns): price-taker reallocation for self-scheduling + an
import-aware surplus signal, with T2/T4 carried as-is (twice-confirmed mild
positives). Cells `scratchpad/p9/`.
