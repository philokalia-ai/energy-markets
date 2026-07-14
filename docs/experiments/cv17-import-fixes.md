# cv17 — weak-zone import fixes (production implementation)

Promotes the validated prototypes of the weak-zone diagnosis
([weak-zone-diagnosis/README.md](weak-zone-diagnosis/README.md)) to production
code, under `ENERGY_PRICES_CODE_VERSION = 17`. The diagnosis showed the cv16 EU
footprint's low-correlation zones (BE/DK/AT/CH/SI/RO/RS/SE3/IT-CNORTH) are not
a shape problem but a handful of phantom-scarcity days: import starvation from
(a) chronic Core-FBMC residual ATC on never-dropped borders and (b) tail-day
understatement of the fixed `:v2` climatology injection, amplified by a book
with no supply between the top domestic tranche (~1.6×gas) and the €3,000 cap.

## What shipped

1. **Border drops — AT–CZ, AT–DE_LU, AT–SI** added to `flow_based_drop_borders`
   (chronic residual ATC, p10 = 0 vs 1.3–2.0 GW physical; the HU/BE/SK/SE
   precedent), and **SI on the Slovakia treatment**: `SLOVENIA_PROFILE` =
   continental scarcity temperament + `:hydro` opportunity anchor so the
   restored imports price at the coupled Core reference. The v3 attribution
   control measured the SI drop as strictly necessary (backstop-only leaves SI
   at corr 0.33 vs 0.70 with the drop).
2. **Ex-ante elastic import backstop** as a first-class `ZoneProfile` mechanism
   (`import_backstop`, `backstop_weeks=8`, `backstop_price_mult=1.8`,
   `backstop_scarcity_credit=0.0`), computed by
   `MeritOrderBook.get_import_backstop` next to the `:v2` climatology off the
   same cached day relations (fully ex-ante — every input strictly predates
   the D-1 auction):
   `qty(h) = max(0, max_{k=1..8} netimport(day−7k, h) − clim_median(h) −
   offered_endogenous_import_ATC(h))`, priced at 1.8× gas SRMC. The
   endogenous-ATC subtraction (production refinement over the prototype)
   prevents double counting capacity the MPCC flow variables already carry.
   ON for AT, BE, CH, DK1, DK2, SE3, IT-CNORTH, SI, RO, RS.
   **HU deliberately excluded**: its climatology injection is already adequate
   and the P2 prototype drifted its bias −14.6 → −28.8; the v3 attribution
   keeps HU membership a calibration decision — the production benchmark
   (below) confirmed exclusion. OFF for all guard zones (GR/BG/ES/PT and the
   rest of the footprint).
3. **SE3 anchor refs over dropped borders** (`anchor_include_dropped`, gated —
   only `SE3_PROFILE` opts in): dropped in-footprint neighbors enter the
   two-pass opportunity-anchor reference weighted by observed climatology
   import flow, so SE3's ref becomes SE2-dominated (its real ~5 GW marginal
   supplier) instead of DK1-only (~0.3 GW). Gate: SE4/DK2 side effects
   measured on the benchmark (below).
4. **Ref-priced retained-border exports** (`ref_priced_exports`, gated — SI and
   BE opt in): observed net exports over RETAINED borders (SI–HR, BE–GB)
   price at the coupled/anchor reference in pass 2 instead of firm demand at
   the cap, so exporters curtail under domestic stress — the demand-side
   mirror of the dropped-border `anchor_export_mw` treatment.
5. `ENERGY_PRICES_CODE_VERSION` 16 → 17.

Every new `ZoneProfile` field defaults inert; the mechanisms activate only on
the EU-footprint path (`enrich_network=true` + `apply_zone_profiles=true`).
The legacy SEE single-zone and 5-zone products force `SEE_PROFILE` and no
drops, so they are structurally unchanged.

## Gate results

### 1. Unit tests

`julia --project=. test/runtests.jl`: **1078 passed / 4 failed / 12 errored /
2 broken** — the failures are exactly the 16 pre-existing "UC Caching
Integration" failures documented in the known-issues memory (verified on
unmodified main); all merit-book / profile / network / MPCC / scenario suites
pass, including the updated `test_zone_profiles.jl` (119 tests).

### 2. SEE byte-identity (cv16 code ↔ cv17 code)

Single-zone merit books for **GR, BG, RO, RS, HU, ES, PT** on 2026-01-26
(full order books at 17 significant digits — 13,965 order rows) plus the 96
GR cleared prices through `generate_energy_prices(:merit_order)`:
**bit-identical** between main (cv16) and this branch (offline DuckDB extract,
same solver). The new mechanisms are provably OFF on the legacy product.

### 3. 28-day stratified benchmark (production code path)

`test/scripts/cv17_bench.jl` — the diagnosis benchmark (16 spike + 12 normal
days), 39 zones, `run_multi_zone_market_clearing(enrich_network=true,
passes=2, :merit_order, gurobi)`, offline DuckDB extract, evaluated by
`test/scripts/weak_zone_eval.py cv17` against ENTSO-E settled prices and the
stored `eu_scn_base` baseline.

<!-- CV17_BENCH_TABLE -->

### 4. Full-year backfill (production record)

<!-- CV17_FULLYEAR -->

## Reproduction

```bash
# 28-day production-path benchmark (offline, ~1 h with Gurobi)
julia --project=. test/scripts/cv17_bench.jl
python3 test/scripts/weak_zone_eval.py cv17

# Full-year cv17 record (Postgres, pipelined, resumable)
START_DATE=2025-07-01 END_DATE=2026-06-30 julia --project=. bin/cv17_backfill.jl
```
