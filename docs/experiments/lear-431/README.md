# LEAR pilot: DE_LU and GR, prices and calendar only (#431, PR F part 2)

**Question.** How does a standard statistical EPF benchmark, LEAR (Lago et al. 2021), do on our
zones, cells and target, and how does it compare to the naives, the live physics and the GBM
lines, and to Timestral?

**What this is.** An offline research pilot: two zones, one fixed specification, a chronological
split and hyperparameters locked before the test. No production integration and no
`code_version` change.

## Specification

- **Model.** A clean-room reimplementation of LEAR (`lear.py`). epftoolbox is not imported or
  vendored. Its licence is Apache-2.0, not AGPL as the plan believed, but it is still not a
  dependency.
  - One Lasso per delivery slot.
  - Features: prices of D-1, D-2, D-3 and D-7 (24 slots each), plus 7 weekday dummies.
  - Scaling: "invariant" asinh with median/MAD.
  - α is chosen by LassoLarsIC(AIC), then a Lasso refit.
  - The noise variance is var(y), the sklearn < 1.1 behaviour epftoolbox was built on. Newer
    sklearn refuses to estimate it when the window is shorter than the 103 features. This was
    set for every window before any score was seen.
- **Recalibration.** Daily, on the W market days D-W..D-1.
- **Target.** SDAC only. DE_LU uses sequence 1; its sequence 2 is EXAA and is never used. GR uses
  its single series.
  - The rule is PR C's `sdac` policy: latest revision, the finest complete resolution per hour,
    duration-weighted mean.
  - It is identical to collapse's benchmark-431 SDAC helper on all 69,406 zone-hours, with a
    maximum difference of 1e-13.
- **Market day and information set.**
  - The market day is the Europe/Athens day, with 24 local slots. On the 23-h day the missing
    hour is interpolated for features and training targets only. On the 25-h day the repeated
    hour is averaged as a source, and both UTC hours get its forecast.
  - The forecast for day D uses settled prices of days before D only; the latest is D-1,
    auctioned on D-2. That matches the TSFM `*_L1` runs and the nominal D-1 06:30 UTC issue.
- **Schedule, fixed in advance.**
  - Data: 2022-12-01 onward.
  - **Validation 2024-01-01..06-30**: W ∈ {56, 84, 182, 364} or their mean, chosen per zone by
    validation MAE.
  - **Locked: W = 364 for both zones** (`hparams.json`). It was committed and pushed as
    48a9ca3 at 19:38 UTC, *before* the test run.
  - **Test 2024-07-01..2026-11-13**: 866 days × 2 zones. There was one test run and no reruns.
- **Compute.** 0.6 s per day-fit (24 Lassos). Validation took 57 s and test 65 s on 16–20
  cores, far inside the one-day budget.
- **Scoring.** collapse's benchmark-431 contract (`evaluate.py`, `benchmark-431-v1`), imported by
  path. It provides:
  - the naives: d1, d7, and epf (D-1 on Tue–Fri, D-7 on Sat–Mon), keyed by Athens date and hour;
  - rMAE as the ratio of matched aggregate MAEs;
  - a one-sided daily-vector DM test (L1 loss, Bartlett HAC with lag 7, complete 24-h days only).

## The second arm (D-1 load/RES forecasts + fuels lagged 2 days) is dropped

The brief allows the arm only where the vintages are authentic. Neither zone has them.

`audit_vintages.py` reports the share of forecast rows stamped ≤ D-1 10:00 UTC (the earliest SDAC
gate), with **D = the row's Europe/Athens market day** (the pilot's convention) and years by D:

| zone, years | load rows pre-gate | RES rows pre-gate |
|---|---|---|
| DE_LU 2022–2024 | 0 % | 0 % |
| DE_LU 2025 | 1.32 % | 0 % |
| DE_LU 2026 | 6.50 % | 0.62 % |
| GR 2022–2024 | 0 % | 0 % |
| GR 2025 | 0.57 % | 0 % |
| GR 2026 | 1.64 % | 0.31 % |

(The first version of this table used the UTC date as D, which gave 2.4 % / 0.3 % for 2026 load.)

- The historical stamps are bulk-load times, months to years after delivery.
- In 2026 the ETL overwrites the day-ahead values with later revisions.
- Training on latest revisions and forecasting with them would be leakage. Filling missing
  vintages with final revisions is excluded by the brief.
