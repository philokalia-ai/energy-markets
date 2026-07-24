# Weather → RES prediction experiments (July 2026)

Scripts behind `docs/res-forecasting-investigation.md`. GR, 2025-07-01 →
2026-06-30, train Jul–Mar / test Apr–Jun 2026 (out-of-sample). They read CSVs
extracted next to the scripts; regenerate them with the SQL below
(`ENERGY_CONN_STR` / `WEATHER_CONN_STR` from `.env`).

| script | what it measures |
|---|---|
| `fit_res.jl` | solar + wind skill from national-avg weather vs the ENTSO-E DA forecast benchmark |
| `fit_wind2.jl` | multi-site wind (top-20 distinct grid cells, per-site power curve) on ERA5 and true forecast inputs |
| `make_predictions.jl` | emits the OOS hourly RES predictions used by the price test |
| `price_test.jl` | 12-day GR `:merit_order` price run with weather-RES substituted via `renewable_modifier`, vs the production baseline |

## Data extraction

`actual.csv` / `da_forecast.csv` (energy DB): hourly GR Solar + Wind Onshore
from `entsoe.aggregated_generation_per_type` / `entsoe.generation_forecasts_for_wind_and_solar`,
deduped `DISTINCT ON (production_type, date_time_utc) … ORDER BY update_time_utc DESC`,
then `AVG` per `date_trunc('hour', …)`.

`weather_meas.csv` / `weather_fcst.csv` (weather DB): per-hour national
aggregates over all 1,851 cities — `avg(direct_radiation)`, `avg/p75/p90(wind_speed_10m)`,
`avg(temperature_2m)` from `weather.city_measure` / `weather.city_forecast`
(forecast table has **no radiation** — see the investigation doc).

`cells_meas.csv` / `cells_fcst.csv`: hourly `wind_speed_10m` for the top-20
distinct grid cells, selected by uploading the hourly wind-generation series to
a TEMP table in the weather DB and ranking
`corr(city_measure.wind_speed_10m, gen_mw)` per city, deduping identical
correlations (cities sharing an open-meteo grid cell produce identical series).

Findings summary: solar corr 0.92 with radiation + sun-elevation (ENTSO-E
0.95); wind 0.75 on true forecast inputs (ENTSO-E 0.91), bottleneck is 10 m
population-sited data, not the model; substituting weather-RES into the GR
price model costs corr 0.850 → 0.686 — keep ENTSO-E at lead 1, use weather for
earliness and lead 2–7 once the ceres data fixes land.

## v2/v3 (100 m wind + honest vintages, public-API preview)

| script | what it measures |
|---|---|
| `fetch_public.py` | pulls ERA5 100 m wind + GHI (archive API) and honest lead-1/2 GFS vintages (Previous-Runs API) for the selected cells |
| `fit_res_v2.jl` | 40-cell 100 m wind ridge + 20-cell GHI solar, lead-1/2, targets actual & ENTSO-E DAfc |
| `solar_hod_test.jl` | per-hour-of-day solar calibration (corr 0.958→0.988 vs DAfc) |

Price ladder (12 OOS days): ENTSO-E inputs 0.850/€24.6 → v1 0.686 → v2 0.754 →
v3 (hod solar) **0.802/€29.6**. Attribution: wind-only substitution 0.823,
solar-only 0.778. See the investigation doc §4b.

(The "v2/v3" above are GR-only experiment iterations, distinct from the
shipped pack versions below.)

## v2 pack (2026-07-15): wind refit on GFS-vintage features — train/serve mismatch fix

**The bug.** The committed pack `bin/res_models_v1.json` fit its wind models on
ERA5 reanalysis `wind_speed_100m` at the eu_wind_cells, but at inference the
live ex-ante track (`INPUT_MODE=weather` in `bin/daily_forecast.jl`, morning
runs since 2026-07-14) feeds them **GFS forecast** winds from the public
open-meteo forecast API. On the GFS feed the v1 pack has large, zone-specific
level errors — about **−29 % wind volume for GR** (act/pred 1.41 at lead 1),
DE_LU/NL/FR under-predicted ~40–50 %, PL/HU over-predicted ~35–45 % — with
hourly corr degrading 0.83 at lead 1 → 0.41 at lead 7 (measured in
docs/experiments/dn-load-model/README.md §4). Solar (GHI) does not have this
problem (level 0.96–0.97, corr 0.94–0.96 at all leads) and is untouched.

