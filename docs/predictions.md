# Predicting RES & loads — the open, reproducible input model

This is the complete, open recipe for the model behind the site's
**"Predicting RES & loads"** page. It predicts, for every delivery hour and every
zone of the **39-zone footprint**, the **wind, solar and load** the day-ahead
market clears on — strictly ex-ante (D-1 weather only) — from open weather data. A
third party with **no Postgres and no private data** can retrain the models from
scratch, score them, and reproduce our numbers. Everything it needs is either a
free public API or a published artifact.

Provenance is honest and **per target**: 5 pilot zones use committed **LightGBM**
models where they won the scorecard; every other zone uses the **linear weather
packs** the daily forecast actually drives them with. Each series carries a
`src_solar`/`src_wind`/`src_load` label (`ml`|`pack`) — the badge on each zone
panel — and the map colours all 39 zones (see §1 status table).

> The market-clearing counterfactual (prices, order books, the 39-zone footprint)
> is documented in [reproducibility.md](reproducibility.md). This document is only
> about the **input models** that feed the weather forecast track.

> **Download the standalone bundle:** the fitted model (the 5 ML pilot zones'
> LightGBM dumps + a minimal self-contained Python predictor + per-zone output
> parquets) is packaged as a GitHub Release —
> <https://github.com/philokalia-ai/energy-markets/releases/tag/input-model-v1.0.0>.
> With no Euphemia, no Julia and no Postgres you can load the per-zone predictions
> as data and run the model for new days from the public open-meteo API. Rebuild it
> with [`bin/build_input_model_bundle.sh`](../bin/build_input_model_bundle.sh)
> (sources in [`bin/input_model_bundle/`](../bin/input_model_bundle/)).

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

### Footprint status (which model produces each target)

The 5-zone pilot was rolled out to the **whole 39-zone footprint** (see
[`docs/experiments/input-upgrade/rollout-39.md`](experiments/input-upgrade/rollout-39.md)).
Provenance is resolved per zone-target at RUN time from
[`bin/input_models/meta.json`](../bin/input_models/meta.json) (`pilot_zones` +
`winners`) via `ml_pilot_zones()` / `ml_use_new()` in `bin/ml_inputs.jl`, exactly
as `bin/daily_forecast.jl` reads it with `EUPHEMIA_ML_INPUTS` on:

| class | count | solar | wind | load |
|-------|-------|-------|------|------|
| **NEW LightGBM** | **76 of 117 zone-targets** (38 load, 22 solar, 16 wind) | per-winner | per-winner | 38/39 zones |
| **linear pack** | 41 zone-targets (incl. all of NO4) | pack | pack | pack |

Each (zone, target) ships whichever beat the other on the frozen OOS scorecard.
**Load is a near-universal NEW winner (38/39 zones)**; solar NEW on 22 modeled
zones (7 skip — no meaningful solar: NO1-5, SE1, RS); wind NEW on 16 (the physical
power-curve pack still wins the low/onshore zones; 7 skip). **76 winner LightGBM
models** live in [`bin/input_models/`](../bin/input_models/) with geometry from
[`geom.json`](../bin/input_models/geom.json) (39 zones); losers ship no model and
fall back to the pack. Pack zones reuse the SAME committed weather packs:
[`bin/res_models_v2.json`](../bin/res_models_v2.json) (RES ridges via
`predict_solar_hour`/`predict_wind_hour`) and
[`bin/load_models_v1.json`](../bin/load_models_v1.json) (per-zone ridge via
`predict_load`). Every row's `src_*` label records which model produced each
target, and the manifest tags each zone `model: ml|pack`.

> Sections 3–7 below detail the **LightGBM** pilot models. The linear-pack recipe
> (the same one the live forecast uses for the other 34 zones) is documented under
> [`docs/experiments/res-forecasting/`](experiments/res-forecasting/) (wind/solar
> ridges) and [`docs/experiments/dn-load-model/`](experiments/dn-load-model/)
> (the D-n load ridge); the exporter reuses their committed packs verbatim.

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
`previous-runs-api.open-meteo.com` (HTTP 429 "Daily API request limit exceeded"
under load). We reduce that dependency from two sides:

