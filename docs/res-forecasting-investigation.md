# Weather → RES prediction for true ex-ante forecasting — investigation (July 2026)

**Question.** ENTSO-E's D-1 RES forecasts arrive late (~16:00 UTC, DE/IT ~19:08 UTC)
and don't exist at all for lead ≥ 2 days. Can we predict wind/solar ourselves from
the `silentech.weather` data, well enough to (a) forecast earlier in the day and
(b) extend the forecast horizon to lead 2–7?

Study: GR, 2025-07-01 → 2026-06-30 hourly. Train Jul–Mar, test **out-of-sample
Apr–Jun 2026**. Benchmark = the ENTSO-E DA forecast's own accuracy vs actual RES.

## 1. What the weather data can and cannot do today

| Fact | Consequence |
|---|---|
| `city_forecast` horizon reaches **+6–7 days** (GFS via self-hosted open-meteo) | lead 2–7 price forecasts become *possible* — ENTSO-E inputs cannot support them at all |
| `direct_radiation` is **100% NULL in `city_forecast`** (never populated, 2024→2026) — requested by the ETL but not served by the self-hosted GFS sync | **no live solar prediction today**; fix is on the open-meteo deployment (sync `shortwave_radiation`/`direct_radiation` for `ncep_gfs013`) |
| Wind is **10 m only** (`wind_u/v_component_10m` synced); GFS has 100 m | hub-height signal lost; cheap fix |
| `cloud_cover_{low,mid,high}` **is synced** by open-meteo but the ETL's `HOURLY_VARS` drops it | free extra solar feature if stored |
| ETL upserts `city_forecast` with `past_days=5` → past hours are **overwritten by post-delivery runs** | stored "forecasts" for past timestamps are near-analysis: **honest lead-N backtesting is impossible**; live use is fine, backtests are slightly optimistic |
| Catalogue is **GR-only** (1,851 cities → effectively ~a few hundred distinct grid cells) | EU zones need new catalogue rows; same instance serves any EU point |
| Cities are population points, not wind-farm sites | national averages dilute wind signal badly (see §3) |

## 2. Solar — essentially solved with a 3-term linear model

Inputs: national-avg ERA5 `direct_radiation` (stand-in for the missing forecast
radiation) + sun-elevation geometry (`sinel`, computed, free). OOS Apr–Jun 2026:

| model | corr | MAE (MW) |
|---|---|---|
| ENTSO-E DA solar forecast (benchmark) | 0.948 | 715 |
| 24h persistence | 0.926 | 383 |
| S1: radiation only | 0.887 | 683 |
| **S2: radiation + sun elevation** | **0.919** | **541** |
| S2 target = ENTSO-E DA forecast itself | 0.970 | 803* |

*MAE inflated by trend extrapolation; calibration, not shape.
Benchmark MAE 715 includes the known curtailment gap (actual < forecast).

Solar output is geometry × weather; the physics that matters (sunrise/sunset,
seasonal arc) is captured by one computed feature. **No physical simulation
needed.**

## 3. Wind — the gap is spatial data, not model physics

National-average 10 m wind: corr 0.57. The catalogue clusters into identical
open-meteo grid cells; ranking cells by correlation with actual GR wind output
and using the top 20 distinct cells (per-site power-curve + raw-speed features,
OLS weights):

| model | corr | MAE (MW) |
|---|---|---|
| ENTSO-E DA wind forecast (benchmark) | 0.911 | 256 |
| 24h persistence | 0.503 | 658 |
| national avg wind, cubic (W3) | 0.596 | 554 |
| **20 best cells, ERA5 inputs** | **0.779** | **429** |
| **20 best cells, true forecast inputs** | **0.746** | **458** |
| same, target = ENTSO-E DA forecast | 0.851 | 371 |

Key facts:
- Weather-forecast error costs little (0.779 → 0.746); the forecast wind tracks
  ERA5 at corr 0.924. **The bottleneck is where we sample and 10 m height, not
  forecast quality and not the model.**
- Remaining gap to 0.91: hub-height wind (100 m), real wind-farm coordinates
  instead of correlation-picked cities, per-region aggregation. The TSO knows
  farm locations + installed MW per site; we approximate.

## 4. Price-level test (the question that matters)

