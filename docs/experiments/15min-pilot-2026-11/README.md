# 15-minute clearing pilot (2026-11-15, phase 3)

Question (owner): can we clear at 15' and does it make the evaluation better?
Setup: cv44 (main 5a3be57), Julia 1.13.4, HiGHS 1.27, 39 zones, per-period
decomposition, PS master on, extract `euphemia-live-20261115`, D-1 legacy path,
8 calibration days, UTC-day windows. Arms: H = hourly; Q = `clear_resolution_minutes=15`;
Qf = Q + `EUPHEMIA_PS_INTRAHOUR=flat`.
Run: `CLEAR_RES=15 [EUPHEMIA_PS_INTRAHOUR=flat] julia --project=. test/scripts/blocks/clear_days.jl LABEL DAYS...`;
score: `python test/scripts/blocks/score15.py H_LABEL Q_LABEL` (planner-p3 protocol).

## Feasibility
All 8×96 periods are optimal and the PS master handles 96 periods without change: MWh budgets, MW×0.25 per quarter.

| arm | wall time vs H | solve time vs H | RSS |
|---|---|---|---|
| Q | 3.49× (473–905 s/day) | 4.07× | ≈ 4 GB, as hourly |
| Qf | 3.08× | 3.49× | ≈ 4 GB, as hourly |

**Degeneracy:** in Q, the master swings whole storage families 0↔Pmax between the
quarters of an hour (423 of 3,576 family-hours; CH up to 3.8 GW) even where inputs are
hourly-replicated. `EUPHEMIA_PS_INTRAHOUR=flat` (src/mpcc/complex_orders.jl) holds
each family's MW constant within the hour. It is opt-in and a no-op on hourly books.

## Scores (7,486 hourly cells vs live SDAC; 29,364 native-PT15M quarter cells)

| | hourly MAE (H 48.59) | days better | 15-min MAE (H-rep 49.21) | days better |
|---|---|---|---|---|
| Q | 48.32 (−0.27) | 6/8 | 48.77 (−0.9 %) | 7/8 |
| Qf | 48.25 (−0.35) | 6/8 | 48.73 (−1.0 %) | 7/8 |

Where the gain comes from:
- solar-ramp hours: −0.47, against −0.28 elsewhere (Qf);
- zones with native PT15M load and RES: −1.1 %, against −0.3 % for replicated-only zones (Qf, 15-min).

Shape floor (hindsight):
- S_mean = mean|a − ā_h| = 8.44 €/MWh, which is 17 % of the 15-min MAE.
- Intra-hour variance is 6 % of the replicated MSE.
- Q reproduces half of the actual intra-hour dispersion (4.4 vs 8.4) and about 3 % of the centred shape.

The quarter-hour error is dominated by the hourly level error.

Planner-p3 gates:

| gate | Q | Qf |
|---|---|---|
| native-15 MAE ≥ 5 % below H-rep | fail (−0.9 %) | fail (−1.0 %) |
| ≥ 5 of 8 days better | pass | pass |
| hourly MAE worsens ≤ €0.5 | pass | pass |
| no new cap prints | pass | pass |
| wall ≤ 4× hourly | pass in total; 3 Q days above 4× under uneven contention | pass |

Verdict: feasible and slightly positive, but not a code-version change. Add 15-min
*scoring* (hourly model replicated ×4 vs native PT15M) first; keep 15-min clearing
opt-in. Not covered: Athens-day windows, the 06:30 context, quarter-level ATC
(the MPCC looks up ATC by hour). Data coverage, Sep–Nov 2026:
- native PT15M share of zone-days: price 98 %, load 80 %, RES 85 %, ATC 95 %;
- per-zone counts: `audit_resolution_coverage.csv`.
