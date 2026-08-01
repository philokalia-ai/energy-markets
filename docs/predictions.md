# Predicting RES & loads — the open, reproducible input model

This is the complete, open recipe for the model behind the site's
**"Predicting RES & loads"** page. It predicts, for every delivery hour and every
pilot zone, the **wind, solar and load** the day-ahead market clears on — strictly
ex-ante (D-1 weather only) — from open weather data. A third party with **no
Postgres and no private data** can retrain the models from scratch, score them,
and reproduce our numbers. Everything it needs is either a free public API or a
published artifact.

> The market-clearing counterfactual (prices, order books, the 39-zone footprint)
> is documented in [reproducibility.md](reproducibility.md). This document is only
> about the **input models** that feed the weather forecast track.

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

**Pilot zones (5, with committed model dumps):** GR, ES, DE_LU, SE2, NL — 3
targets each = **15 LightGBM models** in [`bin/input_models/`](../bin/input_models/).
Zone geometry (weather cells + population-weighted cities) is reused verbatim from
the committed packs ([`geom.json`](../bin/input_models/geom.json)). The other 34
footprint zones keep the linear packs and are out of this surface.

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
> `features.py` *including its known imperfections* (GR holidays use the Western
> Gregorian Easter; only GR/ES/DE/SE carry a holiday map; hard-coded degree-hour
> bases). Fixes happen at the next retrain, never in the port — a serve-time "fix"
> would introduce skew. See the header of `bin/ml_inputs.jl` and the asserts in
> `test/test_ml_inputs.jl`.

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
  LightGBM, committed linear pack} won the OOS scorecard
  ([`scorecard.csv`](experiments/input-upgrade/scorecard.csv)). The live winners
  (`ML_USE_NEW` in `bin/ml_inputs.jl`): load = new on all 5; solar = new on all but
  ES; wind = new only on offshore-heavy NL. The badge next to each chart on the page
  shows which is live.
- **Export:** each booster is a LightGBM text dump (`bin/input_models/<zone>_<target>.txt`)
  plus [`meta.json`](../bin/input_models/meta.json) (feature order, best iteration,
  ratio column, night-clamp flag).

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
`/api/v1/inputs/{manifest,reservoir,<zone>}`):

- `v1/inputs/<ZONE>.parquet` — per zone-hour over a trailing ~60-day window + the
  forecast horizon: the five drivers (`temp_c`, `ghi_wm2`, `cloud_pct`,
  `pressure_hpa`, `wind100_ms`), our per-zone-winner prediction (`pred_solar_mw`,
  `pred_wind_mw`, `pred_res_mw`, `pred_load_mw`), the ENTSO-E DA reference
  (`ref_*_mw`, null where unpublished), the settled actual (`act_*_mw`, null until
  settled), the winner labels (`src_*`), and `vintage_lag`.
- `v1/inputs/reservoir.parquet` — weekly reservoir `fill_ratio` (share of the
  trailing-52-week max, the seasonal water-value signal `get_reservoir_drawdown`
  uses) and `dryness` (vs the same ISO-week prior-year median, `get_reservoir_dryness`)
  for the hydro zones.
- `v1/inputs/manifest.json` — freshness, the column dictionary, and the per-zone
  freshest-day **midday RES-coverage** summary the map colours by.

Run it offline against the extract (small window shown; production is 60 days):

```bash
EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-public.duckdb \
INPUTS_HIST_DAYS=14 INPUTS_ASOF=2026-07-27 \
  julia --project=. bin/export_prediction_inputs.jl
```

In CI it runs in the same publish step as `bin/export_web_parquet.jl`
(`.github/workflows/daily-forecast.yml`), then `bin/web_data_push.sh` syncs
`data/web/v1/` to R2 with the manifest uploaded last.

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
