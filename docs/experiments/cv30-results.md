# cv30 — export capability, surplus floor, decision trace: measured results

**Prereg:** [docs/cv30-export-surplus-prereg.md](../cv30-export-surplus-prereg.md)
(#245, merged — gates FROZEN). **Baseline:** cv27 main. **Solver:** HiGHS
(reproducibility). **Data:** offline DuckDB extract (private read-only copy of
`euphemia-live.duckdb`), 39-zone footprint, two-pass enriched-network clear.

## Deviations from the prereg (as-ratified vs as-executed)

- **Switch polarity.** The prereg names `EUPHEMIA_DISABLE_CV30 + _T1.._T4`
  (a ship convention, default-ON). For an *experiment* that must measure a clean
  cv27 baseline, the treatments are implemented behind **default-inert
  `EUPHEMIA_ENABLE_CV30[_T1/_T2/_T3]`** switches (isempty-gated), so `base` =
  nothing set = cv27 main (proven byte-identical below). On a ship the owner
  flips these to the DISABLE convention like cv22/cv27.
- **T1 candidate set.** Implemented as the frozen survey borders (both
  directions tied): `IT-CSOUTH~IT-SOUTH, BG~GR, RO~BG, IT-SOUTH~IT-Calabria`
  (`CV30_T1_BORDERS_DEFAULT`, overridable via `EUPHEMIA_CV30_T1_BORDERS`). The
  LOO attributes T1 as a package (per-border screening within it is a follow-up).
- **T2 export term.** "demonstrated_export_capability" is implemented as a
  zone-aggregate: trailing-366d p95 of the zone's total gross OUTBOUND flow per
  4h block (`get_export_capability_day`), the zone-level analog of the T1
  per-border p95. Ex-ante (pre-delivery history only).
- **T4 (cloud-cover feature).** Input-side; the prereg validates it on the
  forecast track (weather-RES solar MAE), NOT the record gates — it cannot move
  a record clear. Deferred to the ML-input program; not implemented here. One
  line, as ratified.
- **Decision trace.** [status filled below]

## All-off identity guard

Fresh-main reference regenerated this session (the committed guard TSVs were
found stale by a prior agent). 1032-row harness (GR single-zone 2026-01-26 +
39-zone EU 2026-04-03). **All cv30 switches unset ⇒ byte-identical to the
fresh-main reference** (`diff` empty). The private extract copy is bit-identical
to the shared one (same guard passes against a reference built on the shared
extract).

## Positive control (treatments bite)

[filled below]

## Set A (24 days: 1/8/15/22 of 2025-01, 2026-01, 2024-07, 2025-07, 2025-05, 2026-05)

Arms: `base`, `allon`, `loo_T1`, `loo_T2`, `loo_T3`. Scored-cell counts beside
every figure.

[TABLES]

## Set B (scored once, only on an A-pass)

[TABLES or "not reached — A did not pass"]

## Verdict per gate

[filled below]

## Ship recommendation

[filled below]
