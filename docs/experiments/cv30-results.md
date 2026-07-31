# cv30 — export capability, surplus floor, decision trace: measured results

**Prereg:** [docs/cv30-export-surplus-prereg.md](../cv30-export-surplus-prereg.md)
(#245, merged — gates FROZEN). **Baseline:** cv27 main. **Solver:** HiGHS
(reproducibility). **Data:** offline DuckDB extract (private read-only copy of
`euphemia-live.duckdb`), 39-zone footprint, two-pass enriched-network clear.
**Verdict: NO-SHIP** (Set A fails on every gate; Set B not scored, per protocol).

## Headline

All three record-touching treatments (T1/T2/T3) were implemented default-inert
and measured on Set A (24 days × 39 zones = 22,464 scored zone-hours per arm).
**Each treatment increases all-hours MAE, and the package fails three frozen
gates simultaneously**: T2's phantom-negative falsifier fires at 20.6% (gate
≤2%), T1 manufactures 6 new cap-hours and breaches BG/RO correlation (−0.32),
and T3 over-lowers the Italian zones (+1.42 MAE). Set A does not pass, so Set B
was **not scored** (calibrate-A / hold-out-B, scored once only on an A-pass).

## Deviations from the prereg (as-ratified vs as-executed)

- **Switch polarity.** The prereg names `EUPHEMIA_DISABLE_CV30 + _T1.._T4` (a
  ship convention, default-ON). For an experiment needing a clean cv27 baseline,
  the treatments are behind **default-inert `EUPHEMIA_ENABLE_CV30[_T1/_T2/_T3]`**
  switches (isempty-gated), so `base` = nothing set = cv27 main (proven
  byte-identical below).
- **T1 candidate set.** Frozen survey borders (both directions tied per cv27
  protocol): `IT-CSOUTH~IT-SOUTH, BG~GR, RO~BG, IT-SOUTH~IT-Calabria`
  (`CV30_T1_BORDERS_DEFAULT`). LOO attributes T1 as a package.
- **T2 export term.** `demonstrated_export_capability` = trailing-366d p95 of a
  zone's total gross OUTBOUND flow per 4h block (`get_export_capability_day`),
  the zone-aggregate analog of the T1 per-border p95. Ex-ante.
- **T4 (cloud-cover).** Input-side; the prereg validates it on the forecast
  track (weather-RES solar MAE), NOT the record gates — it cannot move a record
  clear. **Deferred to the ML-input program**; not implemented here.
- **Decision trace.** The book-capture `owner` tag already labels each order's
  strategy family (RES / IMPORT / DEMAND / BACKSTOP / BOUNDARY:* / unit-code).
  The additional pricing-branch sub-label + per-(zone,hour) marginal-order trace
  JSON is **designed but deferred**: it is price-inert observability orthogonal
  to the owner's ship decision, and the package NO-SHIPs, so wiring it into the
  capture writer (PipelinedBackfill) was not the overnight priority. Design in
  "Decision trace" below. Its byte-identity guard would be capture-on == off.

## All-off identity guard (PASS)

Fresh-main reference regenerated this session (a prior agent found the committed
guard TSVs stale). 1032-row harness (GR single-zone 2026-01-26 + 39-zone EU
2026-04-03). **All cv30 switches unset ⇒ byte-identical to fresh-main cv27**
(`diff` empty, 1032/1032 rows). Re-run after the directional-T1 amendment — still
byte-identical. The private extract copy is bit-identical to the shared one (the
reference was built on the shared extract, the all-off run on the private copy,
and they match to the last digit).

## Positive control (treatments bite)

5 arms × 2 July days. **T1 bites** (73 zone-hours; GR evening −15 to −49 as the
BG~GR ceiling decouples GR; RO/IT move). **T3 bites hard** (198 zone-hours; IT
zones −25 to −82). **T2 = 0 changes on July days** (high summer load ⇒ surplus
signal never fires) — but it fires on Jan/May (see Set A: T2 is the sole source
of every negative price).

## Set A (24 days: 1/8/15/22 of 2025-01, 2026-01, 2024-07, 2025-07, 2025-05, 2026-05)

