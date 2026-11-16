# Probabilistic scores for the TSFM quantiles (#431, PR F part 1)

**What this is:** an offline scoring of the quantiles and P(price ≤ 0) that were already saved.
Nothing is re-forecast and nothing live changes. Script: [`prob_scores.py`](prob_scores.py);
tests: `test/test_tsfm_prob_scores.py` (13). Outputs go to `$TSFM_OUT/prob431/*.csv`, which is
not committed.

## Coverage of the evaluation

| set | cells | zones × days | notes |
|---|---|---|---|
| backtest, common | 54,231 | 39 × 58 (2026-09-14..11-13) | the README's common set, asserted |
| **backtest, on-time** (primary) | **47,679** | 39 × 51 | excludes the 7 days whose lead-1 `sim` came after D-1 10:00 UTC |
| backtest, on-time ex-IT | 39,200 | 32 × 51 | |
| conformal evaluation | 26,247 | 39 × 28 (10-14..11-13) | days with a full 28-day calibration window; median 481 calibration cells per zone-day |
| day-level P(any hour ≤ 0) | 1,986 zone-days (on-time) | | 2,259 overall; labels identical to collapse's (0 disagreements) |
| **live overlay rows** | **0** | | see "Live" below |

- **Arms**, all lead 1 with settled prices through D-1, are *raw TSFM*:
  - `t209_uni` = Timestral-209M on prices only, label (a) 06:30;
  - `c2_uni` = Chronos-2 on prices only, label (a);
  - `t209_sim` = Timestral-209M with the live `sim` as a covariate, label (a′) post-sim, ≈10:15 UTC.
- **The blends only exist for P(≤ 0).** The hourly blend is 50/50 with collapse's D-1 logistic; the
  day blend is 50/50 with collapse's day logistic. The quantiles are always raw TSFM.
- **Chronos-2 quantile crossings.** 699 Chronos-2 rows had crossed quantiles; they are sorted
  (monotone rearrangement) and counted. Timestral had none.

## 1. Pinball loss and the grid CRPS (backtest only)

On-time cells (47,679), in €/MWh. The full 21-level table is in `pinball.csv`.

| arm | q01 | q05 | q10 | q25 | q50 | q75 | q90 | q95 | q99 | mean of q10/q50/q90 | mean of 21 | **CRPS (21-grid approx.)** | MAE of median |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| t209_uni (a) | 0.97 | 3.69 | 6.25 | 11.15 | 14.11 | 11.91 | 7.27 | 4.63 | 1.41 | 9.21 | 9.82 | **20.45** | 28.21 |
| c2_uni (a) | 1.07 | 3.88 | 6.51 | 11.50 | 14.60 | 12.40 | 7.73 | 5.02 | 1.72 | 9.62 | 10.22 | **21.27** | 29.21 |
| t209_sim (a′) | 0.87 | 3.23 | 5.45 | 9.86 | 12.63 | 10.67 | 6.48 | 4.08 | 1.26 | 8.19 | 8.75 | **18.22** | 25.27 |

- **How the CRPS is computed.** It is `2 · Σ_k w_k · QS_{τ_k}`, where each level's weight is the width
  of its cell on [0, 1]. The tails beyond 1 % and 99 % are scored with the outer quantiles.
  - It is an **approximation from the saved 21-quantile grid, backtest only.** The unit test puts it
    within 8 % of the closed form for a normal.
  - Live saves only q10/q50/q90, so **no CRPS is reported for live**; the mean of the three
    pinballs is the live-comparable number.
- **Ranking.** Every level ranks the arms the same way as MAE: `t209_sim` < `t209_uni` < `c2_uni`.

## 2. Central-interval coverage and width (inclusive endpoints)

On-time cells (47,679). `below`/`above` are the shares of actuals outside the interval on each side.

| arm | 50 %: cov / width | **80 %: cov / width** | 90 %: cov / width | 98 %: cov / width | 80 %: below / above |
|---|---|---|---|---|---|
| t209_uni (a) | 0.466 / 40.3 | **0.752 / 79.8** | 0.862 / 106.8 | 0.971 / 172.9 | 0.120 / 0.128 |
| c2_uni (a) | 0.420 / 38.0 | **0.715 / 76.5** | 0.839 / 104.7 | 0.962 / 173.5 | 0.137 / 0.148 |
| t209_sim (a′) | 0.462 / 35.9 | **0.756 / 71.1** | 0.866 / 95.1 | 0.973 / 153.3 | 0.117 / 0.127 |