- Fuels alone were not run as a substitute; that would be a new specification.

## Results (target SDAC, pooled cells, rMAE on the same cells)

| window | zone | n | LEAR MAE | rMAE vs d1 | vs d7 | **vs epf** | DM vs epf, p |
|---|---|---|---|---|---|---|---|
| test 2024-07-01..2026-11-13 | DE_LU | 20,783 | 22.59 | 0.753 | 0.592 | **0.703** | < 1e-4 |
| | GR | 20,783 | 22.75 | 0.866 | 0.709 | **0.872** | < 1e-4 |
| record 2024-07..2026-06 | DE_LU | 17,518 | 20.69 | 0.722 | 0.589 | 0.699 | < 1e-4 |
| | GR | 17,518 | 21.20 | 0.844 | 0.699 | 0.850 | < 1e-4 |
| rolling-origin 2025-07..2026-06 | DE_LU | 8,759 | 20.31 | 0.746 | 0.611 | 0.711 | |
| | GR | 8,759 | 19.49 | 0.856 | 0.693 | 0.850 | |
| **El Mahtout & Ziel overlap** 2024-07-01..2025-01-14 | **DE_LU** | 4,753 | 22.87 | 0.691 | 0.576 | **0.691** | < 1e-4 |
| | GR | 4,753 | 24.94 | 0.830 | 0.719 | 0.849 | 1e-4 |

LEAR beats all three naives in every window and zone (DM p < 1e-4 over 197–859 complete days).
The gain is modest, though: it removes 13–31 % of the epf naive's error, less in GR than in DE_LU.

### Sanity band: DE_LU sits outside it (0.69 vs 0.4–0.6)