- **Fetch preference (local-first).** `fetch_weather` / `fetch_load_weather`
  resolve the previous-runs base URL from `EUPHEMIA_OPENMETEO_PREVRUNS_URL`
  (default the public API) and now fall back to the public API **on both an
  error AND a null-data response** — a self-hosted instance that answers HTTP 200
  with all-null `previous_dayN` arrays (it holds no previous-run chunks) is
  treated as "no usable answer" and the batch is re-fetched publicly
  (`_batch_all_empty`, unit-tested; the guard never fires for an explicit
  `base_url` or when the primary already IS public). So pointing
  `EUPHEMIA_OPENMETEO_PREVRUNS_URL` at the local instance is safe today (it
  transparently falls through) and becomes free the moment the instance can serve
  previous runs. *Why the self-hosted mirror can't serve previous_dayN yet, and
  what it would take, is documented in the infra repo
  `manifests/weather/PREVIOUS_RUNS.md`.*

- **Durable archive.** [`bin/capture_gfs_vintages.jl`](../bin/capture_gfs_vintages.jl)
  (nightly `capture-gfs-vintages.yml`, ~07:30 UTC after the pre-gate forecast)
  appends the day's `previous_day1..7` vintages for the union of all 39 zones'
  RES cells + load cities into **`data/gfs_vintages/`** — one parquet per delivery
  day (`delivery_date, valid_time_utc, lead_days, lat, lon, variable, value`),
  reusing the exact serve-time fetch machinery. It is **idempotent** (existing
  day-files are skipped unless `EUPHEMIA_VINTAGE_FORCE=true`), **additive**, and
  **non-fatal** (per-day failures — including a rate-limited public window — are
  warned and retried on the next run; the process always exits 0). This is the
  in-our-control safety-net that de-risks the public history ageing out or the
  rate limit tightening. **Warm-up:** deep leads for a just-completed day may sit
  at the edge of the public API's ~7-day previous-runs window and return null;
  those rows are simply absent and accrue as the runs land — coverage is honest,
  never fabricated.

## 3. Features (all admissible at the D-1 gate)

Replicated exactly by [`features.py`](experiments/input-upgrade/features.py) (train)
and [`bin/ml_inputs.jl`](../bin/ml_inputs.jl) (serve):

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

> **Train/serve consistency rule (owner):** the serve-time port replicates
> `features.py` *exactly as trained*, changed only IN LOCKSTEP with it. The
> rollout-39 retrain fixed GR's holidays to the **Orthodox** (Julian/Meeus) Easter
> and added BG/RO/RS Orthodox maps — applied to `features.py` `orthodox_easter` AND
> `bin/ml_inputs.jl` `ml_orthodox_easter` together (asserted byte-identical for all
> mapped countries). ES/DE/SE keep the Western Easter; unmapped countries carry no
> holiday map; degree-hour bases stay the hard-coded 21.0/16.5 °C. A serve-time
> "fix" out of lockstep would introduce skew. See the `bin/ml_inputs.jl` header and
> the asserts in `test/test_ml_inputs.jl`.

## 4. Training protocol (frozen)

Full protocol: [`docs/experiments/input-upgrade/protocol.md`](experiments/input-upgrade/protocol.md);
driver: [`train.py`](experiments/input-upgrade/train.py).

- **Data window** 2024-07-14 … 2026-07-22 (previous_day1 dense from ~2024-07).
  **Train** 2024-07-14 … 2026-04-30; **OOS valid** 2026-05-01 … 2026-07-22
  (the deliberately-hard recent regime). Time-ordered, no shuffling; capacity/AR
  features are strict-past so folds do not leak.
- **Model:** LightGBM, L1 objective (MAE-aligned), per zone-target, `num_leaves ≤ 31`,
  `lr = 0.05`, `n_estimators ≤ 600`, early-stopped on a time-ordered inner tail.
  Predictions clamped ≥ 0; solar clamped to 0 at night (sun elevation = 0).
