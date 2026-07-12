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

`weather_meas.csv` / `weather_fcst.csv` (silentech DB): per-hour national
aggregates over all 1,851 cities — `avg(direct_radiation)`, `avg/p75/p90(wind_speed_10m)`,
`avg(temperature_2m)` from `weather.city_measure` / `weather.city_forecast`
(forecast table has **no radiation** — see the investigation doc).

`cells_meas.csv` / `cells_fcst.csv`: hourly `wind_speed_10m` for the top-20
distinct grid cells, selected by uploading the hourly wind-generation series to
a TEMP table in the silentech DB and ranking
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
