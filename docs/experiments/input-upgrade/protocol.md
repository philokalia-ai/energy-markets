# INPUT-UPGRADE PROTOCOL (FROZEN 2026-07-31)

## Mission
Predict the REFERENCE INPUTS (not actuals) with ML, strictly ex-ante, better than
the committed linear packs (bin/res_models_v2.json, bin/load_models_v1.json).
Then verify at PRICE level whether it collapses GR July-2026 middays.

## TARGETS (per zone-hour, hourly-aggregated from PT15M/PT60M)
- LOAD:  entsoe.day_ahead_total_load_forecast, area_type_code LIKE 'BZN%', total_load_mw
- SOLAR: entsoe.generation_forecasts_for_wind_and_solar, production_type='Solar',
         day_ahead_generation_forecast_mw
- WIND:  same table, production_type IN ('Wind Onshore','Wind Offshore'), summed
These are the D-1 forecasts the reference track clears on (scores 0.78-0.86). If our
predicted inputs == these, the ex-ante (weather) track converges to reference quality.

## PILOT ZONES
GR (mandatory), ES, DE_LU, SE2. Geometry (cells/cities) reused from the committed
packs verbatim (geom.json). 12 models = 4 zones x {load, solar, wind}.

## FEATURES (every one available at the 08:00 UTC D-1 gate; lag stated)
Weather = GFS gfs_seamless PREVIOUS_DAY1 vintages from open-meteo previous-runs API
(per-timestamp: hour h of day D as predicted by the run issued D-1). Honest ex-ante.
  RES cells (mean over zone cells): wind_speed_100m, shortwave_radiation(GHI),
    cloud_cover, surface_pressure  [lag: issued D-1, admissible]
  Load cities (pop-weighted mean): temperature_2m, shortwave_radiation  [D-1]
Derived:
  - clearness index = GHI / TOA(lat,doy,hour); TOA from astronomy [D-1]
  - sun elevation (sinel), hour-of-day, hour-of-week, day-of-year Fourier [known]
  - degree-hours: CDH(T,base), HDH, T^2, 24h-MA of T [D-1 weather]
  - holiday flag (workalendar-free static list per country) [known]
CAPACITY / adaptive (attacks fleet-growth bias):
  - trailing-30d p95 of actual per-type generation (aggregated_generation_per_type),
    window ENDING D-2 (actual-gen publishes with ~1-2d lag; D-2 is safe) [lag D-2]
AUTOREGRESSIVE (load):
  - DA load forecast for D-1 same hour (target-of-yesterday, known at D-1 gate) [D-1]
  - DA load forecast for D-7 same hour [known]
  (RES AR: trailing p95 capacity already carries the level; skip AR to avoid leakage.)

## TRAIN / VALIDATION (time-ordered, no leakage)
Data window: 2024-07-14 .. 2026-07-22 (previous_day1 dense from ~2024-07; targets to 07-29).
  TRAIN:  2024-07-14 .. 2026-04-30
  VALID (OOS, primary — the failure regime): 2026-05-01 .. 2026-07-22
Time-ordered only; no shuffling. Capacity/AR features are strict-past so no fold leakage.
Report a secondary fold (2025-06-01..2025-08-31 summer) if time permits.

## MODELS
LightGBM gradient boosting, objective L1 (MAE-aligned), per zone-target. Modest depth
(num_leaves<=31, lr 0.05, n_estimators<=600, early-stop on a time-ordered inner tail).
Clamp predictions >=0. Solar clamped to 0 when sun elevation==0 (night).
Export: LightGBM model .txt + a python inference script emitting a per-day inputs
parquet (zone, ts, load_mw, solar_mw, wind_mw) the pipeline consumes.

## METRICS (input-level scorecard, per zone x target, on VALID window)
MAE (MW), bias (pred-target), Pearson corr, and normalized MAE (MAE/mean(target)).
Baseline = committed packs scored on the SAME valid window & SAME GFS-vintage weather
(re-implement the pack feature vectors from res/load JSON coefficients in python).
Report new vs baseline vs target side by side.

## PRICE-LEVEL TEST (the owner's question)
Days: 2026-07-24 .. 2026-07-28 (in extract) GR + ES/DE_LU/SE2 as controls.
Clear the SOTA multi-zone EU model (current main) via run_multi_zone_market_clearing
with a ZoneScenario per arm:
  ARM-new: renewable_modifier->0 + inject predicted RES (this model) as price-taker
    supply; load_modifier -> predicted load. (Replicates bin/daily_forecast weather track.)
  ARM-baseline: same but inputs from the committed packs.
Report GR midday hours (UTC 09-15) price for: settled actual (~0), reference track,
baseline weather track, new weather track. Question: does new collapse GR July middays
to <= EUR 5-10?

## SHIP GATE
Ship only if (a) input-level MAE materially better than baseline on VALID (esp. GR
solar midday), AND (b) price-level GR middays move toward reference/settled without
breaking control zones. Non-draft PR only with price-level results. Branch unmerged.

## PROVENANCE / HONESTY NOTES
- Weather is GFS D-1 vintage for BOTH train and serve -> no train/serve skew.
- Targets are the ENTSO-E DA forecasts (the reference consumables), NOT actuals.
- Extract euphemia-live.duckdb ends 2026-07-28 (data) / weather ERA5 2026-07-22.
  GFS vintages fetched live for the whole window incl. the price-test days.