- **Per-zone-winner selection:** each (zone, target) ships whichever of {new
  LightGBM, committed linear pack} won the OOS scorecard. Across the 39-zone
  footprint **76 of 117 zone-targets ship NEW** (rollout-39: load 38/39, solar 22,
  wind 16); the winners live in `meta.json`'s `winners` map, resolved at run time
  (see [`rollout-39.md`](experiments/input-upgrade/rollout-39.md) for the full
  scorecard). The badge next to each chart on the page shows which is live.
- **GFS vintage cache:** the honest `previous_day1` vintages fetched for train (and
  reused at serve) are cached durably in **`data/gfs_vintages/`** (git-ignored,
  ~136 MB, one parquet per zone × time-chunk) so future retrains never re-fetch the
  rate-limited open-meteo history.
- **Export:** each booster is a LightGBM text dump (`bin/input_models/<zone>_<target>.txt`)
  plus [`meta.json`](../bin/input_models/meta.json) (feature order, best iteration,
  ratio column, night-clamp flag, and the `pilot_zones` / `winners` wiring keys).

## 5. The committed model + the pure-Julia scorer

The daily workflow is dependency-free: [`bin/ml_inputs.jl`](../bin/ml_inputs.jl) is a
self-contained GBDT evaluator (`parse_lgb_model`, `lgb_predict`,
`lgb_node_decision`) + a feature port that replicates `features.py` exactly, reading
the committed text dumps. It is validated **bit-for-bit** against python LightGBM.

## 6. Equivalence numbers (Julia serve == python train)

From [`docs/experiments/input-upgrade/wiring.md`](experiments/input-upgrade/wiring.md)
(5 zones × 4 days × 3 targets):

| level | quantity | max &#124;Δ&#124; |
|-------|----------|-------------------|
| scorer (identical python feature vectors → Julia GBDT) | load / solar / wind | **0** (bit-identical) |
| feature port + full predict (rebuilt from the same GFS parquets + extract) | all 18,240 feature scalars | 5.7e-13 |
| | NEW load MW | **0** |
| | NEW solar / wind MW | 6.99 / 40.3 MW on **2 of 960** hours (a feature within ~1e-13 of a split threshold flips one tree leaf — the documented last-ULP mechanism; the other 958 hours bit-identical) |

## 7. Reproduce with no database

**Retrain from scratch** (open weather + the public extract for targets/capacity):

```bash
# 1. Fetch the D-1 GFS vintages for the pilot cells (free previous-runs API)
python docs/experiments/input-upgrade/fetch_gfs.py       # + fetch_nl.py for NL

# 2. Pull the targets + cap95 from the PUBLIC extract (no Postgres) — or the
#    open ENTSO-E Transparency Platform
python docs/experiments/input-upgrade/pull_targets.py

# 3. Build features and train the 15 LightGBM models
python docs/experiments/input-upgrade/features.py
python docs/experiments/input-upgrade/train.py           # writes bin/input_models/*.txt

# 4. Score OOS + the input-level scorecard
python docs/experiments/input-upgrade/predict_inputs.py
```

**Score the committed models with the Julia port** (proves serve == train), against
the read-only public extract + the public open-meteo API:

```bash
EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-public.duckdb \
  julia --project=. test/scripts/ml_inputs_equivalence.jl
```

**Regenerate the site's Predictions data plane** (the driver + prediction panels
this page renders) — see below.

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
- `v1/inputs/reservoir.parquet` — weekly reservoir `fill_ratio` (share of the
  trailing-52-week max, the seasonal water-value signal `get_reservoir_drawdown`
  uses) and `dryness` (vs the same ISO-week prior-year median, `get_reservoir_dryness`)
  for the hydro zones.
- `v1/inputs/manifest.json` — freshness, the column dictionary, the zone lists
  (`zones` = the full surface, `pilot_zones` = the ML five, `pack_zones` = the
  linear-pack remainder), and the per-zone freshest-day **midday RES-coverage**
  summary the map colours by (each entry tagged `model: ml|pack`).