12 OOS days, Apr–Jun 2026, GR `:merit_order`, identical pipeline; only the RES
input differs (ENTSO-E DA forecast vs our weather-RES via `renewable_modifier`).

| RES input | price corr vs DAM | price MAE (€/MWh) |
|---|---|---|
| ENTSO-E DA forecasts (production) | **0.850** | **24.6** |
| weather-RES (S2 solar + 20-cell wind) | 0.686 | 36.5 |

(pooled over 288 h; baseline matches the production GR record 0.86/€20.8 —
sanity check). Per-day: weather-RES loses on 11 of 12 days, worst on
high-wind-error days (2026-06-26: 0.90→0.63). **Wind error is the driver**
(458 MW MAE vs ENTSO-E's 256; solar contributes little of the gap).

**Conclusion: at lead 1, keep ENTSO-E RES forecasts — do not substitute.**
The weather path is worth ~0.69 corr *today*, which is the current price of
(a) forecasting hours before ENTSO-E publishes and (b) any lead ≥ 2 forecast
at all. The §6 data fixes (100 m wind, farm-sited points, forecast radiation)
are what would close the gap.

## 5. Do we need physical modelling (Dyad)?

**No — and the evidence is direct.**
- Solar: the only physics with signal is solar geometry — one closed-form
  feature (sun elevation) recovers it; corr 0.92 with a 3-term linear model vs
  ENTSO-E 0.95. Cloud-cover/clear-sky decomposition might add a point or two;
  a plant-level simulation cannot, because the residual is capacity-registry
  and curtailment noise, not optics.
- Wind: the model already embeds the physical power curve (cut-in/rated/cut-out
  on hub-corrected speed); the deficit is **input resolution** (10 m vs 100 m,
  site placement), which no simulation tool fixes — it needs better data, which
  open-meteo already has and we simply don't sync.
- Verdict: keep the light-physics features (sun geometry, power curve). Revisit
  physical modelling only if, after the data fixes in §6, wind still lags — and
  then the next step is per-farm power curves, not Dyad.

## 6. What we need from ceres / infra (concrete, ordered by value)

1. **Serve radiation on the forecast endpoint** (`pankgeorg/infra` →
   `manifests/weather`, open-meteo forecast sync): add `shortwave_radiation`
   (and ideally `diffuse_radiation`) to `OPEN_METEO_VARIABLES` for
   `ncep_gfs013`; verify `/v1/forecast` returns non-null `direct_radiation`.
   Without this there is **no live solar input**.
2. **Add 100 m wind**: sync `wind_u/v_component_100m`, add `wind_speed_100m`
   to the ETL `HOURLY_VARS` + a DB column.
3. **Store cloud cover**: already synced; add `cloud_cover` to `HOURLY_VARS`.
4. **Archive forecast vintages**: new table
   `weather.city_forecast_vintage(city_id, issue_ts, measure_ts, …)` appended
   per run (or at minimum: stop overwriting past hours). Needed for honest
   lead-N backtests and for measuring our real edge vs the market.
5. **EU site catalogue**: extend `weather.city` beyond GR — per zone, ~20–50
   points seeded at wind/solar capacity locations (or a coarse grid +
   correlation selection like §3). Volume comparable to today's GR set.
6. **Evening ETL run**: weather ETL runs 03:00; add a ~18:00 UTC run so the
   20:00 UTC forecast job sees the GFS 12z run.

## 7. Bottom line

- **Do not substitute at lead 1**: ENTSO-E RES stays the input (price corr
  0.850 vs 0.686). The measured degradation IS the honest price of earliness.
- **Solar**: model-ready (corr 0.92, 3-term linear); blocked only on radiation
  flowing in the forecast table (ceres #1).
- **Wind**: corr 0.75 today; the fix list is data plumbing, not modelling.
  With 100 m wind + farm-sited points, 0.85+ is plausible (predicting
  ENTSO-E's own forecast already reaches 0.85 with 10 m city data).
- **The prize** is (a) forecasting **hours earlier** in the afternoon and
  (b) **lead 2–7**, where no ENTSO-E input exists — a degraded-but-real
  forecast against zero. For lead ≥ 2 a load model is also required
  (temperature + calendar — same infra, likely easier than wind).
