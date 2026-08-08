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

### Actuals trust tiers (3 of 4 family audits in; Nordics pending)

| Tier | Zones | Consequence |
|---|---|---|
| **1 (trusted)** | IT×7, CH, ES, PT, FR, BE, DE_LU, AT, HU, RS | actuals usable for input scoring, oracle bounds valid |
| **2 (caveats)** | GR, RO (clean actuals, TRUE fc overshoot 1.24/1.40), SI, SK, CZ (night-artifact 9.3%), PL | inputs correctable; actual-based metrics need the caveat noted |
| **3 (untrusted)** | **NL** (solar actual = 2–7% of fleet — never substitute/score against it), **BG** (noisy actuals: night 7.6%, wind cf 3.3) | no actual-anchored derivation; input work goes through forecasts/ML only |

Cross-cutting registry finding (both agents, independently): the unit
registry carries ~0 distributed solar for most zones (only HU sane) —
**installed-capacity parameters must come from p99-of-actuals or forecast
ceilings, not the registry**, for RES.

### Bistability: contained (rule 5); solver reproducer parked on pillar 1.

## R1 spec (inputs per zone × target)

Winner = ML vs TSO forecast on the **out-of-sample scorecard vs actuals**,
EXCEPT Tier-3-actuals zones where scoring vs actuals is invalid → those keep
the TSO forecast (or ML scored vs forecast-consistency) until their actuals
source is fixed. NOTE (from this audit): the #252/#301 ML RES targets are
ENTSO-E D-1 forecasts, which shields ML from garbage actuals but also means
"ML beats TSO on actuals" must be re-established per zone before R2 uses it.

## R2 package order (updated by R0)

1. **IT family** (Tier-1 across the board, oracle-positive, registry gap
   noted) — the clean pilot.
2. **Iberia + core** (ES/PT/FR/BE/DE_LU/AT — Tier-1).
3. **SEE** (GR/RO first — true-overshoot zones with clean actuals; BG last
   within family pending actuals).
4. **Nordics/Baltics** (pending audit 4; SE3 nuclear reporting question).
5. **NL** — blocked on an actuals decision (external source or
   forecast-only derivation), explicitly out of the first pass.
