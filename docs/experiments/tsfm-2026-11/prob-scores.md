# Probabilistic scores for the TSFM quantiles (#431, PR F part 1)

**What this is:** an offline scoring of the quantiles and P(price ≤ 0) that were already saved.
Nothing is re-forecast and nothing live changes. Script: [`prob_scores.py`](prob_scores.py);
tests: `test/test_tsfm_prob_scores.py` (19). Outputs go to `$TSFM_OUT/prob431/*.csv`, which is
not committed.

## Coverage of the evaluation

| set | cells | zones × days | notes |
|---|---|---|---|
| backtest, common | 54,231 | 39 × 58 (2026-09-14..11-13) | the README's common set, asserted |
| **backtest, on-time** (primary) | **47,679** | 39 × 51 | excludes the 7 days whose lead-1 `sim` came after D-1 10:00 UTC |
| backtest, on-time ex-IT | 39,200 | 32 × 51 | |
| conformal evaluation | 26,247 | 39 × 28 (10-14..11-13) | days ≥ 28 days after the zone's first day; the trailing 28-calendar-day window holds 18–25 distinct on-time market days (median 20), 384–601 cells |
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
  - **Calibration.** The zone's on-time cells in the **trailing 28 calendar days D-28..D-1,
    strictly before D.** D-1's prices are public at the D-1 06:30 issue.
    - The 7 late-sim days are excluded from the cohort, so a window holds fewer than 28 market
      days: **18–25 distinct calibration days, median 20, and 384–601 cells (median 481)** per
      zone-day.
    - **Eligibility is per zone:** D must be ≥ 28 days after *that zone's* first day, and the
      window must hold **≥ 14 distinct calibration days**, the declared minimum usable sample. In
      this run every zone starts on 09-14 and the minimum realised is 18, so nothing is excluded.
  - **Evaluation:** 10-14..11-13, 28 days, 26,247 cells.
- **Band policy.** A negative offset narrows the band, and a large one can **invert** it
  (lo′ > hi′). Two policies are reported (`adjust_band`):
  - **`signed`** is standard CQR. An inverted band is the *empty* prediction set. It is never
    shown as a band of negative width: it is scored as a zero-width interval at the midpoint
    (it misses unless y equals that point) and counted.
  - **`widen`** clips offsets at 0. It never narrows and never inverts, so it is the only policy
    that can be published as an ordered q10 ≤ q90 pair.
- **Tests:**
  - calibration days are strictly before D;
  - changing future rows leaves earlier offsets unchanged, and raw quantiles are unchanged;
  - eligibility is per zone, and sparse windows are refused;
  - the band policies behave as specified.

**Inversions under `signed`** (all 39 zones, on-time, out of 26,247 cells):

| arm | 50 % | 80 % | 90 % |
|---|---|---|---|
| t209_uni | 30 (0.11 %) | 8 (0.03 %) | 5 (0.02 %) |
| c2_uni | 19 (0.07 %) | 6 (0.02 %) | 11 (0.04 %) |
| t209_sim | 25 (0.10 %) | 11 (0.04 %) | 5 (0.02 %) |

Negative offsets, i.e. a narrowed band, occur on 16–24 % of cells for Timestral and 4–6 % for
Chronos-2 (`neg_offset_share`). Under `widen`, those cells keep the raw band.

**Results, before → after, all 39 zones, on-time:**

| arm | level | policy | coverage | width | pinball lo | pinball hi | interval score | per-zone coverage after |
|---|---|---|---|---|---|---|---|---|
| t209_uni | 50 | signed | 0.463 → 0.496 | 43.1 → 46.0 | 12.08 → 12.13 | 12.72 → 12.69 | 99.19 → 99.28 | 0.44–0.56 |
| t209_uni | 50 | widen | 0.463 → 0.503 | 43.1 → 46.3 | 12.08 → 12.13 | 12.72 → 12.68 | 99.19 → 99.23 | 0.46–0.61 |
| t209_uni | **80** | signed | 0.746 → 0.783 | 85.1 → 92.4 | 6.871 → 6.877 | 7.765 → 7.711 | 146.4 → 145.9 | 0.73–0.83 |
| t209_uni | **80** | **widen** | **0.746 → 0.788** | 85.1 → 92.6 | 6.871 → 6.875 | 7.765 → 7.706 | 146.4 → 145.8 | 0.74–0.84 |
| t209_uni | 90 | signed | 0.857 → 0.887 | 114.4 → 124.5 | 4.089 → 4.093 | 4.932 → 4.898 | 180.4 → 179.8 | 0.84–0.93 |
| t209_uni | 90 | widen | 0.857 → 0.892 | 114.4 → 124.8 | 4.089 → 4.091 | 4.932 → 4.891 | 180.4 → 179.6 | 0.86–0.93 |
| c2_uni | **80** | signed | 0.711 → 0.779 | 81.8 → 92.9 | 7.173 → 7.125 | 8.417 → 8.237 | 155.9 → 153.6 | 0.73–0.85 |
| c2_uni | **80** | **widen** | **0.711 → 0.781** | 81.8 → 92.9 | 7.173 → 7.123 | 8.417 → 8.236 | 155.9 → 153.6 | 0.73–0.85 |
| t209_sim | **80** | signed | 0.743 → 0.777 | 75.9 → 82.3 | 5.933 → 5.963 | 7.191 → 7.088 | 131.2 → 130.5 | 0.74–0.83 |
| t209_sim | **80** | **widen** | **0.743 → 0.783** | 75.9 → 82.6 | 5.933 → 5.957 | 7.191 → 7.082 | 131.2 → 130.4 | 0.74–0.84 |