The additive v1 contract is preserved: the pack zones add **more zone files** and a
`model` field / `zones`+`pack_zones` manifest keys — no existing key is renamed.

**Open-meteo budget.** The full-footprint pull is much larger than the 5-zone
pilot (39 zones, each a RES 4-variable + load 2-variable fetch, batched ≤50
cells/call, one span fetch per zone per admissible vintage group, throttled by
`EUPHEMIA_OPENMETEO_ZONE_THROTTLE` with 429 backoff). `INPUTS_BACK_DAYS` (default
**30**, was `INPUTS_HIST_DAYS`=60 for the pilot) trades trailing-history depth for
the size of that pull — 30 days keeps the daily CI run inside the public rate
budget; raise it for a deeper offline backfill. `INPUTS_ZONES` restricts the run
to a subset. The CI step is **non-fatal** (a transient open-meteo failure warns
and never blocks the core web-data publish).

Run it offline against the extract (mix an ML pilot with pack zones):

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
skill strip on the prediction pages ([`bin/export_prediction_scorecard.jl`](../bin/export_prediction_scorecard.jl),
routes `/api/v1/inputs/{scorecard,skill}`). Unlike the inputs export this is pure
file work (no DB, no open-meteo) — it reads only committed artifacts (the winners
map in `bin/input_models/meta.json`, the 39-zone VALID table in
[`experiments/input-upgrade/rollout-39.md`](experiments/input-upgrade/rollout-39.md),
the 5-pilot [`scorecard.csv`](experiments/input-upgrade/scorecard.csv)):

- `v1/inputs/scorecard.json` — per-(zone,target) VALID `mae_new`/`mae_base`,
  `corr_new`/`corr_base`, `bias_new`, `n_valid`, and the **winner** taken strictly
  from `meta.json` (the corr-guard-reconciled truth: four NEW winners were demoted
  to their pack on a correlation regression — NL_solar/NO2_wind/FR_wind/HU_load —
  so the card tells the honest "ML beaten by pack on corr — pack ships" story). A
  no-resource RES target is its own `skip` state. Collapse hit/false-alarm metrics
  are a solar-only, first-class card element; they are computed at the price level
  (`collapse_metrics.py`) and ship `null` (a **pending** state) until a settled-price
  pass fills them — never fabricated.
- `v1/inputs/skill.json` — per-lead (D-1..D-7) input skill. It ships in a
  `warming_up` state with an empty `skill[]` until the archived GFS `previous_dayN`
  vintages (`bin/capture_gfs_vintages.jl`) accumulate enough days for a non-noisy
  deep-lead score; the strip renders "warming up" and fills lead by lead — no
  fabricated deep-lead rows.

### The three prediction pages (Load · Solar · Wind)

The `#view=predict` surface is a **hub + three sibling pages** under one segmented
sub-nav (`Overview · Load · Solar · Wind`, deep-linked `#view=predict&target=…&zone=…`),
each honoring its own physics (Load: temperature/holidays/AR; Solar: the collapse
cliff + cap95; Wind: the power curve + the onshore-pack-vs-ML honesty), composed
from the shared chart primitives. Design and acceptance criteria:
[`docs/pillars/pillars-2-4-predictions-plan.md`](pillars/pillars-2-4-predictions-plan.md).

## 9. The collapse question (why midday is the whole game)

Near the RES-coverage threshold — when predicted wind+solar approaches load — a
small solar-forecast error flips whether the midday price **collapses** to ≤ €5 (or
below zero) or not. That classification dominates continuous MAE there, so input
accuracy at midday decides whether the price signal is useful at all
([SCIENTIST.md §4](../.claude/SCIENTIST.md)). This is why the map centres on
**tomorrow's predicted midday RES coverage** and flags collapse-risk zones, and why
the input scorecard reports collapse hit / false-alarm rates alongside MAE
([`collapse_metrics.py`](experiments/input-upgrade/collapse_metrics.py)). The
combined-stack price panel — GR collapse detection 8/16 → 13/16 hours with the ML
solar — is in [`wiring.md`](experiments/input-upgrade/wiring.md).
