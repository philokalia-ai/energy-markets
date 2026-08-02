# The fitted layer — inventory, code review, and improvement backlog

> Chapter one of the SIX-PILLARS program, companion to
> [`six-pillars.md`](six-pillars.md). Everything here is **pillars 2–4** — the only
> fitted artifacts in the system. Pillars 1/5/6 are constructed and appear here only
> as the *consumer* of these fits (a load bias becomes a price bias). Numbers are
> from the committed scorecard `docs/experiments/input-upgrade/rollout-39.md` (VALID
> 2026-05-01…07-22) and `docs/experiments/{res-forecasting,dn-load-model}`.

## 1. Inventory — every fitted artifact surfaced on the site

The Predictions page (`web/index.html` `#view=predict`) and the map colour by these.
Provenance is resolved per (zone, target) at run time from
`bin/input_models/meta.json` (`ml_pilot_zones()` / `ml_use_new()`, `bin/ml_inputs.jl`).

| Artifact | Family | Count | Committed at | Serve path |
|---|---|---|---|---|
| **LightGBM input models** | GBDT, L1 objective, `num_leaves≤31`, lr .05 | **76 of 117 zone-targets** (load 38, solar 22, wind 16) | `bin/input_models/*.txt` + `meta.json` + `geom.json` | pure-Julia GBDT scorer `bin/ml_inputs.jl` (bit-identical to python) |
| **RES linear packs** | per-zone ridge on power-curve(v100 cells) + GHI | 41 zone-targets fall back here | `bin/res_models_v2.json` | `bin/weather_res.jl` `predict_solar_hour`/`predict_wind_hour` |
| **Load linear pack** | per-zone ridge, 207 features (hour-of-week, degree-hours, GHI, Fourier) | fallback + daily-forecast load-fill | `bin/load_models_v1.json` | `bin/weather_load.jl` `predict_load` |
| **cap95 normalizer** | trailing-30d p95 actual gen ending D-2 | all RES | computed in `features.py` / `bin/ml_inputs.jl` | ratio target `tgt/cap95` |
| **Holiday computus** | Gregorian + Orthodox (Julian/Meeus) Easter, fixed national maps | 10 mapped countries | `features.py` / `bin/ml_inputs.jl` (lockstep) | calendar feature |

**Which won (headline, from rollout-39):** load is a near-universal ML winner
(38/39; only NO4 keeps its pack). Solar ML wins 22/32 modeled zones (7 skip — no
resource). Wind ML wins only 16/32 — the physical power-curve pack still beats
LightGBM on the low/onshore zones. Notable ML gains: PL load 757→549 MAE,
PL solar 679→469, GR load 197→109 (Orthodox-holiday retrain), RO load 367→198.

## 2. Code review — correctness risks, staleness, improvement candidates

**R1 — Winner selection is MAE-only; it can (and does) ship a correlation
regression.** `ml_use_new()` picks NEW when it beats the pack on VALID *MAE*. On the
scorecard this shipped several corr-worse models: **NO2 wind** NEW corr 0.798 vs
pack 0.881 (ships NEW on MAE 102.9<116.3); **FR wind** NEW 0.843 vs pack 0.888.
Correlation is exactly the shape signal the collapse question and the price corr
depend on — an MAE-only gate is blind to it. *Risk: medium; it degrades the price
corr in wind-set zones.*

**R2 — Systematic positive LOAD bias in several large zones** feeds straight into
demand → price. Scorecard NEW load bias: FR +191, IT-NORTH +198, HU +130, RO +98,
NO3 +108, AT +29. Load bias is not laundered by the construct layer — a +2% load
over-prediction lifts the whole demand curve and the clearing price. *Risk: medium;
concentrated in a few zones, easy to measure.*

**R3 — RES wind pack has a residual +5..15% May–June seasonal level bias** the
feature family cannot express (`res-forecasting/README.md`): the v2 GFS-vintage
refit fixed the −29% GR train/serve bug (0.29→0.14 mean |bias|) but a
"seasonal calibration layer is the identified next iteration". *Risk: low-medium;
seasonal, self-limiting.*

**R4 — Large negative SOLAR volume bias in several ML winners** (GR solar NEW bias
−337, BG −195, BE −117). This *helps* collapse detection (under-forecast solar is
conservative on crashes) but hurts non-collapse midday level. It is a known
tension, reported not hidden (`predictions.md §9`). *Risk: low; documented, and the
sign is defensible for the collapse question.*