**The refit.** Same model family and cells as v1 — per-zone ridge on
`[1, pcurve.(v100_cells), v100_cells/3.6]` — but the training features are the
**GFS-vintage** winds the live track actually consumes:
`wind_speed_100m_previous_day1` (`gfs_seamless`) from the public open-meteo
previous-runs API (what GFS predicted ~1 day ahead; dense from ~mid-2024).
Targets: hourly zone wind actuals (Wind Onshore + Offshore, dedup-by-update_time
+ BZN filters) from `entsoe.aggregated_generation_per_type`. Train
2024-07-01..2026-05-04 (λ by 5-fold chronological CV), holdout = the last
8 weeks (2026-05-05..2026-06-30). All 37 zones with v1 wind models were refit.
Because v1 and v2 are linear in the same features, each zone may ship a convex
blend `α·v2 + (1−α)·v1_level-rescaled` (α picked on a pre-holdout slice by
corr; α=1 i.e. pure v2 in 22/37 zones — stored as `alpha_v1_blend`). Cells and
solar coefficients are copied from v1 verbatim (feature vectors in
`bin/weather_res.jl` unchanged, guarded by test/test_weather_res.jl).

| script | what it does |
|---|---|
| `fetch_gfs_vintages.py` | pulls `wind_speed_100m_previous_day1` for all 1,403 wind-zone cells (batched, chunked, resumable, hourly/daily-rate-limit aware; `GFS_OUT` sets the cache dir) |
| `fetch_wind_targets.sh` | extracts hourly zone wind actuals + the GR ENTSO-E D-1 wind forecast from Postgres |
| `fit_wind_gfs.py` | assembles features/targets, refits the 37 wind ridges, prints the v1-on-GFS vs v2-on-GFS validation table, `--emit` writes `bin/res_models_v2.json` |
| `wind_gfs_validation.csv` | the full 37-zone held-out validation table |

### Validation (held-out last 8 weeks, both models on the SAME GFS features)

Headline zones (`pred/act` = volume ratio, 1.00 = unbiased; full table in
`wind_gfs_validation.csv`):

| zone | v1 corr | v1 MAE | v1 pred/act | v2 corr | v2 MAE | v2 pred/act |
|---|---|---|---|---|---|---|
| GR | 0.795 | 479 | 0.71 | **0.881** | **313** | **0.93** |
| DE_LU | 0.915 | 4551 | 0.57 | **0.923** | **2147** | **1.00** |
| FR | 0.902 | 1646 | 0.60 | **0.909** | **873** | **1.08** |
| ES | 0.770 | 2057 | 0.57 | **0.836** | **1196** | **1.15** |
| NL | 0.896 | 980 | 0.52 | **0.908** | **495** | **1.04** |
| BE | 0.914 | 540 | 0.62 | **0.918** | **332** | **0.97** |
| IT-SOUTH | 0.769 | 578 | 0.52 | **0.857** | **336** | **1.06** |
| PT | 0.739 | 728 | 0.40 | **0.844** | **365** | **1.12** |
| NO2 | 0.772 | 151 | 0.49 | **0.847** | **122** | **1.30** |
| PL | 0.888 | 701 | 1.36 | 0.888 | **478** | **1.16** |
| SE3 | 0.909 | 296 | 1.25 | 0.909 | **202** | **1.07** |

Across all 37 zones: **v2 beats v1-on-GFS corr in 30/37** (losses are small,
≤0.03, mostly tiny-fleet or Norwegian zones), **MAE improves in 33/37**
(often halved), and the mean absolute volume bias drops **0.29 → 0.14**. The
GR −29 % headline bias becomes −7 %.

Two honesty notes on that table: (1) v1 was *trained* on ERA5 through
2026-06-30, so it has seen the holdout targets — the comparison is tilted in
v1's favor; a leakage-free replay (train to 2025-05, evaluate May-Jun 2025)
shows the same picture. (2) The residual v2 biases cluster at **+5..+15 % in
May–June specifically** — a seasonal level effect (early-summer stability /
curtailment) that this feature family cannot express. On a **year-round** OOS
window (train 2024-07..2025-05, evaluate 2025-05..2026-06) v2 volume bias is
within ±5 % in 17/36 zones with mean |bias| 0.07, vs v1's systematic 0.35–1.32
range; a seasonal calibration layer is the identified next iteration.

**GR chain check (no regression):** on the holdout lead-1 vintages, corr of the
v2 GR wind prediction vs the ENTSO-E D-1 wind forecast is **0.926** (v1: 0.881;
ENTSO-E DAfc vs actual: 0.923) — comfortably above the 0.90 gate.

**Shipping.** `bin/weather_res.jl` `load_res_models()` now prefers
`bin/res_models_v2.json` with v1 as fallback; `EUPHEMIA_RES_PACK=<path>`
overrides for rollback.

**Scoreboard footnote (required).** Live weather-track rows
(`input_mode='weather'`) from **2026-07-14 until this deploys** were produced
with the v1 pack on GFS inputs and carry the −29 % GR wind volume bias (and the
analogous per-zone biases in the table above). Flag that slice on the per-lead
scoreboard; do not compare it against post-deploy weather-track rows as one
series. Production forecast rows written after this deploys must be stamped
**code_version 17+** (bumped in the parallel cv17 PR — see the standing
directive in CLAUDE.md).
