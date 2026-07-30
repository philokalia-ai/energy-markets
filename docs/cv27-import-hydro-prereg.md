# cv27 — FBMC import capability + hydro surplus pricing, pre-registration

**Status: gates frozen by this merge (owner process directive, 2026-07-30):
the experimenter runs the full theory→experiment→results cycle autonomously;
the OWNER decides at the END, with the measured results in hand — never asked
to pre-approve an unvalidated approach.** Merging this file freezes the gates
before any scored arm (the prereg discipline is unchanged); the ship/backfill
decision happens in the results report. Gates, tie-break, envelope and the
calibrate-on-A / hold-out-B discipline are inherited from
`docs/cv25-phase2-prereg.md`. The
baseline for every arm is the **cv26 record code** (ATC Day-ahead preference,
#233) — these treatments must be measured on the ATC-clean footing, since the
intraday-contamination fix already reshapes the Nordic import picture.

**Windows.** The inherited Set A/B months (2025-01, 2026-01, 2024-07, 2025-07)
plus, declared now for the hydro mechanisms' regime coverage: **2025-05 and
2026-05** (Nordic melt/surplus season), same day-of-month rule (A: 1/8/15/22,
B: 4/11/18/25, substitution rule unchanged). Six months × 4 days per set.

Grounding: `docs/experiments/cv26-scarcity-noship.md` (what not to do),
the 2026-07-30 shape-loss diagnosis (Fable synthesis, session record) and the
#233 FBMC finding.

## T1 — Demonstrated capability on Day-ahead-free (FBMC) borders

- **Problem:** since the Nordic FBMC go-live (late 2024) most Nordic/Core
  borders publish NO Day-ahead offered-ATC rows; cv26 falls back to the
  Intraday blend — arbitrary leftovers (NO3→NO1 "23 MW") on exactly the
  borders that matter for the Nordic belt.
- **Lever:** where a border-hour has no Day-ahead row, size its capacity by
  **demonstrated interconnector capability** — the trailing-365d p95 of
  observed gross flow per 4h block (`:p95_block`), the exact runtime recipe
  already first-class in the cv21/cv22 boundary books. No new machinery.
- **Market characteristic:** the border's demonstrated transfer capability —
  what the coupled market has actually carried, strictly ex-ante.
- **Expected direction:** Nordic-belt level tracking recovers (the 2025 dip);
  interior-Norway/SE shape-bad share falls.
- **Falsifiers:** any new cap hour anywhere; the inherited envelope; NO2/DK1
  (borders WITH Day-ahead rows) must be untouched — a nonzero delta there
  means the gate leaked; Set-B non-survival.

## T2 — Hydro spill-risk pricing (Nordic surplus regimes)

- **Problem:** the model's water value is a flat daily level, so it misses
  WHICH hours collapse toward 0 in surplus regimes. Diagnosis: 8 Nordic zones
  carry ~33% of all shape-loss mass; oracle bound = fixing only settled<10
  hours lifts NO3 median daily shape corr 0.13→0.84, the belt 0.62→0.87.
- **Lever:** in surplus regimes (reservoir fullness above a declared
  percentile AND net demand below the day's median), the hydro offer follows
  the **net-load valley**: the water value scales down proportionally to the
  within-day net-demand position, floored at 0 (never negative here — that is
  T3's job). One new profile field (the surplus-regime gate percentile);
  the hourly scaling is the existing `norm_demand` machinery, no new knob.
- **Market characteristic:** spill-risk opportunity cost — stored water
  facing spill prices at its recall value, near zero, and sellers chase the
  valley rather than hold a level.
- **Expected direction:** NO3/SE1-3/NO4/FI daily shape corr up; the
  belt-wide bad-day share (<0.3) down.
- **Falsifiers:** NO3 zone-year median shape corr not reaching ≥0.55 (from
  0.32); Nordic bad-day share not falling ≤0.12 (from 0.20); any continental
  zone breaching the neighbour envelope; caps ceiling; Set-B non-survival.
  Shape stats computed with the flat-day rule (see Metric note).

## T3 — Deep-surplus negative pricing

- **Problem:** the book never clears below the must-run discount; settled
  negative hours run 300–600/yr in NL/SE3/ES/FR/DE_LU/DK1/PL.
- **Lever:** must-run volumes (the existing below-cost discount tranche) bid
  down to a **negative floor** representing curtailment-avoidance /
  subsidy-keeping behaviour: one form-level floor value (declared, not
  per-zone), applied only to the tranche already priced below cost.
- **Market characteristic:** inflexibility + support-scheme economics — a
  unit that pays to keep running rather than cycle.
- **Expected direction:** sim clears <0 on a material share of
  settled-negative hours; midday MAE falls in the listed zones.
- **Falsifiers:** sim negative hours where settled >20 €/MWh (phantom
  negatives); the inherited envelope; the oracle bound says total shape gain
  is modest (+0.03-0.04 CORE) — if measured gain exceeds the oracle,
  something else moved (investigate, don't celebrate); Set-B non-survival.

## Metric note (reporting, not physics — applies to this prereg's scoring)

Shape statistics exclude zone-days with settled daily stdev < 2 €/MWh
(1,367 zone-days footprint-wide; corr is numerically meaningless there and
~halves the apparent NO1/NO4/NO5 shape problem). Level metrics keep all days.
This rule is part of the prereg so it cannot be chosen after seeing results.

## Protocol

1. Implement all three behind `EUPHEMIA_DISABLE_CV27` with per-treatment
   sub-switches `_T1/_T2/_T3` (the cv25 Phase-4 pattern). All-off bit-identity
   guard vs cv26 main before any arm.
2. Arms on Set A: `cv26` (baseline), `all` (T1+T2+T3), leave-one-out per
   treatment. Full coupled 39-zone footprint, per-cell harness, HiGHS.
3. Score per inherited gates + the per-treatment falsifiers above (scored-cell
   counts beside every figure; shape stats under the Metric note rule).
   Set B once, only if the package passes on A.
4. Report the measured results to the owner (non-draft PR carrying code +
   results together); the ship/backfill decision is the owner's, made on the
   data. cv bumps to 27 on the activating branch only.

**Out of scope by rule:** conduct residuals (PL premium, SEE evening level),
the evening ramp premium (own prereg, next), any scarcity-form change.

**This merge freezes the gates. Amendments before the run, in the open.**
