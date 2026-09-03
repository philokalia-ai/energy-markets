# Predicting RES & loads — the open, reproducible input model

This is the complete, open recipe for the model behind the site's
**"Predicting RES & loads"** page. It predicts, for every delivery hour and every
zone of the **39-zone footprint**, the **wind, solar and load** the day-ahead
market clears on — strictly ex-ante (D-1 weather only) — from open weather data. A
third party with **no Postgres and no private data** can retrain it from scratch,
score it and reproduce our numbers from free public APIs and published artifacts.

Provenance is honest and **per (zone, target)**: each one ships whichever of
{LightGBM, the committed linear weather pack} won the frozen out-of-sample
scorecard. The winner map in
[`bin/input_models/meta.json`](../bin/input_models/meta.json) is the single source
of truth and moves at every retrain, so this document points at it rather than
transcribing it. Each series carries a `src_solar`/`src_wind`/`src_load` label
(`ml`|`pack`) — the badge on each zone panel.

> The market-clearing counterfactual (prices, order books, the 39-zone footprint)
> is documented in [reproducibility.md](reproducibility.md). This document is only
> about the **input models** that feed the weather forecast track.

> **Standalone bundle:** the fitted model is also packaged as a GitHub Release —
> <https://github.com/philokalia-ai/energy-markets/releases/tag/input-model-v1.0.0>
> (models + a minimal self-contained Python predictor + per-zone output parquets;
> no Julia, no Postgres). That release is the **5-zone pilot** (GR/ES/DE_LU/SE2/NL),
> frozen at v1.0.0 — the live system runs all 39 zones. Sources and its own README:
> [`bin/input_model_bundle/`](../bin/input_model_bundle/), builder
> [`bin/build_input_model_bundle.sh`](../bin/build_input_model_bundle.sh).

## 1. What we predict, and against what

For delivery day **D**, three targets per zone-hour — the **ENTSO-E day-ahead
forecasts** the auction actually clears on (NOT the settled outturn):

| target | source table | column |
|--------|--------------|--------|
| **load** | `entsoe.day_ahead_total_load_forecast` (`area_type_code LIKE 'BZN%'`) | `total_load_mw` |
| **solar** | `entsoe.generation_forecasts_for_wind_and_solar`, `production_type='Solar'` | `day_ahead_generation_forecast_mw` |
| **wind** | same table, `production_type IN ('Wind Onshore','Wind Offshore')`, summed | `day_ahead_generation_forecast_mw` |

Predicting the *reference* (not outturn) is deliberate: if our predicted inputs
equal the TSO's published forecast, the ex-ante weather track converges to the
reference track's price quality. Error is measured against what the market used.

### Which model produces each target

Provenance is resolved per zone-target at RUN time from `meta.json`
(`pilot_zones` + `winners`) via `ml_pilot_zones()` / `ml_use_new()` in
`bin/ml_inputs.jl`, exactly as `bin/daily_forecast.jl` reads it with
`EUPHEMIA_ML_INPUTS` on. Count today's split from the artifact:

```bash
python3 -c "import json; w=json.load(open('bin/input_models/meta.json'))['winners']; \
print(sum(w.values()), 'LightGBM winners of', len(w), 'zone-targets')"
```

The *shape* is stable across retrains even though the membership is not: **load is
the near-universal LightGBM winner** (every zone at the last retrain); solar wins
on most zones with meaningful solar (NO1–NO5, SE1 and RS have none — those targets
are a `skip` state); **wind is the contested target** — the physical power-curve
pack still wins many low/onshore zones. One LightGBM text dump ships per winner in
[`bin/input_models/`](../bin/input_models/), with geometry from
[`geom.json`](../bin/input_models/geom.json) (39 zones); losers ship no model and
fall back to the committed packs — [`bin/res_models_v2.json`](../bin/res_models_v2.json)
(RES ridges, `predict_solar_hour`/`predict_wind_hour`) and
[`bin/load_models_v1.json`](../bin/load_models_v1.json) (per-zone ridge,
`predict_load`). The full per-zone scorecard is in
[`rollout-39.md`](experiments/input-upgrade/rollout-39.md); the pack recipe itself
is under [`docs/experiments/res-forecasting/`](experiments/res-forecasting/) and
[`docs/experiments/dn-load-model/`](experiments/dn-load-model/).

## 2. Honest ex-ante weather (the vintage discipline)

