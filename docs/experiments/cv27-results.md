# cv27 — FBMC capability / spill-risk / negative floor: measured NO-SHIP

Run 2026-07-30..31 per the frozen `docs/cv27-import-hydro-prereg.md` (gates
frozen by merge before any scored arm; owner reviews RESULTS, per the
2026-07-30 process directive). Arms on the cv26 baseline, 24 ratified Set-A
days (incl. the declared melt months), 22,464 scored cells per arm, per-cell
harness, HiGHS. All-off guard bit-identical to cv26 main (1032/1032); T2
polarity proven at book level (NORDIC profile: valley 31.3→0.0, peaks
untouched — note: single-zone `create_merit_order_book` defaults to
SEE_PROFILE, which cost three probe iterations to discover).

## Set A

| arm | MAE | corr | ΔMAE | Δcorr |
|---|---|---|---|---|
| cv26 | 31.58 | 0.692 | — | — |
| all (T1+T2+T3) | 30.58 | 0.711 | −0.99 | +0.019 |
| loo_T1 | 31.41 | 0.697 | (T1: −0.82) | |
| loo_T2 | 30.72 | 0.709 | (T2: −0.14) | |
| loo_T3 | 30.61 | 0.710 | (T3: −0.02) | |
| allb (T1b amendment) | 31.43 | 0.699 | −0.14 | +0.007 |

Zero cap hours in every arm. Set B not scored (no arm passed A).

## Verdicts (per the frozen falsifiers)

- **T1 (unscoped demonstrated capability): FAIL on the envelope** — DE_LU
  +3.74 / AT +3.25 MAE — despite the largest aggregate gain measured this
  program (SI −6.1 MAE corr 0.642→0.732, IT-Sicily −3.6 corr →0.828, CZ corr
  0.605→0.757, NL −3.1, IT-family −3..−4).
- **T1b (declared amendment: only borders that HAD Day-ahead history and lost
  it): FAIL, differently** — DE_LU/AT healed but DK2 +10.94 (asymmetric
  border overrides distort net flows), SK +3.34, corr breaches
  NO1/NO3/SE3/IT-Sardinia, and the SI/CZ/NL wins VANISHED. The decisive
  finding: **the unscoped T1's gains came mostly from the never-DA Core
  borders, not the Nordic ones** — capacity re-basing interacts with the
  cv17-era calibration border-by-border and cannot ship under a global rule.
  A border-scoped program (cv17/cv22-style, per-border gates) is the path.
- **T2 (spill-risk valley): FAIL its gates, close on one** — NO3 median daily
  shape corr 0.417→0.546 (gate ≥0.55, near-miss), Nordic bad-day share
  unchanged 0.236→0.235 (gate ≤0.12, clear miss), NO4 corr −0.062 breach
  (its flat export-congested price gains structure it does not have —
  exclude NO4 in any revival).
- **T3 (deep-surplus −20 floor on must-run): INERT** — zero negative sim
  hours; the RES block at +€1 stays marginal long before the −20 tranche.
  Confirmed by the public-book comparison (same day): the real gap is the
  FULL price-taker floor — 20–78% of real offered supply at ≤0 €/MWh
  including RES/RoR/cogen — not a must-run-only tweak.

## What this round proved

1. The FBMC/intraday capacity surface is worth ~1 MAE + 0.02 corr on the
   footprint — the largest single lever measured since Phase 4 — but ships
   only as a bordered program with per-border gates.
2. Spill-risk pricing moves NO3's shape exactly as designed and nothing else;
   it needs a companion (price floor, NO4 exclusion) to clear its own gates.
3. Negative pricing must start from the price-taker floor (public-book
   evidence: GME/OMIE 20–78%/26–42% of supply ≤0; our books 0%) — the
   highest-priority next treatment, together with zone-aware hydro placement
   (Italy price-taking vs Iberia cap-priced; measured dP evening +121 NORD /
   −40 Iberia midday).

`feat/cv27-import-hydro` stays UNMERGED (cv stays 26). Raw cells
`scratchpad/p7/`, scorers `score_cv27.py`, transcripts `cv27_scores_A.txt`;
public-book protocol + metrics in `scratchpad/pubbooks/`.