- **Every interval is too narrow.** The 80 % interval covers 72–76 %.
- **Misses fall on both sides about equally**, slightly more above. The intervals are
  under-dispersed, not biased.
- Ex-IT figures are about 1 point lower (`intervals.csv`).

## 3. P(price ≤ 0): reliability

On-time cells. Brier ≈ REL − RES + UNC on the bins [0, .01, .05, .1, .2, .4, .6, .8, 1].

| level | source | n | events | base rate | mean p | Brier | REL ↓ | RES ↑ |
|---|---|---|---|---|---|---|---|---|
| hour | raw TSFM (t209_uni) | 47,679 | 640 | 0.0134 | 0.0172 | 0.00922 | 0.00019 | 0.00411 |
| hour | collapse logistic | 47,679 | 640 | 0.0134 | 0.0096 | 0.00959 | 0.00016 | 0.00373 |
| hour | **hourly blend (t209_uni)** | 47,679 | 640 | 0.0134 | 0.0134 | **0.00881** | 0.00039 | 0.00479 |
| hour | hourly blend (t209_sim) | 47,679 | 640 | 0.0134 | 0.0149 | 0.00859 | 0.00021 | 0.00470 |
| day | max-hour TSFM (t209_uni) | 1,986 | 134 | 0.0675 | 0.0611 | 0.04280 | 0.00110 | 0.02068 |
| day | collapse day logistic | 1,986 | 134 | 0.0675 | 0.0438 | 0.04421 | 0.00193 | 0.02058 |
| day | **day blend (t209_uni)** | 1,986 | 134 | 0.0675 | 0.0525 | **0.04113** | 0.00248 | 0.02365 |

Reliability bins for t209_uni (on-time):

| p bin | raw TSFM hourly: n / mean p / observed | hourly blend: n / mean p / observed | day blend: n / mean p / observed |
|---|---|---|---|
| < 0.01 | 39,192 / 0.005 / 0.0004 | 39,837 / 0.003 / 0.0004 | 953 / 0.004 / 0.004 |
| 0.01–0.05 | 5,612 / 0.025 / 0.012 | 5,668 / 0.022 / 0.015 | 567 / 0.025 / 0.016 |
| 0.05–0.1 | 1,317 / 0.068 / 0.072 | 982 / 0.069 / 0.099 | 202 / 0.070 / 0.079 |
| 0.1–0.2 | 846 / 0.136 / 0.149 | 525 / 0.141 / 0.183 | 127 / 0.138 / 0.220 |
| 0.2–0.4 | 420 / 0.279 / 0.350 | 420 / 0.283 / 0.360 | 82 / 0.281 / 0.439 |
| 0.4–0.6 | 206 / 0.504 / 0.655 | 175 / 0.479 / 0.709 | 35 / 0.493 / 0.600 |
| 0.6–0.8 | 66 / 0.665 / 0.621 | 64 / 0.684 / 0.953 | 18 / 0.708 / 1.000 |
| ≥ 0.8 | 20 / 0.893 / 0.800 | 8 / 0.926 / 1.000 | 2 / 0.900 / 1.000 |

- **Raw TSFM.** It over-forecasts in the low bins: below 0.05, mean p is 2–12× the observed
  frequency. It under-forecasts at 0.2–0.6, which is where the README's "over-dispersed" (mean p
  0.017 vs base 0.013) comes from.
- **Blend.** It fixes the low-bin bias and is calibrated on average (mean p = base rate, 0.0134),
  but it is **under-confident above p ≈ 0.4**: a 0.48 forecast verifies 71 % of the time, and 0.68
  verifies 95 %.
  - Its REL is higher than either input's. It wins on Brier through resolution.
  - A monotone recalibration (isotonic or Platt on a rolling window) would help, but was not
    tested here.
- **Alarms at the site badge threshold** (p ≥ 0.3, hourly, on-time; full table in `alarms.csv`):

  | source | alarms | precision | hit rate |
  |---|---|---|---|
  | raw TSFM | 439 | 0.58 | 0.40 |
  | logistic | 408 | 0.59 | 0.38 |
  | blend | 396 | 0.60 | 0.37 |

  At p ≥ 0.5 the blend's precision is 0.92 (118 of 129).