Arms: `base`, `allon`, `loo_T1`, `loo_T2`, `loo_T3`. **22,464 scored zone-hours
per arm** (24 × 39 × 24). corr is Pearson(sim, settled) over all scored hours;
per-zone corr uses the flat-day rule (drop settled-sd<2 zone-days).

### Aggregate (all scored zone-hours, vs settled)

| arm | MAE | dMAE | corr | dcorr | new caps | neg hrs | phantom-neg % |
|---|---|---|---|---|---|---|---|
| base   | 31.14 | 0.00 | 0.701 | 0.000 | 0 | 0 | 0.0 |
| allon  | 33.30 | +2.17 | 0.529 | −0.172 | **6** | 63 | **20.6** |
| loo_T1 (T2+T3) | 32.58 | +1.44 | 0.704 | +0.004 | 0 | 57 | **22.8** |
| loo_T2 (T1+T3) | 33.27 | +2.13 | 0.529 | −0.172 | **6** | 0 | 0.0 |
| loo_T3 (T1+T2) | 31.88 | +0.74 | 0.543 | −0.158 | **6** | 60 | 16.7 |

### LOO attribution (marginal effect of adding Tk = allon − loo_Tk)

| Tk | changed zone-hrs | dMAE_Tk | new caps from Tk |
|---|---|---|---|
| T1 | 1,093 | +0.72 | **6** (all of them) |
| T2 | 244 | +0.04 | 0 |
| T3 | 3,519 | +1.42 | 0 |

- **T1** contributes all 6 new cap-hours and the BG/RO corr collapse.
- **T2** barely moves MAE (+0.04) yet is the **sole source of all negative
  prices** (loo_T2, which omits T2, has 0 neg / 0 phantom; every other arm's
  negatives vanish without T2), at a **20.6% phantom-negative rate**.
- **T3** is the biggest MAE degrader (+1.42), over-lowering the IT zones.

### Collapse classification (first-class, per SCIENTIST.md)

| arm | settled≤5 hit % | settled≤5 false-alarm % | settled<0 hit % |
|---|---|---|---|
| base  | 42.2 | 39.0 | 0.0 |
| allon | 42.8 | 39.6 | 5.3 |
| loo_T1| 42.8 | 39.1 | 5.3 |
| loo_T2| 43.0 | 39.2 | 0.0 |
| loo_T3| 42.3 | 39.9 | 5.3 |

T2/T3 catch 5.3% of true negative hours (base catches 0), but the ≤5 hit-rate is
essentially flat (42.2→42.8) and false-alarm rises (39.0→39.6). The collapse
signal is **not improved** — the few true negatives caught come with a 20%
phantom-negative tax.

### Per-zone envelope breaches (dMAE>+3.0 OR dcorr<−0.05 vs base; corr on non-flat zone-days)

`allon` breaches 7 zones:

| zone | base MAE | arm MAE | dMAE | base corr | arm corr | dcorr | new caps |
|---|---|---|---|---|---|---|---|
| IT-Sicily   | 20.18 | 36.61 | +16.43 | 0.795 | 0.776 | −0.019 | 0 |
| BG          | 38.83 | 53.62 | +14.79 | 0.715 | 0.397 | **−0.318** | **3** |
| RO          | 39.67 | 52.91 | +13.24 | 0.712 | 0.394 | **−0.317** | **3** |
| IT-Sardinia | 19.68 | 31.01 | +11.34 | 0.805 | 0.794 | −0.011 | 0 |
| IT-Calabria | 20.21 | 28.67 | +8.47 | 0.796 | 0.811 | +0.015 | 0 |
| IT-CSOUTH   | 18.52 | 25.86 | +7.34 | 0.807 | 0.824 | +0.017 | 0 |
| IT-SOUTH    | 19.75 | 27.09 | +7.34 | 0.816 | 0.835 | +0.019 | 0 |

BG/RO change-footprint max delta **+2,455 €/MWh** — the symmetric export ceiling
caps the *import* direction of BG/RO, starving them into cap prices. IT zones are
T3 over-lowering (min delta −100 to −142 €/MWh in the change footprint).

