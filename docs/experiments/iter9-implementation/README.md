# Iteration-9 implementation — endogenizing AL / MK / ME / HR (39 → 43 zones)

Implements the Phase-0 scoping (`docs/experiments/iter9-scoping/README.md` on
`exp/iter9-scoping`; roadmap item 3 of
`docs/experiments/boundary-zones-roadmap.md`). Branch
`feat/iter9-endogenize`. All src changes are **default-inert**: gated on
footprint membership, so the 39-zone EU product, the 5-zone SEE product and
every single-zone book are unchanged (guards G1/G2 below).

## Design (what shipped, where)

1. **Network plumbing** (`src/Network.jl`, `src/clearing/multi_zone_books.jl`)
   - **Per-border aggregate-remap override.** New
     `AGGREGATE_BORDER_COUNTERPARTY_REPRESENTATIVE = {("IT","ME") => "IT-CSOUTH"}`
     + `build_aggregate_remap_overrides(footprint)` +
     `aggregate_remap_overrides` kwarg threaded through
     `create_transfer_capacity_from_entsoe` → `_create_transfer_capacity_enriched`.
     The IT–ME explicit DA ATC is filed under the aggregate `IT`; the border is
     the Monita cable landing in IT-CSOUTH, so the blanket `IT→IT-NORTH` remap
     would mis-wire it. Active only when ME **and** IT-CSOUTH are footprint
     nodes (unit-tested; empty for the 39-zone and SEE sets).
   - **HR border drops.** `flow_based_drop_borders` += HR–SI and HR–HU, gated
     on `"HR" in fp`. HR's only implicit-table rows for these borders are
     *Intraday* leftovers (p10 0–1 MW vs 1.8–2.4 GW physical; there are NO
     Day-ahead implicit rows for HR at all) — the SK/AT/SI treatment. A code
     comment now marks the latent trap that the implicit ATC loader has no
     `contract_type` filter. HR–RS stays endogenous (real explicit DA ATC,
     avg 408/473 MW). Control arm: `EUPHEMIA_ITER9_HRHU=endogenous` keeps
     HR–HU endogenous on the Intraday-avg ATC (run only if HU degrades).
   - Everything else is automatic through existing mechanisms: the new
     endogenous borders (GR–AL, GR–MK, AL–ME, MK–RS, ME–RS, HR–RS, MK–BG
     2026→, ME–IT-CSOUTH) come in via the explicit-DA union; GR/BG's observed
     AL/MK injections are excluded natively via `atc_linked` →
     `net_import_exclude` (no wave-1 hooks exist on main — verified); RS's
     `import_backstop` headroom accounting picks up the three new endogenous
     borders through `endogenous_counterparties = net_import_exclude`.

2. **Profiles** (`src/merit_order/zone_profiles.jl`)
   - `CROATIA_PROFILE` = the SLOVENIA shape (continental temperament 1.25 /
     κ1.5 / peak-κ0.6, `:hydro` anchor, `import_backstop`) **minus**
     `ref_priced_exports` — SI's flag covered its ~1 GW HR export, which is
     now a dropped in-footprint border handled by `anchor_export_mw`; HR's own
     retained exogenous export (HR–BA ~216 MW) is small and the scoping's
     instruction is measure-before-adopt. Unit test pins
     `with_profile(CROATIA; ref_priced_exports=true) == SLOVENIA`.
   - `AL`/`MK`/`ME` → explicit `SEE_PROFILE` registry entries with rationale
     docstrings (AL: gas-anchored SEE per the ALPEX premium, watch winter cap
     days → backstop is the designed next lever; MK: SEE first, promote to the
     SERBIA shape if the RS/RO failure mode appears; ME: SEE, export outlet
     via the endogenous Monita border).
   - MK's ~40 missing load-forecast days degrade per-day: the book returns
     `success=false` ("No load data found") → the multi-zone builder `@warn`s,
     drops the zone for the day and rebuilds ATC-linked neighbors with their
     observed imports restored (existing failed-zone path, verified by code
     read and by the loud warnings in the trial builds).

3. **Footprint 43** (`bin/reproduce.jl`, `bin/eu_calibration_run.jl`)
   - `FOOTPRINT43 = FOOTPRINT39 + [AL, HR, ME, MK]` constants; default stays
     39 everywhere. `eu_calibration_run.jl` selects 43 via env
     `FOOTPRINT=43`; `reproduce.jl` via `--zones`. The frozen cv17/cv18
     backfill runners are historical records and were not touched — the iter9
     cv backfill runner will be authored at ship time on FOOTPRINT43.
   - Note: the published DuckDB extract does not carry the four new zones, so
     43-zone runs read Postgres until the extract is rebuilt.

## Guards

- **G1 (byte-identity of the SEE products)** — **PASS**. Vs main @077c7da:
  GR single-zone books bit-identical (SHA256) on 2026-01-26 and 2026-04-03;
  the 5-zone SEE ATC surface bit-identical on both days; the 5-zone SEE book
  bit-identical on 2026-01-26 (0 differing order lines of 3,432) and on
  2026-04-03 (0 of 3,140) when the two builds run serialized. An initial hash mismatch on the 5-zone books was
  reproduced as the *documented* concurrent-Postgres last-ULP SUM-reordering
  transient (another agent's backfill was hammering the DB): same-code
  back-to-back reruns are bit-identical, and the serialized cross-code diff
  is 0 lines. 43-zone smoke build (2026-04-03, no solve): all four new zones
  build (AL 74 / HR 312 / ME 240 / MK 480 orders), borders AL:{GR,ME},
  HR:{RS} (SI/HU dropped), ME:{AL,IT-CSOUTH,RS} (Monita on IT-CSOUTH, not
  IT-NORTH), MK:{BG,GR,RS}.
- **G2 (39-zone bit-identity)** — pending solver availability.
- **G3 (43-zone A/B)** — pending solver availability. Windows: 2026-04-01..05
  benchmark, 2026-07-06..21 July regime window, 2026-03-01..08 March guard.
  Baseline arms: cv19 `multi_zone_eu` saved record (March/April; coverage
  verified: 8 and 5 days × 39 zones) + fresh 39-zone runs for July (cv19
  backfill ends 2026-06-30). Treatment: fresh 43-zone runs via `ab_run.jl`
  (save_to_db=false, prices to TSV). Scoring: `score_ab.jl`
  (resolution-aware actuals, dedup by sequence — the iteration-4 standard).

## Files

- `ab_run.jl` — A/B driver (footprint × window → TSV, resumable, no Postgres writes)
- `score_ab.jl` — per-zone/per-window scorer + A-vs-B delta tables
- results TSVs land here (`ab_39.tsv`, `ab_43.tsv`, `ab_scores.tsv`, …)