## 4. Split-conformal recalibration (offline, not wired live)

- **Specification, fixed before scoring:** conformalised quantile regression (CQR) on the central
  interval.
  - **Per zone, additive.** The score is `max(lo − y, y − hi)`, and the offset is its
    `⌈(n+1)·level⌉`-th smallest value.
  - **Calibration** uses the zone's on-time cells on the **28 market days D-28..D-1, strictly before
    D.** D-1's prices are public at the D-1 06:30 issue.
  - **Evaluation** is only on days with a full window: 10-14..11-13, 28 days, 26,247 cells.
- **Tests** check that the calibration days are strictly before D, that changing future rows leaves
  earlier offsets unchanged, and that the raw quantiles are unchanged.

Results, before → after, on all 39 zones, on-time:

| arm | level | coverage | width | pinball lo | pinball hi | interval score | per-zone coverage range after |
|---|---|---|---|---|---|---|---|
| t209_uni | 50 | 0.463 → 0.496 | 43.1 → 46.0 | 12.08 → 12.13 | 12.72 → 12.69 | 99.19 → 99.28 | 0.44–0.56 |
| t209_uni | **80** | **0.746 → 0.783** | 85.1 → 92.4 | 6.871 → 6.877 | 7.765 → 7.711 | 146.4 → 145.9 | 0.73–0.83 |
| t209_uni | 90 | 0.857 → 0.887 | 114.4 → 124.5 | 4.089 → 4.093 | 4.932 → 4.898 | 180.4 → 179.8 | 0.84–0.93 |
| c2_uni | **80** | **0.711 → 0.779** | 81.8 → 92.9 | 7.173 → 7.125 | 8.417 → 8.237 | 155.9 → 153.6 | 0.73–0.85 |
| t209_sim | **80** | **0.743 → 0.777** | 75.9 → 82.3 | 5.933 → 5.963 | 7.191 → 7.088 | 131.2 → 130.5 | 0.74–0.83 |

Ex-IT: t209_uni 80 % 0.738 → 0.783. All rows are in `conformal.csv`.

**Reading.**
- **Coverage.** Pooled 80 % coverage moves into Fable's 77–83 % acceptance band for all three arms
  (0.777–0.783). The 50 % and 90 % levels end 0.4–2 points short of nominal.
- **Interval score** improves slightly at 80 % and 90 %.
- **Pinball loss.**
  - The **upper endpoint's pinball improves** in every arm.
  - The **lower endpoint's** gets marginally worse for Timestral: +0.1 % for t209_uni and +0.5 %
    for t209_sim. It improves for Chronos-2.
  - The q50 is untouched.
  - Net endpoint pinball is lower in every arm.
- **Per-zone coverage** still ranges 0.73–0.85 at 80 %. A 28-day per-zone window holds ~480
  cells, so zone-level coverage stays noisy.

**Proposal (owner/leader decision, not implemented).** A `TSFM_CONFORMAL=1` follow-up, default
off, would widen the published q10/q90 by the per-zone CQR offset from the trailing 28 days of
settled prices. It meets the brief's bar only in the qualified sense above: coverage is fixed;
summed endpoint pinball and interval score are better; one endpoint is +0.1 % worse for
Timestral. The evidence is 28 evaluation days in one autumn window. A live flag should log both
the raw and the widened band, so it can be re-checked on the first 28 live days.

## Live

- **Live keeps only q10/q50/q90 and p_le0 / p_any_le0.** `prob_scores.py --live-api DIR` scores them
  from the public zone JSONs: pinball on the three levels, 80 % coverage and width, and the
  Brier/reliability of p_le0.
- **On 2026-11-16 at 19:30 UTC, all 39 zone JSONs at `api.philokalia.ai/api/v1/zones/<Z>` had no
  non-null `tsfm`/`tsfm_q10`/`p_le0` value on any day.** The local extract (2026-11-15) has no
  `simulations.tsfm_overlay` table either.
- So the live sample is **0 cells**. There is nothing to report until overlay rows and their
  settled actuals exist.
