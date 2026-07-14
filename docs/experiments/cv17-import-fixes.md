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
   class-split by border (the production no-double-counting refinement over
   the prototype):
   `qty(h) = max(0, max_k net_nonendo(day−7k, h) − clim_nonendo(h)) +
   max(0, max_k net_endo(day−7k, h) − offered_endo_import_ATC(h))` —
   non-endogenous borders (whose climatology the book injects) measure
   demonstrated flow beyond that climatology; ENDOGENOUS borders (which the
   MPCC flow variables carry up to the offered ATC, implicit ∪
   explicit-Day-ahead, the enriched network's exact sourcing) measure
   demonstrated flow beyond that ATC — this also covers episodic offered-ATC
   collapses (CH holiday auction gaps). Priced at 1.8× gas SRMC, above every
   domestic tranche multiplier.
   ON for AT, BE, CH, DK1, DK2, SE3, IT-CNORTH, SI, RO, RS **and HU**.
   HU's membership was the documented open calibration decision (the P2
   prototype drifted its bias −14.6 → −28.8 with an uncredited backstop; the
   v3 attribution left it open): the production benchmark showed the coupled
   SEE cold-snap cluster keeps capping (RO 6 / RS 4 / HU 2 hours > €500)
   without HU's backstop, and `backstop_scarcity_credit = 1.0` on RO/RS/HU
   (the mechanism P2 lacked — recommendation 2's second half) removes the
   residual markup overshoot; with it the cluster drops to 3 single hours.
   The credit was also measured uniformly across the backstop set and
   REVERTED (moved no target metric, cost SK/SE4 ~0.05 corr via their anchor
   refs). OFF for all guard zones (GR/BG/ES/PT and the rest of the
   footprint).
3. **SE3 anchor refs over dropped borders** (`anchor_include_dropped`):
   dropped in-footprint neighbors enter the two-pass opportunity-anchor
   reference weighted by observed climatology import flow, so SE3's ref
   becomes SE2-dominated (its real ~5 GW marginal supplier) instead of
   DK1-only (~0.3 GW). **Measured against its gate and switched OFF**: the
   SE2-dominated ref pinned SE3 at SE2's level — bias flipped +13 → −24 and
   corr fell 0.55 → 0.31 vs the backstop-only configuration. The mechanism
   ships in the code (default off) as a future calibration lever; SE3's §4b
   night-shape problem remains open.
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
**bit-identical** between main (cv16) and the final cv17 branch (offline
DuckDB extract, same solver; verified twice — after the initial
implementation and again on the final configuration). The new mechanisms are
provably OFF on the legacy product, which never consults `ZONE_PROFILES`.

### 3. 28-day stratified benchmark (production code path)

`test/scripts/cv17_bench.jl` — the diagnosis benchmark (16 spike + 12 normal
days), 39 zones, `run_multi_zone_market_clearing(enrich_network=true,
passes=2, :merit_order, gurobi)`, offline DuckDB extract, evaluated by
`test/scripts/weak_zone_eval.py cv17` against ENTSO-E settled prices and the
stored `eu_scn_base` baseline.

**Result (final configuration; corr / MAE / bias vs settled prices, all 28 days):**

| zone | base (cv16) | cv17 | P2 target (corr) | verdict |
|------|-------------|------|------------------|---------|
| BE  | 0.22 / 63.5 / +39.5 | **0.85** / 21.0 / −3.5 | 0.85 | meets |
| DK1 | 0.11 / 71.8 / +37.2 | **0.75** / 28.7 / −7.0 | 0.75 | meets |
| DK2 | 0.32 / 82.6 / +47.5 | **0.79** / 28.7 / −10.4 | 0.76 | beats |
| RO  | 0.35 / 54.8 / +25.5 | **0.77** / 31.6 / −5.5 | 0.77 | meets |
| SI  | 0.28 / 64.5 / +25.0 | **0.70** / 40.8 / −31.5 | 0.70 | meets |
| AT  | 0.17 / 85.3 / +38.6 | **0.77** / 28.3 / −20.2 | 0.80 | −0.03 |
| CH  | 0.11 / 49.9 / +19.4 | **0.70** / 25.5 / −7.3 | 0.74 | −0.04 |
| RS  | 0.32 / 44.6 / +20.5 | **0.76** / 29.3 / −2.4 | 0.79 | −0.03 |
| SE3 | 0.18 / 53.8 / +31.4 | **0.55** / 36.2 / +13.3 | (0.55 = P2) | at P2 |
| IT-CNORTH | 0.59 / 26.2 / +6.6 | **0.61** / 23.1 / +2.1 | — | improves |
| HU  | 0.74 / 37.8 / −14.6 | 0.72 / 41.7 / −29.7 | — | ≈ P2 (0.73/41.1/−28.8) |
| *GR (guard)* | 0.85 / 24.2 | 0.87 / 23.4 | ±0.02 | holds (+0.02) |
| *DE_LU (guard)* | 0.88 / 20.7 | 0.87 / 21.0 | ±0.02 | holds (−0.01) |
| *ES (guard)* | 0.83 / 23.5 | 0.83 / 23.1 | ±0.02 | holds |
| *PT (guard)* | 0.80 / 25.2 | 0.80 / 24.9 | ±0.02 | holds |

**Cap hours (> €500 over the 28 days): 103 → 21**, of which 16 are the
out-of-scope Nordic hydro problem (NO1 12, FI 4) and 2 are pre-existing
IT-NORTH/IT-CNORTH singles — the in-scope residual is 3 single hours (BG/RO/RS
on the two SEE cold-snap days, all < €560 vs the €3,000 phantom caps of the
baseline). Side-effect zones match the P2 prototype exactly: SK 0.71 / 45.7 /
−40.3, CZ 0.56 / 34.9 / −18.3 (the anticipated AT-drop trade-off, identical
to P2), SE4 0.67 / 31.9 / −2.1.

**Where cv17 sits vs the P2 corr targets and why.** AT (−0.03), CH (−0.04)
and RS (−0.03) trail the prototype numbers with MAE at parity. The traced
cause is the no-double-counting refinement the production form requires: the
prototype measured demonstrated headroom against the flow climatology on ALL
borders, while production measures endogenous borders against their OFFERED
ATC (what the MPCC can actually carry) — strictly correct, but smaller
exactly on coupled cold-snap mornings when offered ATC exceeds typical flows
while the whole neighborhood is tight. Loosening it would reintroduce double
counting; the deficit is accepted and documented.

**Calibration iterations measured on this benchmark (all levers documented in
the diagnosis):**
1. *Flat offered-ATC subtraction* (the spec's literal caution (b)): CH 0.27 /
   RO 0.47 / RS 0.76 — over-subtraction left 2 true caps (CH 2025-01-01 h22,
   RO 2026-06-20 h18) and the SEE cluster at €517–591. Rejected.
2. *Class-split headroom* (shipping form) + HU backstop with scarcity credit:
   all targets within 0.04, caps down to 3 in-scope singles.
3. *Uniform scarcity credit across the backstop set*: moved no target metric,
   cost SK/SE4 ~0.05 corr through their anchor refs. Reverted — the credit
   stays scoped to RO/RS/HU, where it demonstrably killed the SEE cluster caps.
4. *SE3 `anchor_include_dropped`*: gated OUT (see item 3 above).

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
