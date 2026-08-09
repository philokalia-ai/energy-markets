# R-cycle master harness — DRAFT for owner ratification (2026-08-08 night)

The one document that governs every recalibration package. Ratify → freeze →
every R2 package cites it; package-level preregs may only ADD gates, never
relax these.

## Standing rules (all packages)

1. **Year scale only.** Every scored arm covers 2025-08-01..2026-07-31 (or
   the rolling equivalent at run time). Fortnight windows mislead on coupled
   mechanisms — measured twice (cv18; TR/MK Set B vs full year).
2. **Sets**: Set A = months {Aug25..Jan26} calibrate/derive; Set B =
   {Feb26..Jul26} scored ONCE on an A-pass. Both halves span a winter/summer
   boundary by construction.
3. **Packages, not levers.** An R2 package = input stack + re-measured
   mechanism parameters for its zone family, A/B'd as ONE arm. Parameters
   are re-MEASURED from their defining data (flows, capacities, reservoir
   state) — never tuned on price error; price error only gates.
4. **Baselines are fresh** (same code, same extract, all-off) — the stored
   record does not pair across extract revisions (measured drift 66.8).
5. **Degenerate-cap quarantine** (bistability-note-2026-08.md): isolated
   cap cells contradicted by settled ≤300 are excluded from headline
   MAE/corr and reported per arm; treatments creating them still fail the
   zero-new-caps guard. Any month-corr move > 0.05 must be checked against
   flagged cells before being read as signal.
6. **Gates per package**: family MAE improves (per-zone floors set in the
   package prereg); envelope ΔMAE ≤ +3.0 / Δcorr ≥ −0.05 on all 39; ZERO
   new (non-quarantined) cap hours; footprint MAE not worse than +0.05;
   collapse hit/FA reported first-class.
7. **Integration (R3)**: coupled run with all accepted packages + LEAVE-ONE-
   OUT arms attributing every package; then cv bump + backfill + ledger.

## R0 outputs feeding this harness

### Actuals trust tiers (ALL 4 family audits in)

| Tier | Zones | Consequence |
|---|---|---|
| **1 (trusted)** | IT×7, CH, ES, PT, FR, BE, DE_LU, AT, HU, RS, NO1–NO5, SE1–SE4 | actuals usable for input scoring, oracle bounds valid |
| **2 (caveats)** | GR, RO (clean actuals, TRUE fc overshoot 1.24/1.40), SI, SK, CZ (night 9.3%), PL, **DK1 (wind fc 25–45% UNDER actual — prime R1 target)**, DK2, FI/EE/LV/LT (Baltic solar night artifacts 9–20%) | inputs correctable; actual-based metrics carry the caveat |
| **3 (untrusted)** | **NL** (solar actual = 2–7% of fleet — never substitute/score against it), **BG** (noisy actuals: night 7.6%, wind cf 3.3) | no actual-anchored derivation; input work goes through forecasts/ML only |

Cross-cutting registry finding (both agents, independently): the unit
registry carries ~0 distributed solar for most zones (only HU sane) —
**installed-capacity parameters must come from p99-of-actuals or forecast
ceilings, not the registry**, for RES.

Additional audit findings folded in:
- **Per-unit feed tail lag** (~3 weeks behind the extract edge, source-side):
  any trailing per-unit logic near "now" needs a feed-freshness
  precondition (measured confound: nuke-silence v1's July mass-derates).
- **SE3 nuclear reporting is complete** — the code-mismatch hypothesis is
  refuted; nuke-silence is backfill-NULL (v2) and lives on as a proposed
  FORWARD live A/B only.
- Load actuals trustworthy in all 39 zones.

### Bistability: contained (rule 5); solver reproducer parked on pillar 1.

Rule-5 refinement (evidence of 2026-08-08 night): treatment-created cap
cells that are THEMSELVES quarantine-class (isolated + settled ≤ 300) count
as branch noise and are reported, not failed; only new NON-quarantine caps
(clustered, or settled-corroborated) fail the guard. Rationale: the base
arm carries such cells too (2 in 310k) and perturbations toss knife-edge
hours in AND out of cap branches — a strict zero would make every arm
unshippable on coin flips.

## R1 spec (inputs per zone × target) — REVISED 2026-08-09 morning

**Finding (measured + code-confirmed):** the current ML stack TARGETS the
ENTSO-E D-1 forecast (docs/predictions.md; the #252 design), so it inherits
the TSO's conditional biases by construction and cannot beat them vs
actuals. The year TSO-vs-actuals scorecard (r1_tso_scorecard.csv, session
scratchpad) quantifies where that matters: **DK1 wind bias −521 MW on
1,967 avg (−26%)**, **GR solar +470 on 1,692 (+28%)**, RO solar +149/414,
BG solar +89/785; most other zone-targets are within ±5%.

**Policy (the R1 deliverable):** the training TARGET follows the trust tier
per (zone, target):
- Trusted actuals + biased TSO fc (DK1 wind, GR/RO solar, …): retrain with
  **actuals as target** (same features/vintages; y changes), scored OOS vs
  actuals — these become the R2 input legs.
- Trusted actuals + unbiased fc: keep fc-target (cheaper, already shipped)
  — nothing to gain.
- Untrusted actuals (NL solar, BG per its tier): fc-target stays CORRECT —
  never train toward garbage.
The dual-target policy is itself a named characteristic (which truth each
zone's input can see), recorded per zone-target in the meta.

## R2 package order (updated by R0)

1. **IT family** (Tier-1 across the board, oracle-positive, registry gap
   noted) — the clean pilot.
2. **Iberia + core** (ES/PT/FR/BE/DE_LU/AT — Tier-1).
3. **SEE** (GR/RO first — true-overshoot zones with clean actuals; BG last
   within family pending actuals).
4. **Nordics/Baltics** (pending audit 4; SE3 nuclear reporting question).
5. **NL** — blocked on an actuals decision (external source or
   forecast-only derivation), explicitly out of the first pass.