**R5 — Staleness.** All models trained through **2026-04-30**, VALID to 2026-07-22.
At audit (Aug 2026) they are ~3 months past train-end and there is no automated
retrain — cadence is "annual/quarterly, manual" (`dn-load-model §6`, `res-forecasting`).
Fit is fast (ridge = minutes closed-form; LightGBM per zone-target = seconds), so
this is cheap to close. *Risk: grows monotonically with time.*

**R6 — Holiday maps cover only 10 countries;** unmapped countries carry NO holiday
feature and therefore lose their load target to the pack "where holidays matter"
(`rollout-39.md` amendment 1). Adding a national-holiday map is a pure data edit
(computus already in code) that could flip more load zones to ML. *Risk: none;
pure upside.*

**R7 — DE_LU one national load model struggles with the Luxembourg mix** (worst
MAPE of the pilot; `dn-load-model §7`). Per-zone feature work (school-holiday
calendars, wind-chill) is the flagged next step. *Risk: low; localized.*

**R8 — Wind onshore bottleneck is the input geometry, not the model** — the
investigation found 10 m population-sited wind is the ceiling; 100 m cells + power
curve is the pack's edge, and LightGBM on the same cells does not beat it on
onshore (`res-forecasting-investigation.md`). A better *cell selection* (turbine-
weighted, the OSM 115k-turbine extraction) is the lever, not a fancier regressor.
*Risk: low; structural, higher-effort.*

**R9 — NO4 is fully pack** (lost every target). Small, congestion-isolated; low
value to chase. *Risk: none; note only.*

## 3. Prioritized improvement backlog