Every weather input is a **GFS `gfs_seamless` `previous_day1` vintage** from the
free [open-meteo previous-runs API](https://open-meteo.com/en/docs/previous-runs-api):
for hour *h* of day D it carries the value predicted by the run **issued on D-1** —
never a later run that would peek across the 12:00 CET auction gate. This is the
same discipline the live forecast uses ([`bin/weather_vintage.jl`](../bin/weather_vintage.jl)),
applied identically at **train and serve** time so there is no train/serve skew.
On the site, every number is labelled by the vintage (`vintage_lag`: 0 = the run
current at the horizon, 1 = the D-1 previous-run vintage for settled history).

Drivers, per zone-hour (mean over the zone's weather cells; pop-weighted over its
cities for load):

- **RES cells:** `wind_speed_100m`, `shortwave_radiation` (GHI), `cloud_cover`, `surface_pressure`
- **Load cities:** `temperature_2m`, `shortwave_radiation`

### Where the vintages come from (local-first, with a durable archive)

The `previous_dayN` history is served publicly only by the rate-limited
`previous-runs-api.open-meteo.com` (HTTP 429 under load). Two mitigations:

- **Local-first fetch.** `fetch_weather` / `fetch_load_weather` resolve the base
  URL from `EUPHEMIA_OPENMETEO_PREVRUNS_URL` (default: public) and fall back to
  the public API on an error **or** an all-null response (`_batch_all_empty`,
  unit-tested) — so a self-hosted instance that cannot yet serve previous runs is
  safe to point at today. *Why it can't yet: the infra repo's
  `manifests/weather/PREVIOUS_RUNS.md`.*

- **Durable archive.** [`bin/capture_gfs_vintages.jl`](../bin/capture_gfs_vintages.jl)
  (nightly `capture-gfs-vintages.yml`, ~07:30 UTC) appends the day's
  `previous_day1..7` vintages for all 39 zones' cells and cities into
  **`data/gfs_vintages/`** — one parquet per delivery day (`delivery_date,
  valid_time_utc, lead_days, lat, lon, variable, value`), through the exact
  serve-time fetch machinery. Idempotent, additive and non-fatal (always exits 0;
  `EUPHEMIA_VINTAGE_FORCE=true` to rewrite a day). Deep leads for a just-completed
  day can sit at the edge of the public ~7-day window and return null — those rows
  are simply absent and accrue as the runs land, never fabricated.

## 3. Features (all admissible at the D-1 gate)

Replicated exactly by [`features.py`](experiments/input-upgrade/features.py) (train)
and [`bin/ml_inputs.jl`](../bin/ml_inputs.jl) (serve). Each model's exact feature
order is its `feat_cols` in `meta.json`.

- **Weather drivers** above.
- **Solar geometry:** clamped sun elevation `sinel(lat, lon, doy, hour)`; clearness
  index `GHI / (S0·sinel)`.
- **Calendar:** hour-of-day, day-of-week, day-of-year Fourier terms (1st + 2nd
  harmonic), a static per-country holiday flag.
- **Degree-hours (load):** CDH/HDH about 21.0 / 16.5 °C, their squares, and the
  **trailing-48 h** temperature mean.
- **Capacity normalization (RES):** `cap95` = the trailing-30-day 95th-percentile
  of actual per-type generation (`entsoe.aggregated_generation_per_type`), window
  **ending D-2** (actual generation publishes with ~1–2 d lag). Wind and solar
  models predict a **ratio** against `cap95`, so a growing fleet does not drift the
  forecast.
- **Autoregressive (load):** the D-1 and D-7 same-hour DA load forecasts (both
  known at the gate).
- **DE_LU load only (fit-iteration 6):** `school_hol`, a deterministic German
  school-holiday flag (Christmas, the Jul 15–Aug 31 summer envelope, autumn,
  Easter ±7 d), and `windchill` (Environment Canada JAG/TI on the zone-mean 100 m
  wind as an ex-ante cold-stress proxy). Inert for every other model — no other
  `feat_cols` references them.

> **Train/serve consistency rule (owner):** the serve-time port replicates
> `features.py` *exactly as trained*, changed only IN LOCKSTEP with it. GR/BG/RO/RS
> use the **Orthodox** (Julian/Meeus) Easter, applied to `features.py`
> `orthodox_easter` AND `bin/ml_inputs.jl` `ml_orthodox_easter` together (asserted
> byte-identical); ES/DE/SE keep the Western Easter; unmapped countries carry no
> holiday map; degree-hour bases stay the hard-coded 21.0/16.5 °C. Iteration 6's
> two DE_LU features were added to both sides in the same commit and are
> lockstep-tested (`cmp_dnload_iter6.py`, `test/test_ml_inputs.jl`). A serve-time
> "fix" out of lockstep would introduce skew.

## 4. Training protocol (frozen)

Full protocol: [`docs/experiments/input-upgrade/protocol.md`](experiments/input-upgrade/protocol.md);
39-zone driver: [`train39.py`](experiments/input-upgrade/train39.py) (`train.py` is
the superseded 5-zone pilot trainer).

- **Data window** 2024-07-14 … 2026-07-27 (`previous_day1` dense from ~2024-07).
  Last retrain (fit-iteration 4, 2026-08-02): **train** 2024-07-14 … 2026-06-14,
  **OOS valid** 2026-06-15 … 2026-07-27 (the last ~6 weeks). Time-ordered, no
  shuffling; capacity/AR features are strict-past so folds do not leak.
- **Model:** LightGBM, L1 objective (MAE-aligned), per zone-target, `num_leaves ≤ 31`,
  `lr = 0.05`, `n_estimators ≤ 600`, early-stopped on a time-ordered inner tail.
  Predictions clamped ≥ 0; solar clamped to 0 at night (sun elevation = 0).
- **Per-zone-winner selection:** LightGBM ships only where it beat the pack on the
  OOS window **and** lost no more than 0.02 Pearson corr (the fit-iteration 1
  corr guard — a model that wins MAE by flattening the shape does not ship). The
  outcome is `meta.json`'s `winners` map, resolved at run time.
- **GFS vintage cache:** the honest `previous_day1` vintages fetched for train (and
  reused at serve) are cached durably in **`data/gfs_vintages/`** (git-ignored,
  one parquet per zone × time-chunk) so retrains never re-fetch the rate-limited
  open-meteo history.
- **Export:** each booster is a LightGBM text dump (`bin/input_models/<zone>_<target>.txt`,
  one per winner) plus [`meta.json`](../bin/input_models/meta.json) (feature order,
  best iteration, ratio column, night-clamp flag, `pilot_zones` / `winners`).

## 5. The committed model + the pure-Julia scorer

The daily workflow is dependency-free: [`bin/ml_inputs.jl`](../bin/ml_inputs.jl) is a
self-contained GBDT evaluator (`parse_lgb_model`, `lgb_predict`,
`lgb_node_decision`) + a feature port that replicates `features.py` exactly, reading
the committed text dumps.

## 6. Equivalence (Julia serve == python train)

[`test/scripts/ml_inputs_equivalence.jl`](../test/scripts/ml_inputs_equivalence.jl)
scores the committed models two ways: PART 1 feeds python's own reference feature
vectors into the Julia GBDT (isolates parser + tree math), PART 2 rebuilds every
feature in Julia from the same GFS parquets + extract. It is re-run on every
retrain and is a ship gate. At the last retrain (fit-iterations 4 and 6, spot set
of pilot + rollout zones): **scorer max |Δ| = 0** (bit-identical), feature port
relative diff **< 1e-9**, **0 of 1080** split-flips. It needs
`dump_eval39.py`'s reference dump and the GFS parquets present first.

## 7. Reproduce with no database

**Retrain from scratch** (open weather + the public extract for targets/capacity):

```bash
# 1. Fetch the D-1 GFS vintages for every zone's cells (free previous-runs API)
python docs/experiments/input-upgrade/fetch_new.py     # per-zone resumable

# 2. Pull the targets + cap95 from the PUBLIC extract (no Postgres) — or the
#    open ENTSO-E Transparency Platform
python docs/experiments/input-upgrade/pull_all.py

# 3. Build features and train; writes the winners to bin/input_models/*.txt + meta.json
python docs/experiments/input-upgrade/train39.py

# 4. Score OOS + the input-level scorecard
python docs/experiments/input-upgrade/predict_inputs.py
```

**Regenerate the site's Predictions data plane** — see §8.

## 8. The site data plane (`v1/inputs/`)

[`bin/export_prediction_inputs.jl`](../bin/export_prediction_inputs.jl) reuses the
same fetch/scorer machinery to emit the additive `v1/inputs/` parquet contract the
Predictions page reads through the Worker API (`workers/api/`, routes
`/api/v1/inputs/{manifest,reservoir,scorecard,skill,<zone>}`):

- `v1/inputs/<ZONE>.parquet` — one file per footprint zone, per zone-hour over a
  trailing window (default 30 days, `INPUTS_BACK_DAYS`) + the forecast horizon: the
  five drivers (`temp_c`, `ghi_wm2`, `cloud_pct`, `pressure_hpa`, `wind100_ms`),
  the per-zone-winner prediction (`pred_solar_mw`, `pred_wind_mw`, `pred_res_mw`,
  `pred_load_mw`), the ENTSO-E DA reference (`ref_*_mw`, null where unpublished),
  the settled actual (`act_*_mw`, null until settled), the per-target provenance
  labels (`src_solar`/`src_wind`/`src_load` = `ml`|`pack`), and `vintage_lag`.
- `v1/inputs/reservoir.parquet` — per hydro zone, weekly `fill_ratio` (share of the
  trailing-52-week max, the signal `get_reservoir_drawdown` uses) and `dryness`
  (vs the same ISO-week prior-year median, `get_reservoir_dryness`).
- `v1/inputs/manifest.json` — freshness, the column dictionary, the zone lists and
  the per-zone freshest-day **midday RES-coverage** summary the map colours by.
  The legacy key names still describe the ML/pack split: `zones` = the full
  surface, `pilot_zones` = zones carrying at least one LightGBM winner,
  `pack_zones` = the pure-pack remainder (both derived from `meta.json`, so
  `pack_zones` is empty while every zone has a winner).

**Open-meteo budget.** The full-footprint pull is 39 zones × (a RES 4-variable +
a load 2-variable fetch), batched ≤50 cells/call, one span fetch per zone per
vintage group, throttled by `EUPHEMIA_OPENMETEO_ZONE_THROTTLE` with 429 backoff.
`INPUTS_BACK_DAYS` (default **30**) trades trailing-history depth against the size
of that pull — 30 days keeps the daily CI run inside the public rate budget;
`INPUTS_ZONES` restricts it to a subset. The CI step is **non-fatal**: a transient
open-meteo failure warns and never blocks the core web-data publish.

Run it offline against the extract:

```bash
EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-public.duckdb \
INPUTS_ZONES="GR,PL,IT-NORTH" INPUTS_BACK_DAYS=2 INPUTS_ASOF=2026-07-27 \
  julia --project=. bin/export_prediction_inputs.jl
```

In CI it runs in the same publish step as `bin/export_web_parquet.jl`
(`.github/workflows/daily-forecast.yml`), then `bin/web_data_push.sh` syncs
`data/web/v1/` to R2 with the manifest uploaded last.

### The model-card + skill artifacts (`scorecard.json`, `skill.json`)

Two **additive** JSON side-artifacts feed the per-zone model card and the per-lead
skill strip ([`bin/export_prediction_scorecard.jl`](../bin/export_prediction_scorecard.jl),
routes `/api/v1/inputs/{scorecard,skill}`). Unlike the inputs export this is pure
file work (no DB, no open-meteo) — it reads only committed artifacts (`meta.json`,
the 39-zone VALID table in [`rollout-39.md`](experiments/input-upgrade/rollout-39.md),
the pilot [`scorecard.csv`](experiments/input-upgrade/scorecard.csv)):

- `v1/inputs/scorecard.json` — per-(zone,target) VALID `mae_new`/`mae_base`,
  `corr_new`/`corr_base`, `bias_new`, `n_valid`, and the **winner** taken strictly
  from `meta.json`. Where the corr guard demoted a lower-MAE LightGBM model the
  card tells that story rather than hiding it; a no-resource RES target is its own
  `skip` state. Solar cards also carry collapse hit/false-alarm rates, computed at
  the price level (`collapse_metrics.py`) and `null` (**pending**) until a
  settled-price pass fills them — never fabricated.
- `v1/inputs/skill.json` — per-lead (D-1..D-7) input skill. Ships `warming_up` with
  an empty `skill[]` until the archived `previous_dayN` vintages accumulate enough
  days for a non-noisy deep-lead score, then fills lead by lead — no fabricated
  deep-lead rows.

### The three prediction pages (Load · Solar · Wind)

The `#view=predict` surface is a hub plus three sibling pages under one segmented
sub-nav (deep-linked `#view=predict&target=…&zone=…`), each honoring its own
physics: Load temperature/holidays/AR, Solar the collapse cliff + cap95, Wind the
power curve and the onshore pack-vs-ML honesty. Design and acceptance criteria:
[`docs/pillars/pillars-2-4-predictions-plan.md`](pillars/pillars-2-4-predictions-plan.md).

## 9. The collapse question (why midday is the whole game)

Near the RES-coverage threshold — when predicted wind+solar approaches load — a
small solar-forecast error flips whether the midday price **collapses** to ≤ €5 (or
below zero). That classification dominates continuous MAE there, so input accuracy
at midday decides whether the price signal is useful at all. Hence the map centres
on tomorrow's predicted **midday RES coverage**, and the scorecard reports collapse
hit / false-alarm rates alongside MAE
([`collapse_metrics.py`](experiments/input-upgrade/collapse_metrics.py)). The
combined-stack price panel — GR collapse detection 8/16 → 13/16 hours with the ML
solar, measured on the 5-zone pilot — is in
[`wiring.md`](experiments/input-upgrade/wiring.md).