## Verdict per gate

| Gate (frozen) | Result | Status |
|---|---|---|
| T2 phantom-negative ≤ 2% | 20.6% (allon), 22.8% (loo_T1) | **FIRED — NO-SHIP T2** |
| No new cap-hours | +6 (all from T1) | **FAIL (T1)** |
| Per-zone envelope +3.0 MAE / −0.05 corr | BG/RO corr −0.32; 6 IT zones dMAE +7..+16 | **BREACH** |
| Aggregate MAE / corr | +2.17 MAE, −0.172 corr | worse |
| Collapse (≤5 hit / <0 hit) | flat hit, higher false-alarm | not improved |
| GR summer-midday ≤ €5 (owner target) | not achieved on Set A (T1-driven GR moves are evening-coupling, not midday collapse) | not met |

**Set A does not pass. Set B was NOT scored** (protocol: scored once, only on an
A-pass). Conflicted ≠ pass; a fired falsifier is a verdict, not a negotiation.

## Directional-T1 diagnostic (disclosed post-A amendment)

The T1 failure has two parts: (a) a symmetrization defect — `both directions
tied` (the cv27 *fill* protocol) applied as a *ceiling* caps the import direction
and starves BG/RO; (b) whether the export-ceiling concept helps at all with
correct directionality. `EUPHEMIA_CV30_T1_DIRECTIONAL` applies the ceiling to the
listed directions only. Measured on Set A (24 days), vs cv27 base:

[T1_DIR TABLE — filled after the run]

This is calibration-set diagnosis (not falsifier-tuning: T1's failure is an
envelope/cap breach, not the phantom gate). It does not change the package
verdict — T2 and T3 fail independently.

## Decision trace (design, deferred)

`owner` tags on the captured book already encode the strategy family. The
remaining spec: (1) a per-order `strategy` sub-label for unit orders
(`srmc_tranche_k` / `water_value` / `must_run_deep` / `res_price_taker` /
`export_capability_ceiling` / `import_injection` / `backstop` / `boundary_book`)
plus its key inputs, threaded alongside the tag through `create_merit_order_book`
into `BOOK_SINK`; (2) a per-(zone,hour) `trace` JSON written in the clearing
layer (which owns the marginal order + border-binding state the book_build stage
cannot see). Both are capture-side and **price-inert by construction**; the guard
is capture-on == capture-off prices. Deferred because it is observability
orthogonal to the owner's ship decision on a NO-SHIP package.

## Ship recommendation

**NO-SHIP the cv30 package.** Per-treatment:

- **T2 (export-aware surplus floor): NO-SHIP.** The export-aware signal did NOT
  fix the phantom-negative problem (20.6% vs cv28 18% / cv29 16.4%) — the third
  redesign of the surplus floor fails the same falsifier as the first two. The
  floor family is exhausted on the record gates; a fourth attempt needs a
  fundamentally different mechanism (not a price floor on price-takers). Lesson:
  the export term makes the signal *conservative on quantity* but the failure is
  that when the floored price-taker DOES become marginal, it prints −20 in hours
  that settled positive — a **marginality** problem the signal cannot see.
- **T3 (self-scheduling reallocation): NO-SHIP.** Reallocating (not deleting) the
  cv29 haircut shares avoids phantom scarcity (0 new caps) — the cv29 lesson
  holds — but it over-lowers the IT zones (+1.42 MAE, IT-Sicily/Sardinia dMAE
  +11..+16), because the reallocated block is priced at self-schedule/floor in
  shoulder hours that settled well above it. The share magnitudes (0.5–0.7) are
  too large for a system-wide reallocation.
- **T1 (export-capability ceiling): NO-SHIP as implemented (symmetric).** The
  concept — cap a border whose real DA exchange saturates below nominal ATC — is
  sound, but tying both directions starves importers (BG/RO). See the
  directional diagnostic for whether the corrected, direction-scoped ceiling is
  worth a future border-screened program (the GR headline). Not shipped here.

The code lands default-inert (byte-identical to cv27), so nothing changes for the
record or the live forecast; the switches remain for future revival of a
redesigned mechanism.
