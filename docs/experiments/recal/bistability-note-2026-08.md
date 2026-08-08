# Degenerate cap-branch bistability — diagnosis (2026-08-08 night)

**The phenomenon.** In the week's year-scale A/Bs, "distant gains" (ES corr
+0.116, IT-CSOUTH +0.140 on the year) decomposed into single flip months.
Tonight's precision pass reduces them further: **exactly TWO isolated
zone-hours in 310k** — ES 2026-07-20 14:00 and IT-CSOUTH 2026-04-26 12:00 —
where the fresh baseline (`trmk_base_fy`) prices €3,000 while **all five**
treatment arms price €3–250. One midday phantom-cap hour destroys a
zone-month of Pearson corr and ±4 of month-MAE.

**The record is clean.** The published `multi_zone_eu` rows price both cells
at €1–27 across every code_version (18–31). The caps exist ONLY in the
fresh re-run on the 2026-08-06-refreshed extract: upstream data revisions
between the record's 2026-07-28 extract and the refresh moved the coupled
problem onto a knife-edge where the base solution lands in a cap branch at
one solar-surplus hour — and ANY perturbation (a boundary book, a 1-MW RES
shave) escapes it. Data-revision-sensitive degeneracy, not a code defect,
and physically absurd (cap at solar peak) — a solver/robustness corner, not
a market state.

**Containment for the R-harness (the scoring side):**
- Quarantine rule: a zone-hour with price ≥ 2,999 that is (a) isolated (no
  adjacent cap hour in the same zone) and (b) contradicted by settled ≤ 300
  is flagged `degenerate_cap` and excluded from MAE/corr headline metrics;
  flagged counts are reported per arm (a treatment that CREATES such cells
  still fails the zero-new-caps guard — quarantine never launders caps).
- Paired-arm reporting: any month where an arm's corr moves > 0.05 must be
  re-checked for flagged cells before being read as signal (formalizes this
  week's ad-hoc interpretation guard).

**The solver-side thread (pillar 1 backlog, reproducers preserved):** why can
a deep-surplus midday period reach the cap at all in the decomposed clear —
suspected robustness-ladder/near-infeasible corner on one period under
specific revised inputs. Reproducers: the two cells above with the
2026-08-06 extract (`trmk_base_fy` in results.duckdb) vs the same cells
under any perturbation. Fix belongs in the MPCC robustness ladder, gated
and measured like any solver change; NOT attempted inside the R-cycle.
