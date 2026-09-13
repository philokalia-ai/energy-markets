# cv40: implementation defects from the 2026-09-13 cv39 review

Four defects the review evidenced in source, each reproduced before the change
(`docs/energy-markets-cv39-review.md`, priority 2). Kill switches let each be
ablated; `test/test_cv40_fixes.jl` covers them.

| # | Defect | Fix | Switch |
|---|---|---|---|
| 1 | JAO's interconnector hubs are marked by an underscore in the **raw** name (DK1_CO, NO2_SK, SE3_FS); the test ran on the **mapped** name, where `DE` → `DE_LU` — Germany's own net-position limits (24 records/day) never reached the clear | test the raw name | `EUPHEMIA_DISABLE_CV40_DEHUB` |
| 2 | a published limit of exactly 0 was skipped (`lim > 0.0 \|\| continue`), leaving a hub barred from exchanging unconstrained (61,069 rows with `min_np_mw = 0`, 60,886 with `max_np_mw = 0`) | enforce the zero cap | `EUPHEMIA_DISABLE_CV40_ZEROLIM` |
| 3 | transmission-outage caps ran **before** explicit ATC and the pre-gate fallback were added, so border-hours from those sources escaped the remaining-NTC cap | cap after every source is assembled | structural (none) |
| 4 | fine→coarse load aggregation used the running mean `(acc + next)/2`: 100/200/300/400 MW → 312.5 instead of 250 | duration-weighted mean | structural (none) |

Also in the branch, not record-affecting: `bin/emit_model_lines.py` no longer
hard-codes the cv37 book directory. The trained-on version travels with
`models.joblib` (`book_cv`) and the run aborts on a mismatch rather than
publishing lines from a model fitted on different books (review §6).

## A/B (paired, live Postgres, Gurobi, canonical 39 zones incl. CH)

52 Wednesdays 2025-09-03..2026-08-26, labels `ab40_base` (switches 1+2 off) vs
`ab40_fixes`. **Scored against the canonical SDAC settlement target**
(`scripts/settlement_view.py`: per zone the sequence with full day coverage and
the later publication time — sequence 1 for DE_LU/AT, the blank series
elsewhere), which is the review's priority-1 correction.

**Coverage caveat:** fixes 3 and 4 are structural and run in BOTH arms, so the
delta below measures fixes 1 and 2 only. Fix 4 fires solely on
mixed-resolution zone-days; fix 3 only where a later capacity source supplied a
border-hour under a transmission outage. Neither is attributed here.

| | base | fixes |
|---|---|---|
| footprint MAE | 27.23 | 27.22 |
| energy-weighted MAE | 26.44 | **26.39** |
| bias | −9.94 | −9.93 |
| corr | 0.758 | 0.758 |
| cells ≥ 500 €/MWh | 0 | 0 |
| collapse recall (settled ≤ 5, n=2,268) | 0.175 | 0.175 |

9.8 % of cells move, mean |Δ| 2.47, max 81. **Aggregate is a wash; the
redistribution is the finding and it is physically coherent.** Germany and the
zones downstream of its evacuation improve — HU −0.43, DE_LU −0.27, DK1 −0.10,
SI −0.08, RO/BG/DK2/RS −0.05..−0.07 — while the zones that now absorb the
constrained German net position degrade: AT +0.31 (bias −25.7 → −26.1), CH
+0.16, SK +0.12, CZ +0.09, PL +0.05. That is what a binding hub limit should
do, and the review predicted it ("can alter German surplus evacuation and
neighbouring prices").

The collapse tail does not move: recall 0.175 and zero false alarms either way.
These fixes are about feasible exchange, not about the low-price mechanism.

## Recommendation

Ship the code as **cv40**: four correctness fixes, no aggregate cost, a small
energy-weighted gain, and Germany's published constraint finally binding.

**Do not spend a 16-hour record backfill on this alone.** The aggregate score
is flat, so a fresh record buys labelling, not accuracy. The efficient path is
to let the daily forecast pick the fixes up immediately and carry the record
backfill once the larger packages land — the Sicily attribution trace, the
flow-based domain re-clear and the settlement-target rescore — so one run
reflects several corrections. cv39 stays canonical until then.

Separately worth noting from the settlement-target work: blending the EXAA
auction into the German target had been flattering DE_LU by about €1/MWh of
MAE and 0.03 of correlation (20.05/0.881 → 21.06/0.853 on the two-year
ladder), but it does **not** change the cv37 → cv39 verdict (−0.24 vs −0.25).
