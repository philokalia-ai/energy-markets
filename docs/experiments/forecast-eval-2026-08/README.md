# Forecast-mode evaluation: physics vs physics+ex-ante-GBM vs pure stats (2026-08-28)

Owner ask: evaluate the full model (physics counterfactual + ex-ante GBM
residual corrector) as a time-series prediction model, with metrics beyond
corr/MAE, against (a) physics alone and (b) a no-physics statistical baseline.

## Arms (all out-of-sample, GroupKFold(5) by day, 729 days 2024-07..2026-06)

- **phys**: the cv37 counterfactual, untouched (zero fitting, zero leakage).
- **full**: phys + per-zone HGB predicting the residual from EX-ANTE features
  only (book demand/RES/import/backstop/margin, D-2 fuel closes, calendar).
- **stats**: per-zone HGB predicting settled directly — NO physics — from
  settled lags (24/48/168h, 7d roll), calendar, fuels, D-1 load & RES.
  (Prophet rejected: additive-seasonality models underperform GBM-with-lags
  on hourly power prices; this is the stronger statistical baseline.)

## Footprint (energy-weighted; naive = same hour last week)

| metric | phys | full | stats |
|---|---|---|---|
| MAE | 23.08 | 14.93 | 14.49 |
| RMSE | 34.26 | 23.55 | 23.12 |
| bias | −1.67 | −0.04 | +0.14 |
| corr | 0.794 | 0.882 | 0.887 |
| rMAE vs naive | 0.81 | 0.52 | 0.49 |
| sMAPE % | 45.5 | 35.1 | 33.9 |
| directional acc | 0.61 | 0.75 | 0.80 |
| spike recall (≥p90) | 0.39 | 0.68 | 0.69 |
| spike precision | 0.77 | 0.73 | 0.74 |
| collapse recall (≤€5) | 0.23 | 0.49 | 0.49 |

Per-zone table: `full_model_metrics.csv` / `full_metrics.txt`.

## Reading, honestly

1. **The ex-ante corrector is worth ~8 MAE points** (23.1→14.9) and doubles
   spike recall — the physics residual is predictably structured (the same
   fact the conduct probe measures) and an ex-ante model captures half of it.
2. **Pure stats edges out physics+GBM on averages** (14.5 vs 14.9 MAE, dir
   0.80 vs 0.75). Fair reading: for *interpolating a stationary regime*,
   lagged prices carry most of the signal. Physics keeps three advantages the
   averages hide: highest spike precision (0.77), zero fitted parameters (no
   leakage of any kind), and input-driven regime portability — a new fuel/RES
   regime moves it correctly on day one, where a lag model needs weeks of new
   history. And only the physics arm is a *counterfactual* — the stats model
   learns the market's conduct into its lags, so it can never measure it.
3. **CV caveat (both ML arms)**: GroupKFold shuffles days, so models train on
   days after each test day. A strict forward-chaining evaluation would be
   somewhat worse for both ML arms (physics unaffected). The full-vs-stats
   ranking is fair (same CV); the ML-vs-physics gap is slightly flattered.
4. **Live-regime warning (2026-08-28)**: the ENTSO-E account outage (since
   08-25) has starved the live D-1 inputs; yesterday's lead-1 under-forecast
   ALL zones by −23..−106 €/MWh (DE_LU 80 vs 160 settled). No corrector fixes
   an input outage; the account re-validation is the fix.

Tomorrow-corrector plumbing: `gbm_correct.py` (per-hour features captured via
the strategist hook, sub-hourly slots averaged into hours; corrections clipped
to the zone's same-month residual envelope before use).
