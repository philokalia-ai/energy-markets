# In-merit fleet truthing (2026-11 level investigation)

**Question.** Why did the live non-Italy price level stop following gas in
autumn 2026? Live lead-1 bias went from −11 in W38 to −88 in W46, while settled
prices rose from 139 to 243 €/MWh and TTF rose from 73 to 99.

**Answer: phantom in-merit hard coal in the `fleet_truth_mode=:installed` zones.**
`CONTINENTAL_PROFILE` (DE_LU, NL, PL, CZ) and `BALTIC_PROFILE` true every
market-active fuel type to ENTSO-E *installed* capacity: they complete it up to
installed and never derate it below. This was set in iter7, when coal SRMC was
above gas, so coal running below capacity was merit order, not unavailability.
Once TTF crossed ~50, hard-coal SRMC (37 + 0.9·EUA ≈ 110) fell below gas SRMC
(TTF/0.55 + 0.367·EUA + 2 ≈ 190–220). The grid-reserve and mothballed coal
counted in "installed" then became the cheapest thermal in Core.

## Evidence

Inputs: 10-19 and 11-02, gate-time record path, pass-2 books captured.

| | DE_LU 10-19 | DE_LU 11-02 |
|---|---|---|
| hard coal offered | 17.5 GW (10.7 GW of it `AGG-…-Fossil_Hard_coal` completion) | 19.3 GW |
| hard coal dispatched, model / actual | 13.1 / 3.2 GW | 17.6 / 4.3 GW |
| gas dispatched, model / actual | 4.7 / 8.0 GW | 6.4 / 13.2 GW |
| trailing-30d hourly hard-coal output p95 | 4.7 GW (max 5.5) | 4.4 GW |

NL showed the same pattern (6.0 GW offered vs a p95 of 3.3), and so did PL
(13.6 GW vs 8.2). In the 760 of 1,455 cells where settled ≥ 0.85·gas SRMC but
the model sat below 0.85·gas, coal or lignite set the price in 36 %. Anchored
hydro, which follows the pass-1 coupled price, accounted for another 18 %.

## Mechanism

Switch: `EUPHEMIA_INMERIT_TRUTH=1`. Default is off, which is byte-identical
(guarded on 10-19: 936 cells, max |Δ| = 0).

In `_true_up_fleet`, a baseload derate-type is affected when its SRMC is below
gas SRMC on both D and D−30. That means it was in merit over the whole p95
window. Such a type drops out of the truth target and falls back to the
existing `:p95` rule: complete to the 30d p95, derate to 1.15 × the 30d p95.
This is the derate block's own stated principle ("for a fuel whose SRMC sits
below the market price, running under its capacity means it genuinely could
not run").

There are no new parameters. All inputs are ex-ante: fuel closes strictly
before D−1, and output that is strictly historical.

## Result

8 calibration days (`em-team/reports/days.json`) on gate-time inputs, scored
against the SDAC settled price. 7,486 cells. HiGHS, all 24/24 periods optimal.

| set | MAE base → in-merit | bias | corr | caps |
|---|---|---|---|---|
| all-39 | 60.52 → 50.01 (−10.51) | −43.3 → −28.6 | 0.82 → 0.84 | 0 → 0 |
| ex-IT | 61.46 → 49.44 (−12.01) | −40.8 → −24.0 | 0.81 → 0.83 | 0 → 0 |

- 7 of 8 days improve. The exception is 09-20 (collapse Sunday): +1.0 ex-IT.
- 33 of 39 zones improve. Worst losses: SE3 +4.3, NO3 +2.5.
- Settled ≤0 hit and false-alarm counts are unchanged (1/1 out of 253).

**Exposed residual.** Gas peak tranches now set the evening price. Ex-IT cells
more than +50 €/MWh too high in 15–20 UTC rise from 107 to 208 (of 1,536).
For example, DE_LU 11-02 18–20 UTC clears at 389–400 against a settled 306–321.
Evening MAE still falls, 65.0 → 50.4. The cause is the conduct layer
(`TRANCHES` / `peak_kappa`), which this change does not touch.

**Not covered.**
- Pre-gate weather track: the mechanism only reads fleet truthing, but the
  effect there is unmeasured.
- Seasonal skill: needs a rolling backfill.
- Baltic and north-Nordic water value: LV/LT/EE are −57..−75 even after the
  fix, while SE1/SE2/NO4 are +35..+40. That points to a coupling/capacity
  mismatch.
- Single-efficiency gas fleet: settled prices are 1.3–1.6 × the η=0.55 CCGT
  SRMC in W45–46.

Scripts: `test/scripts/level/`.
