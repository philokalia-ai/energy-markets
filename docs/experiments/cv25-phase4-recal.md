# cv25 Phase 4 — the re-calibration, measured

Run 2026-07-30 per `docs/cv25-phase4-prereg.md` (ratified by merging #229 the
same day, **before any scored arm ran**; the A1 sizing fix to
`_endogenous_import_atc` was posted on the PR inside the amendment window).
Branch `feat/cv25-phase2-fixes`; arms from one binary via switches, one fresh
process per (arm, day) cell on the read-only DuckDB extract, HiGHS.
Per-treatment sub-switches (`EUPHEMIA_DISABLE_CV25_T1`/`_T3`) express the
leave-one-out arms; polarity verified live for all four arms before launch, and
the all-off guard is bit-identical to the pre-treatment parent (1032/1032).

**Scored-cell counts:** 14,976 per set (16 days × 39 zones × 24 h, all-arm +
settled intersection; no day truncated or excluded in either set).

## Set A (calibration) — 4 arms × 16 ratified days, 64/64 cells

| arm | MAE €/MWh | corr | ΔMAE | Δcorr |
|---|---|---|---|---|
| allon (Phase-3 honest baseline) | 34.05 | 0.547 | — | — |
| **recal (T1+T3)** | **33.44** | **0.602** | **−0.61** | **+0.055** |
| loo_T1 (only T3) | 34.00 | 0.547 | −0.04 | ±0.000 |
| loo_T3 (only T1) | 33.49 | 0.602 | −0.56 | +0.055 |

- **T1 (BG/GR demonstrated-headroom backstop): PASS, carries the package.**
  ΔMAE −0.56 / Δcorr +0.055, envelope clean. GR MAE 39.79 → 31.91 with corr
  0.451 → **0.719**; BG 52.79 → 46.92; RO improves +5.6 MAE as a neighbour.
  Cap hours fall 5 → 2 with zero new ones — the episodic phantom-scarcity
  spikes the prereg predicted T1 would kill are dead.
- **T3 (IT-NORTH backstop): PASS, small.** ΔMAE −0.05 / Δcorr ±0.000, envelope
  clean; IT-NORTH 33.96 → 32.99 and mild gains across the IT family. **The
  standard 1.8×SRMC backstop does NOT close the +40 sustained level shift** —
  reported as a finding per the prereg's explicit rule (no new price forms).
- **T2: structural no-op, zero code.** The backstop's "offered endogenous ATC"
  term queries the raw directional tables, which the canonicalisation does not
  change — inspected and noted on #229 before any arm ran. `loo_T2` would be
  bit-identical to `recal` by construction.

## Set B (held out, scored once) — allon + recal, 32/32 cells

One substitution by the ratified rule (2025-07-18 unusable at source →
2025-07-19).

| arm | MAE | corr |
|---|---|---|
| allon | 27.26 | 0.633 |
| recal | 27.09 | 0.629 |

Package ΔMAE **−0.17** / Δcorr **−0.004**: mechanically PASS under the ratified
tie-break (Δcorr > −0.005), zero cap hours in either arm. Honest reading of the
flags:

- **One neighbour-envelope breach: RO Δcorr −0.026** (limit −0.02) — while its
  MAE *improves* −0.78. A mixed signal, recorded as the owner's-call flag the
  gates define, not silently passed.
- The treated zones themselves are equivocal out of sample: BG MAE improves
  (32.41 → 31.63) with corr −0.027; GR MAE +0.49 with corr −0.048 — both inside
  the affected-zone envelope (−0.05) but at its edge. The dramatic Set-A GR
  gain is winter-cap-driven; Set-B days have no caps to kill.
- Broad mild improvements elsewhere (Baltics, CZ, PL, DE_LU corr +0.026).

## Verdict and what remains open

The package survives out of sample in the direction that matters (MAE down,
caps zero, nothing hard-breached) and its Set-A mechanism attribution is clean,
but it recovers only **0.61 of the 3.22 MAE** gap on A (0.17 of 2.17 on B).
The remaining damage is the shape pathology (SI/HU/AT/CH) that T2 was expected
to address and structurally could not (it was already correct), plus the
IT-family level shift that the standard backstop form cannot close. Both are
findings for the next preregistered iteration — scarcity-form and
border-scoped mechanisms stay out of scope by the prereg's own rule.

**Ship/backfill decision is the owner's.** cv stays 25 on this branch; #228
carries the full Phase-2+4 package.

## Execution notes

- **Deviation from protocol §2 (disclosed):** the prereg prescribed pipelined
  per-arm sweeps gated on `pipeline_identity.jl`; the sweep instead used the
  Phase-2 per-cell harness (one process per (arm, day), same model functions
  end-to-end). This is strictly more conservative — no worker-env propagation
  surface at all — and the earlier pipeline-divergence diagnosis (1 cell/2,808,
  environment-level tranche flip, sequential value non-reproducible) motivated
  preferring the mechanism already validated in the ratified Phase-2 ablation.
- The A1 review fix (aggregate in-code in `_endogenous_import_atc`) landed
  before ratification: without it T3's backstop double-counted ~3.3 GW
  (IT-NORTH peak 7,960 → 4,686 MW after; BG/cv17 zones unchanged).
- Raw cells: `scratchpad/p4/` (`<arm>_<day>.tsv`, `B_` prefix for Set B);
  scorer `score_phase4.py` (gates encoded, assert-heavy); score transcripts
  `p4_scores_A.txt` / `p4_scores_B.txt`.