Ordered by (value × confidence) / effort. Each item is sized to a **~20-minute
iteration** (the owner's loop cadence). "Verify" is the ex-ante, out-of-sample check
that decides ship/no-ship — never an in-sample MAE.

1. **iteration 1 — winner selection: add a corr guard (fixes R1).** Change
   `ml_use_new()` to ship NEW only when it beats the pack on MAE **AND** does not
   lose >0.02 corr on VALID (else keep the pack). *Value: high (shape/price corr),
   confidence: high, effort: ~15 min — one predicate + re-run the winner sweep.*
   **Verify:** re-score the affected zone-targets (NO2/FR wind at least) on the
   frozen VALID window; confirm no corr regression ships; spot-check the price corr
   on 3 wind-set zones is flat-or-up.

2. **iteration 2 — expand the national holiday maps (fixes R6).** Add fixed-holiday
   maps for the currently-unmapped footprint countries (computus already handles
   movable feasts). *Value: medium-high (flips more load zones to ML), confidence:
   high, effort: ~20 min — data table + the lockstep assert.* **Verify:** the
   `features.py`↔`ml_inputs.jl` byte-identity assert stays green; re-run load winner
   selection for the newly-mapped zones and record any pack→ML flips on VALID MAE.

3. **iteration 3 — per-zone affine LOAD bias correction (fixes R2).** Fit a single
   `(a·x+b)` calibration on a strict-past trailing window for the high-bias load
   zones (FR/IT-NORTH/HU/RO/NO3), applied at serve. *Value: high (large zones,
   direct price impact), confidence: medium-high, effort: ~20 min — closed-form,
   strict-past.* **Verify:** VALID load bias → ~0 with MAE not worse; then one
   price A/B on FR + IT-NORTH confirming the demand-curve shift moves price bias the
   expected direction (this is a fitted-input change — score on the ex-ante track,
   never the record).

4. **iteration 4 — retrain on data through the latest settled month (fixes R5).**
   Re-run `train39.py` extending the window to the newest dense `previous_day1`
   vintages; re-select winners. *Value: high (staleness compounds), confidence:
   high, effort: ~20 min — the pipeline is one driver + the winner sweep.*
   **Verify:** the pure-Julia serve port stays bit-identical
   (`test/scripts/ml_inputs_equivalence.jl`); winners table diff reviewed; VALID
   MAE per target not worse than the shipped model on a fresh held-out tail.

5. **iteration 5 — seasonal wind-level calibration layer (fixes R3).** Add a
   month-of-year multiplicative level term to the wind pack/ML output, fit on
   year-round OOS (the `res-forecasting` recipe already scoped it). *Value: medium,
   confidence: medium, effort: ~20 min.* **Verify:** year-round OOS volume |bias|
   drops toward the 0.07 already seen on the full window without hurting corr
   (scale-invariant), on ≥15 zones.

6. **iteration 6 — DE_LU load feature enrichment (fixes R7).** Add German
   school-holiday calendar + a wind-chill term to the DE_LU load features only.
   *Value: medium (biggest zone by volume), confidence: medium, effort: ~20 min.*
   **Verify:** DE_LU VALID load MAPE/corr improves vs the shipped DE_LU model; no
   change to any other zone (feature is DE_LU-scoped).

7. **iteration 7 — turbine-weighted wind cell reselection (attacks R8).** Replace
   the pack's cell weights for 2–3 onshore-heavy zones with OSM turbine-density
   weights (the 115k-turbine extraction the site already advertises). *Value:
   medium, confidence: medium, effort: ~20 min per zone-batch.* **Verify:** wind
   corr on the reselected zones beats both the current pack and LightGBM on VALID;
   only then does it become a winner-selection candidate.

8. **iteration 8 — collapse-metric report on the SOLAR winners (audits R4).** Not a
   model change — extend `collapse_metrics.py` output to every continental-solar
   winner so the hit/false-alarm trade of each solar model is visible before any
   retrain re-selects it. *Value: medium (guards the collapse question against a
   silent regression), confidence: high, effort: ~15 min.* **Verify:** the report
   runs on DE_LU/FR/PL/BE/CZ/CH and the numbers match the pilot's GR 8/16→13/16.

9. **iteration 9 — cap95 normalizer sensitivity check.** Sweep the trailing-30d p95
   window (e.g. 45d) for the fastest-growing solar fleets (PL/HU/RO) where a 30d
   window may lag a step-change in installed capacity. *Value: low-medium,
   confidence: medium, effort: ~20 min.* **Verify:** VALID solar level bias on the
   growth zones improves; leave the window at 30d elsewhere (no global change).

10. **iteration 10 — automate the retrain cadence (institutionalizes R5).** Wire the
    `train39.py` + winner-sweep + equivalence check into a quarterly CI job (the
    fetch/scorer machinery already exists and is non-fatal). *Value: high long-run,
    confidence: high, effort: ~20 min to draft the workflow.* **Verify:** a dry-run
    of the workflow produces the same committed artifacts on the current window
    (idempotent), and the equivalence test gates it.

**Sequencing note:** items 1, 2 and 8 are pure guards/data (zero model risk) and
should land first; 3 and 4 are the highest-value model changes and share the same
verification harness; 5–7 and 9 are targeted refinements; 10 closes the loop so the
staleness risk never returns. Every model-touching item is scored on the **ex-ante
product track**, never the record (the record runs on ENTSO-E reference inputs by
construction — these fits never enter it).

## 4. Iteration results (measured)

**Iteration 1 — winner-selection corr guard (fixes R1). SHIPPED.** The MAE-only
`win` predicate in `train39.py` gained a companion clause: NEW ships only when it
beats the pack on VALID MAE **AND** loses at most `CORR_GUARD_TOL = 0.02`
correlation (`corr_ok` is vacuous when either corr is NaN). Re-running the selection
over the frozen VALID window (2026-05-01…07-22) from the committed
`valid_preds.parquet` (pilots) + `scorecard39.csv` (39-zone) — **no refetch, no
retrain** — demoted **4 of 76** NEW winners that had shipped a corr regression:

| zone-target | NEW MAE | pack MAE | NEW corr | pack corr | corr lost | → |
|---|---|---|---|---|---|---|
| NL_solar | 1144.6 | 1291.6 | 0.707 | 0.933 | **0.226** | pack |
| NO2_wind | 102.9 | 116.3 | 0.798 | 0.881 | 0.083 | pack |
| FR_wind | 916.6 | 965.3 | 0.843 | 0.888 | 0.045 | pack |
| HU_load | 219.2 | 346.8 | 0.899 | 0.924 | 0.025 | pack |

NO2/FR wind were the two R1 named cases; the guard also caught the large NL_solar
shape regression (a pilot, so `ML_USE_NEW` was flipped in lockstep) and the marginal
HU_load. `meta.json` winners set to `false` for the four; per the winners-only-
committed invariant their `.txt` dumps + meta model entries were removed (72 committed
models ⇔ 72 NEW winners). Direction is one-way conservative (a guard only demotes),
so every other winner is untouched. `test/test_ml_inputs.jl` stays green (214/214).
