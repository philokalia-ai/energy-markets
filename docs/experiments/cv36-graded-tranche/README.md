# cv36: graded upper-tranche ladder — the Italy peak fix (2026-08-27)

Owner-approved recovery plan item 1 (conduct-probe finding: Italy = model-gap;
recal-2026-08 finding: the IT peak uplift is a STEP, on=+31/off=−7 bias).

## Mechanism

`ZoneProfile.tranche_grading::Int = 1` (default = the classic 4-step staircase,
bit-identical; suite-guarded). K>1 splits each scarcity tranche (i≥2) into K
sub-slices whose price multipliers interpolate linearly from the previous
tranche's multiplier — the zone's aggregate supply curve becomes piecewise-
linear near the peak. Same total MW per unit (verified to 0.1 MW).

## Set A (26 odd-week Wednesdays, Gurobi, base = same-branch defaults)

| arm | IT-N/CN overrides | IT-N bias | IT-N pk | IT-N MAE | IT-N corr | CH dMAE |
|---|---|---|---|---|---|---|
| base | — (1.2/1.2, step) | +12.0 | +32 | 24.5 | 0.65 | — |
| g4 | grading=4 only | +11.9 | +30 | 24.0 | — | −0.4 |
| g4b | grading=4, κ=1.05, tsm=1.165 | +8.8 | +27 | 23.0 | 0.68 | +0.8 |
| g4c | grading=4, κ=1.0, tsm=1.15 | **−10.8** | −7 | **18.4** | **0.75** | +1.2 |

Findings:
- The graded ladder DOES create an intermediate landing (g4b: +8.8, which the
  step form could not produce) — but a jump remains between κ=1.05 and κ=1.0:
  the discontinuity is **which technology is marginal at the peak**, not the
  ladder shape. A knob cannot center the bias; the missing middle is likely a
  supply component priced between SRMC-thermal and the scarcity tranches
  (candidate mechanism: Italian pumped-storage opportunity bids, ~7 GW — noted,
  not built).
- **The correlation objective is met by g4c**: IT-NORTH 0.65→0.75, IT-CNORTH
  0.66→0.74, IT-CSOUTH 0.65→0.71 (all cross the 0.7 line of the
  energy-at-corr≥0.7 metric); all seven IT zones improve in MAE (−0.4..−6.6);
  footprint −0.51. Cost: wrong-signed IT bias (−10.8) and CH +1.2 MAE
  (guard is 1.0; CH corr unchanged at 0.72). The g4b PT wobble (4 spring days)
  is absent in g4c (PT corr 0.71, MAE −0.1).

Set-A budget: 3 arms as stated. Set B (26 even-week Wednesdays) run ONCE on
g4c + same-branch baseline — results below; ship/no-ship is the owner's call.

## Set B (held out, scored once)

(pending)
