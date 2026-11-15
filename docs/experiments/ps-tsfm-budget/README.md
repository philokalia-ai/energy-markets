# Timestral forecast of the cv44 pumped-storage budget — gate-1 FAIL (2026-11-15)

**Idea** (planner-p2, idea 1). Replace the cv44 budget E₁₄, the 14-day mean of
daily PS generation, with **0.5·E₁₄ + 0.5·Ê**. Ê is the sum of non-negative
Timestral-209M median forecasts of delivery-day hourly PS generation. The
blend is capped at 24 × the trailing-30-day p95 hourly output.

**Setup**
- Context: 2,048 h, ending at the lead-1 cutoff D-1 00:00 UTC, the same
  cutoff `_storage_cutoff_day` uses.
- No fitting and no price input.
- Days: the 8 calibration days.
- Coverage: 158 zone-days in 20 PS zones, of which 102 zone-days in 19 zones
  have both D and D-7 fully observed. 49 zone-days lack a complete
  delivery-day actual, mostly at the end of the extract.

**Result.** Mean absolute error of daily MWh on the 102 complete zone-days:

| Budget | MAE (MWh/day) | Bias |
|---|---|---|
| E₁₄ | 3,366 | +23 |
| D-7 | 3,330 | −167 |
| Ê | 3,067 | −590 |
| Blend | 3,191 | −283 |

The blend improves on E₁₄ by **+5.2 %** and on D-7 by **+4.2 %**; the gate was
≥ 10 % against both. Timestral alone reaches only +8.9 % and +7.9 %.

**Gate 1 fails, so no paired clears were run** (pilot contract).

Why: daily PS generation is endogenous dispatch, driven by the delivery day's
spreads, wind and solar. Its own history barely predicts it.
- Errors are about 30–40 % of the daily energy for every predictor; the median
  relative error is 0.36 for E₁₄ and 0.32 for the blend.
- The large zones dominate the result, and Timestral helps some and hurts
  others:

  | Zone | E₁₄ | Ê | D-7 |
  |---|---|---|---|
  | ES | 5,274 | 7,283 | |
  | CH | 8,489 | 9,164 | |
  | DE_LU | 10,205 | 7,808 | |
  | AT | 6,974 | 4,570 | 4,565 |

- Timestral's systematic under-forecast (bias −590) is halved by the blend but
  remains.

A useful budget forecast would need the drivers (forecast spread, RES) rather
than univariate history. The circularity caveat applies: generation is
dispatch, not stored energy. Archived; the cv44 budget stays E₁₄.

Script: `gate1_budget.py`. Output: `em-team/results/blocks/p2_gate1.csv`.