Ex-IT, t209_uni 80 %: 0.738 → 0.783 (signed) / 0.787 (widen). All rows are in `conformal.csv`.

**Reading.**
- **Coverage.** Pooled 80 % coverage moves into Fable's 77–83 % acceptance band for all three arms
  under both policies: signed 0.777–0.783, widen 0.781–0.788. Under widen, 50 % ends within 1.2
  points of nominal (t209_uni 0.503, just above), and 90 % ends 0.8–1.7 points short.
- **Interval score** improves at 80 % and 90 % under both policies, slightly more under widen.
- **Pinball loss.**
  - The **upper endpoint's pinball improves** in every arm.
  - The **lower endpoint's** gets marginally worse for Timestral under widen: +0.06 % for t209_uni
    and +0.4 % for t209_sim. It improves for Chronos-2.
  - The q50 is untouched.
  - Net endpoint pinball is lower in every arm.
- **Per-zone coverage** still ranges 0.73–0.85 at 80 %. A zone's window holds 384–601 cells, so
  zone-level coverage stays noisy.

**Proposal (owner/leader decision, not implemented).** A `TSFM_CONFORMAL=1` follow-up, default
off, under the **widen-only** policy: q10 − max(off, 0) and q90 + max(off, 0), with the per-zone CQR
offset from the trailing 28 calendar days (≥ 14 calibration days) of settled prices.
- Widen-only, because signed CQR can produce empty sets (0.02–0.04 % of cells at 80 %), which
  cannot be published as a band.
- It meets the brief's bar only in a qualified sense:
  - coverage is fixed: 0.781–0.788;
  - summed endpoint pinball and interval score are better;
  - one endpoint is +0.06 % (prices only) / +0.4 % (with `sim`) worse for Timestral.
- The evidence is 28 evaluation days in one autumn window.
- A live flag should log both the raw and the widened band, so it can be re-checked on the first
  28 live days.

## Live

- **Live keeps only q10/q50/q90 and p_le0 / p_any_le0.** `prob_scores.py --live-api DIR`
  (`live_report`) scores them from the public zone JSONs and writes `live.json`,
  `live_reliability_bins.csv` and `live_alarms.csv`. Each block carries its source label, arm(s),
  mode(s) and counts:
  - **quantiles:** pinball of q10/median/q90, and inclusive 80 % coverage and width;
  - **hourly probability:** the published `p_le0` (the 50/50 blend, or the TSFM-only fallback)
    against actual ≤ 0. Scored with Brier and the Murphy decomposition, the same reliability bins,
    and alarms at 0.1/0.3/0.5;
  - **day probability:** the published `p_any_le0` against "any hour of the Athens day ≤ 0",
    scored the same way. Only days on which every overlay hour has a settled actual are scored;
    incomplete days are counted.
- **Repeated rows must agree.** The API repeats each day's overlay on every lead/input-mode row.
  Any disagreement in values (`tsfm`, the quantiles, `p_le0`, `p_any_le0`) or provenance (issue,
  arm, mode) between repeats of the same (zone, hour) or (zone, day) is an error.
- **Tests.** An integration test runs the whole live path on a nonempty fixture: 24 hours, one
  negative actual. It checks that the day Brier moves from 0.9025 to 0.0025 when `p_any_le0` goes
  from 0.05 to 0.95.
- **On 2026-11-16 at 19:30 UTC, all 39 zone JSONs at `api.philokalia.ai/api/v1/zones/<Z>` had no
  non-null `tsfm`/`tsfm_q10`/`p_le0` value on any day.** That covers my fetch and collapse's
  `live-20261116` snapshot (19:28 UTC), and rerunning on the snapshot gives 0 overlay hours and 0
  overlay days. The local extract (2026-11-15) has no
  `simulations.tsfm_overlay` table either.
- So the live sample is **0 cells**. There is nothing to report until overlay rows and their
  settled actuals exist.
