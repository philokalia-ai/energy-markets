# Model lines: the rolling-origin test they never had

**Question.** The model-line emitter reads cv37 book features with a frozen
cv37-trained artifact while the record has moved to cv39 and forecasts to
cv40. Retraining on the cv39 books looked like plain hygiene. Before swapping
it in, it was tested chronologically — the honest evaluation the 2026-09-01
review asked for and which this model line had never had.

**Setup.** `scripts/build_probe39.py` builds a cv39 training set: features from
the cv39 books, physics from the cv39 record, and the target is the **canonical
SDAC settlement view**, not the blended average (681,666 rows, 39 zones,
2024-07-01..2026-06-30, `manifest.json` beside it).
`scripts/rolling_origin.py` then splits the last year into four consecutive
quarters; each is predicted only from data **before** it. Four configurations
on identical cells (341,256):

| configuration | MAE | bias | corr |
|---|---|---|---|
| physics alone (cv39 record) | 23.30 | −4.61 | 0.778 |
| **physics + hybrid residual, retrained per fold** | **24.70** | +2.05 | 0.765 |
| physics + the frozen cv37 artifact | *15.66* | +0.44 | *0.891* |
| stats-only GBM, retrained per fold | **21.05** | −1.30 | 0.824 |

## Two findings

**1. The frozen artifact's 15.66 is an in-sample fit, not skill.**
`probe2y37_dataset.parquet` spans 2024-07-01..2026-06-30 — it covers every
test fold. The frozen model beats the retrained one in 39 of 39 zones, which
is what memorisation looks like, not generalisation. Any backtest of the
model lines over that window using this artifact is reporting a fit.
*This does not impugn the live overlay*: the artifact's training data ends
2026-06-30, so the lines published for July 2026 onward are genuine
out-of-sample predictions. The affected claims are historical comparisons on
the training window, including the 14.93 MAE / 0.882 corr headline in
`docs/experiments/forecast-eval-2026-08`, which used GroupKFold over random
days — folds that leak neighbouring hours of the same regime.

**2. Retraining does not rescue the hybrid line — out of sample it is worse
than the physics it corrects.** 24.70 against 23.30, bias flipping −4.61 →
+2.05, correlation 0.778 → 0.765. It is also unstable: it wins 84 of 156
zone-folds, essentially a coin flip, and loses catastrophically where it
loses — BG +32.8, HU +15.2, RO +10.0, AT +9.2 MAE against physics. Only
**7 of 39 zones win in all four folds**: IT-NORTH, IT-CNORTH, IT-CSOUTH,
IT-SOUTH, IT-Calabria, SE1, SE2 — where it is worth −3 to −8 MAE. By fold the
hybrid loses in three of four (fold 2: 28.36 vs 20.04).

**The stats line, by contrast, generalises**: 21.05 vs 23.30 physics, 105 of
156 zone-folds, better bias and correlation.

## What follows

- **Do not promote a globally retrained hybrid.** The retrain is built and
  reproducible, but shipping it would replace an in-sample-flattered line
  with an out-of-sample-worse one.
- **The defensible options**, in order: keep the stats line as the GBM
  overlay; restrict the hybrid to the seven zones that win every fold, after
  validating on a later held-out block; or retire the hybrid overlay.
- **Whatever ships, the published comparison must be rebuilt** on
  rolling-origin folds against the canonical SDAC target, never GroupKFold.
- Production is unchanged by this experiment: the emitter still runs
  `MODEL_LINES_CV=37` with its own artifact, and now refuses a mismatch.
- Separate defect, unrelated to the retrain: the emitter's physics base is
  selected from `simulations.forecast_prices` with **no code-version
  restriction**, so it already mixes cv37/cv39/cv40 vintages. Pinning it is a
  prerequisite for any version binding to mean anything.

**Coverage.** Four folds × 91–92 days, 39 zones, 341,256 scored cells, target
= canonical SDAC. Threads capped (`OMP_NUM_THREADS=4`) because the box is
shared. The per-fold stats line is computed with lags built strictly backward
per zone; an earlier draft of this script applied the 168-hour rolling mean
across zone boundaries and was corrected before the run.