- **Checked, no bug found:**
  - the target matches the contract's SDAC helper exactly;
  - the leakage tests pass (`test/test_lear_431.py`, 10 tests): no future rows in any fit, and
    backward-only lags. A control test confirms that past rows do change the forecast;
  - the ratio does not depend on the period. It is 0.687 in the *validation* half-year (inside
    El Mahtout & Ziel's test window, but used to pick W, so not out of sample) and 0.63–0.79 by
    test quarter.
- **The most likely reason is structural.** The published LEAR numbers use D-1 load and RES
  forecasts: El Mahtout & Ziel's 0.443, and Lipiecki & Weron's LEAR+CP. DE_LU prices are
  wind-driven, so a price-only LEAR cannot see tomorrow's wind. The overlap is also only the
  last 6.5 months of their 2-year window, including the Nov–Dec 2024 Dunkelflaute.
- **This is an open question, not a resolved one.** The clean test is the exogenous arm on a
  store that keeps pre-gate vintages. No rerun with other settings was made.

### Live window 2026-09-14..11-13, same cells (intersection of every model; SDAC target)

**Physics vintages and the gate.** The archive keeps one lead-1 weather vintage per zone-day
(`prediction_made_utc`). Each is classified against the SDAC gate of its market day: D-1 12:00
Europe/Brussels, i.e. 10:00 UTC in summer time and 11:00 UTC in winter.
- On **7 October days** (10-08, 10-09, 10-11, 10-12, 10-13, 10-16, 10-20; both zones, 14
  zone-days, 336 cells) the vintage was issued **10:05–10:06 UTC, after the 10:00 UTC summer gate**.
- No earlier on-time vintage of those days is archived.
- The physics code versions in the window are **cv39 (09-14), cv40 (09-15..11-02) and cv42
  (11-03..11-13)**.

**Primary: the on-time cohort.** Only cells whose physics vintage was issued by the gate are
kept, and every model is scored on that intersection. That is 2,450 cells, 2 zones × 51 days.

| model | info set | DE_LU MAE | GR MAE | both: MAE | rMAE vs d1 | vs epf | DM vs epf, p |
|---|---|---|---|---|---|---|---|
| naive d1 | (a) | | | 45.03 | 1 | | |
| naive epf | (a) | | | 59.85 | | 1 | |
| live physics `sim` (lead-1 weather, cv39/40/42, pre-gate) | (a) | 61.20 | 67.98 | 64.59 | 1.434 | 1.079 | 0.79 |
| **LEAR, prices only** | (a) 06:30 | 45.78 | 40.68 | **43.23** | 0.960 | 0.722 | 3e-4 |
| Timestral-209M, prices only | (a) 06:30 | 34.17 | 33.00 | 33.58 | 0.746 | 0.561 | < 1e-4 |
| Timestral-209M + `sim` | (a′) post-sim, pre-gate | 24.91 | 32.46 | 28.69 | 0.637 | 0.479 | < 1e-4 |

**Secondary: the mixed cohort.** These are the archived vintages as served, pre- and post-gate:
2,786 cells, 2 zones × 58 days, including the 336 post-gate physics cells. Timestral + `sim` read
the same late vintages on those days.

| model | DE_LU MAE | GR MAE | both: MAE | rMAE vs d1 | vs epf |
|---|---|---|---|---|---|
| live physics `sim` (cv39/40/42, mixed pre/post-gate) | 59.17 | 71.06 | 65.11 | 1.443 | 1.128 |
| LEAR, prices only | 43.96 | 41.33 | 42.64 | 0.945 | 0.739 |
| Timestral-209M, prices only | 33.91 | 33.08 | 33.49 | 0.742 | 0.580 |
| Timestral-209M + `sim` (mixed) | 25.90 | 32.37 | 29.14 | 0.646 | 0.505 |

The ranking is the same in both cohorts.
- **On the GBM lines' own, smaller coverage** (their issue time is not in the archive; they are
  overlay rows that the #431 plan describes as rewritten daily, so they are descriptive only):
  - GBM: 1,008 cells over 21 zone-days; LEAR 35.8 vs `gbm` 43.0.
  - Stats: 710 cells over 35 zone-days; LEAR 38.1 vs `stats` 63.2.
  - DM is "insufficient data" (< 30 complete days) for both.
- **LEAR's bias in the live autumn is −21 €/MWh** (on-time cohort). The 364-day window anchors it
  below the sharply higher autumn prices. Against d1 it is not significantly better (p = 0.29
  on-time, 0.21 mixed).
- **Rolling-origin physics and stats GBM on the same cells: not done.** Their per-cell predictions
  (`model-lines-rolling-origin`) were never saved, and rebuilding them needs the Postgres
  `simulations` tables. This box has no access, by rule. The published per-zone figures
  (DE_LU: physics 19.90, frozen hybrid 11.39) come from different cells and actuals, so they are
  not set beside LEAR here.

## Reading

- **Price-only LEAR is a real but weak baseline here.**
  - It beats every naive in every window.
  - It beats the live physics line by a wide margin on identical cells.
  - It beats the live GBM/stats lines on their thin coverage, which is not significant.
  - It loses clearly to zero-shot Timestral on the same information set: 43.2 vs 33.6 on the
    on-time cohort, with rMAE vs epf 0.72 vs 0.56.
- **On this evidence it does not replace Timestral or justify retiring the stats GBM.** It is an
  honest, reproducible floor that any statistical line should beat. Promotion or retirement is
  the owner's call.
- **The DE_LU sanity-band miss is unresolved.** The likely cause is the missing exogenous arm.

## Files

- `lear.py`: data (`prices`), the model, the parallel runner (`run`), hyperparameter locking
  (`select`), and the long-format export for the contract (`export`): zone, t, model, prediction,
  lead, issue_utc, fit_end.
- `evaluate_lear.py`: windows and comparisons through benchmark-431's `evaluate()`. The live
  physics vintages are gate-classified; on-time and mixed cohorts are both scored.
- `audit_vintages.py`: the load/RES publication audit (Athens market day).
- `hparams.json`: the lock. `requirements.txt`: the pinned private venv.
- Tests: `test/test_lear_431.py`.

Outputs (not committed, `em-team/results/lear-431/`): `sdac_hourly.parquet`, `lear_raw_*.parquet`,
`lear_forecasts_test.{parquet,csv.gz}`, `bench_metrics.csv`, `bench_dm.csv` and `bench.txt`.
Mask hashes for every comparison are in `bench_metrics.csv`.

```bash
uv venv --python 3.12 $V && uv pip install --python $V/bin/python -r requirements.txt
python lear.py prices --out $O --extract <read-only extract>
python lear.py run --out $O --start 2024-01-01 --end 2024-06-30 --tag validation --procs 16
python lear.py select --out $O --tag validation
python lear.py run --out $O --start 2024-07-01 --end 2026-11-13 --windows 364 --tag test --procs 20
python lear.py export --out $O --tag test
python evaluate_lear.py --out $O --live <live snapshot> --tsfm <tsfm results>
```
