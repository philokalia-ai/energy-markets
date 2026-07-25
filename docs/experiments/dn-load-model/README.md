# D-n load model: full model predictions at leads 2..7 (July 2026)

> **Productionized as the daily-forecast eligibility LOAD FILL (2026-07-25).**
> The load model is now a per-zone eligibility fallback in `bin/daily_forecast.jl`.
> Motivation (measured): the daily run requires the ENTSO-E 6.1.B D-1 load
> forecast for ALL 39 footprint zones; a run that found LT/SI/CH missing/short
> declared the day INELIGIBLE and threw away the 36 complete zones. The fill
> predicts a zone's hourly load with the committed model **only when its TSO
> forecast is missing/short**, so the day stays eligible.
>
> Shipped:
> - `bin/fit_load_models.jl` → committed pack `bin/load_models_v1.json` (39
>   footprint zones, per-zone ridge, ERA5-archive-trained; refit instructions in
>   the script header — annual/quarterly cadence).
> - `bin/weather_load.jl` — shared feature construction (207 features, identical
>   to this prototype) + open-meteo fetch + `predict_load`; unit-tested pure in
>   `test/test_weather_load.jl`.
> - `load_fill` book hook (`src/merit_order/book_build.jl` + `ZoneScenario`):
>   **merges** model load into a zone's series, filling ONLY hours the TSO did
>   not publish — a present TSO hour is never overridden.
> - `bin/daily_forecast.jl`: predicts short zones once over the candidate span,
>   exempts them in the eligibility gate (a zone the model cannot cover keeps the
>   day ineligible — no silent flat/persistence numbers), stamps filled vintages
>   `input_mode='<mode>+loadfill'` (their own scoreboard track), and honors a
>   `LOAD_FILL` kill-switch (default on).
> - Guards: `test/scripts/load_fill_book_identity.jl` (no-fill = byte-identical
>   book; no-override; seed-when-absent). Real-case validation:
>   `test/scripts/validate_load_fill.jl` (model vs actual vs TSO, out of sample).
> See the PR for the LT/SI/CH validation table and guard evidence.

> **Symmetric RES FILL (2026-07-26).** The load gate was only half the door: a
> run that passed the load gate (with the fill) then went INELIGIBLE on the RES
> gate — DE_LU on lead-1, AT on deeper leads missing their 14.1.D wind/solar
> forecast. The RES twin fills a missing zone's wind/solar from the existing
> weather→RES models (`bin/weather_res.jl` + `res_models` pack) exactly as load
> fill does: `res_fill` book hook MERGES weather RES for the hours the TSO 14.1.D
> did not publish (present TSO RES never overridden); `bin/daily_forecast.jl`
> predicts RES-missing *required* zones once over the span, exempts the fillable
> ones in the RES gate (a zone absent from the RES pack keeps the day
> ineligible), composes the provenance marker `input_mode='<mode>+loadfill+resfill'`
> (score_forecasts stays grouped correctly), and honors a `RES_FILL` kill-switch
> (default on). Inert on the weather track (which already sources all RES from
> weather — no RES gate). Same guard script covers both fills; RES validation:
> `test/scripts/validate_res_fill.jl` (model wind+solar vs 14.1.D). See the
> res-fill PR for the DE/AT numbers.

**Question.** Leads 2..7 of the forecast product are WEEKLY PERSISTENCE of our
own lead-1 forecast (`bin/horizon_forecast.jl`) because ENTSO-E publishes no
inputs beyond D-1. Can we instead run the FULL model at lead n by (a) predicting
the load ourselves (weather + calendar), (b) reusing the weather-RES models
(which already run off forecasts to +7 d), and (c) persisting the remaining
inputs (fuel, flows/ATC)? Does the lead-n model clear beat the lead-n price
persistence baseline?

**Answer: GO, staged.** The load model is ready today and even improves the
D-1 clear; leads 2..7 already beat the current persistence fill using the load
model + persisted per-type RES; the full weather-RES chain additionally needs
the wind pack refit on GFS-vintage features (solar is already fine). Numbers
below.

## 1. Prototype code

| file | what it does |
|---|---|
| `test/scripts/dn_load_fetch.py` | fetches ERA5 city temperature/GHI history + honest lead-1..7 GFS vintages (open-meteo archive / previous-runs APIs) |
| `test/scripts/dn_load_model.jl` | fits per-zone ridge load models, evaluates leads 1..7 vs persistence and the ENTSO-E D-1 forecast |
| `test/scripts/dn_price_test.jl` | GR single-zone `:merit_order` price test at leads 1..7 with only lead-n-legal inputs (offline, DuckDB extract) |

Nothing is wired into CI; CSV intermediates live in the session scratchpad
(regenerate with the fetch script + the psql extracts in the script headers).

## 2. Load model

Per-zone ridge regression (closed form, no new deps), hourly target =
`entsoe.actual_total_load` (deduped, hourly-averaged; hours < 20 % of the zone
median dropped as data glitches).

Features (207, standardized; λ picked on a validation slice, refit on full train):

- 168 local hour-of-week one-hots (EU-DST-aware local time)
- public-holiday flag + holiday × local hour-of-day one-hots (holidays computed
  from Gregorian/Orthodox computus + fixed national days per zone)
- heating/cooling degree-hours: `HDH = max(16.5 − T, 0)`, `CDH = max(T − 21, 0)`,
  their squares, and the same on a trailing 48 h mean temperature (thermal
  inertia); T = population-weighted mean over 5–9 big cities per zone
- GHI (W/m², behind-the-meter-PV suppression proxy)
- day-of-year Fourier (2 harmonics) + linear trend

Train 2022-07-01..2025-06-30 on ERA5 (actual) weather; test
2025-07-01..2026-06-30 (fully out of sample) with **honest lead-n GFS
temperature/GHI vintages** from the open-meteo previous-runs API
(`temperature_2m_previous_dayN` = the value for that hour as predicted N days
earlier).

### Results (test year, hourly)

MAE (MW), our model at leads 1..7 with honest vintage weather, vs the two
benchmarks. `perfect-T` = same model on ERA5 actual weather (upper bound);
`persist` = same-hour actual load of T−7 (T−14 for lead 7, the lead-legal
variant); `ENTSO-E D-1` = the TSO's own day-ahead forecast (lead-1 ceiling).

| zone | ENTSO-E D-1 | perfect-T | L1 | L2 | L3 | L4 | L5 | L6 | L7 | persist (L1-6) | persist (L7) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| GR | 177 | 281 | 288 | 306 | 325 | 341 | 359 | 367 | 374 | 389 | 496 |
| DE_LU | 2109 | 2134 | 2218 | 2229 | 2229 | 2217 | 2243 | 2279 | 2321 | 2811 | 3303 |
| FR | 853 | 1584 | 2125 | 2064 | 2018 | 2008 | 2050 | 2153 | 2265 | 3503 | 4311 |
| ES | 401 | 1077 | 1145 | 1137 | 1133 | 1136 | 1148 | 1180 | 1233 | 1399 | 1805 |
| PL | 413 | 820 | 878 | 881 | 880 | 886 | 898 | 908 | 941 | 997 | 1241 |
| SE3 | 282 | 346 | 333 | 336 | 346 | 371 | 399 | 426 | 462 | 629 | 829 |

MAPE / hourly corr at the extremes (full table: `load_metrics.csv` from the
script):

| zone | model L1 | model L7 | persist L1-6 | ENTSO-E D-1 |
|---|---|---|---|---|
| GR | 5.04 % / 0.960 | 6.40 % / 0.933 | 6.66 % / 0.887 | 3.14 % / 0.984 |
| DE_LU | 4.06 % / 0.955 | 4.25 % / 0.950 | 5.21 % / 0.900 | 3.96 % / 0.958 |
| FR | 4.11 % / 0.973 | 4.44 % / 0.958 | 6.73 % / 0.867 | 1.72 % / 0.994 |
| ES | 4.10 % / 0.934 | 4.43 % / 0.924 | 5.12 % / 0.885 | 1.50 % / 0.990 |
| PL | 4.82 % / 0.954 | 5.15 % / 0.945 | 5.42 % / 0.891 | 2.29 % / 0.986 |
| SE3 | 3.72 % / 0.979 | 4.91 % / 0.962 | 6.46 % / 0.920 | 2.94 % / 0.984 |

Reading:

- **The model beats weekly load persistence at every zone and every lead 1..7**
  — in MAE, MAPE and corr, usually by a wide margin (FR: 2.0–2.3 GW vs 3.5 GW).
- **Degradation with lead is gentle** (GR 288→374 MW from L1→L7; DE_LU nearly
  flat) because the calendar features carry most of the signal and forecast
  temperature stays useful to +7 d.
- **ENTSO-E's D-1 stays the lead-1 quality ceiling** (FR/ES are far better —
  TSO models have SCADA-level inputs) — with one striking exception: **DE_LU**,
  where our 9-city ridge is within 5 % of the TSO forecast MAE, and **SE3**,
  where it is statistically indistinguishable. Keep ENTSO-E load at lead 1;
  use the model only where ENTSO-E can never reach (n ≥ 2).
- Leads 2–4 sometimes beat lead 1 slightly (FR, ES): `previous_day1` is the
  GFS run initialized ~24 h before delivery-day midnight, which is *older*
  than what a real 18:30 UTC D-1 freeze would use — the real lead-1 gap to
  ENTSO-E is smaller than shown here.

## 3. Temperature source per zone — what exists TODAY vs what ceres must add

This is a key finding of the recon:

| source | coverage | vintages? | usable for |
|---|---|---|---|
| `weather.city_measure` (weather DB) | GR only, 1,851 cities, hourly, 2007→now | n/a (measurements) | GR training data, today |
| `weather.city_forecast` (weather DB) | GR only, rolling +7 d | **NO — upserted in place** (rows == distinct hours; each target hour keeps only the latest forecast) | live GR inference only |
| `weather.city_forecast_vintage` (ceres #491, merged 2026-07-12) | GR only, `run_date`-stamped, accumulating since **2026-07-08** | YES, going forward | honest GR backtests *from now on* |
| self-hosted open-meteo (`openmeteo.weather.svc`) | forecasts for arbitrary coords, **no deep history**; not reachable from this host (in-cluster) | live only | live inference, all zones |
| public open-meteo **archive** API (ERA5) | global, hourly, 1940→now−5 d | n/a (reanalysis) | training data, all zones, today |
| public open-meteo **previous-runs** API | global, `*_previous_day1..7` (GFS dense from ~2024-07; a gap around 2024-01) | YES, 1..7 d | honest lead-n backtests, all zones, today |

So: **training data for any zone is available today** (ERA5 archive; GR can also
use the in-house `city_measure`), and **honest lead-n evaluation is available
today** via previous-runs. What ceres must add for *production* (not to depend on
the public API at inference time): extend the weather ETL beyond GR — either new
non-GR city lists into the same `city_measure`/`city_forecast_vintage` tables, or
a small per-zone-city ETL; plus a one-shot ERA5 temperature backfill per non-GR
city for training. Holiday calendars are computable in-code (computus), no ETL.

## 4. Price test (GR, go/no-go)

`test/scripts/dn_price_test.jl`: 30 sample days spread every 12 days across
the OOS test year (all weekdays and seasons represented), GR single-zone
`:merit_order` cleared offline against `data/extracts/euphemia-live.duckdb`
(opened read-only). Per day T and lead n ∈ 1..7, every input is lead-n-legal:

- **load** — our ridge model driven by the lead-n GFS temperature/GHI vintage
  (`load_modifier` replaces the ENTSO-E D-1 load hour by hour)
- **RES** — the production weather-RES pack `bin/res_models_v1.json` driven by
  lead-n GFS vintages of 100 m wind + GHI at the 46 GR cells
  (`renewable_modifier` replaces the ENTSO-E RES forecast)
- **fuel** — TTF/EUA close of the last trading day ≤ T−n (cache-seeded;
  generator caches cleared between runs so SRMCs re-derive)
- **flows** — `EUPHEMIA_FLOW_ASOF_MODE=clim`: per-(border, hour) median of the
  trailing 8 same-weekday days (inputs D-7..D-56)

Benchmarks: `persist_p7` = actual DA price at T−7 same hour (legal at every
lead ≤ 7 — T−7 clears on T−8); `ref_d1` = the D-1 reference clear (ENTSO-E D-1
load + ENTSO-E RES, same clim flows) — the quality ceiling of the current
product at lead 1.

### Results

30 days × 24 h = 720 pooled hours; "daily corr" = mean of per-day correlations
(pooled corr also absorbs day-level level errors). Configs:

- `loadonly_d1` — our load model + ENTSO-E RES (isolates the load model; lead 1 only)
- `model_leadN` — our load + weather-RES pack, both at lead-N vintages, with the
  lead-legal trailing 42-day per-type RES level calibration (`DN_CALIBRATE`)
- `respers_leadN` — our load at lead N + RES persisted from the freshest
  fully-realized day (T−n−1, per-type actuals; pack-free, fully lead-legal)
- `fc_persist` — the product's CURRENT leads-2..7 fill: the lead-1 clear of
  T−7 relabeled +7 d (single-zone emulation of `bin/horizon_forecast.jl`)
- `persist_p7` — actual DA price of T−7 (a stronger baseline than fc_persist)
- `ref_d1` — production-style D-1 reference clear (quality ceiling at lead 1)

| config | pooled corr | pooled MAE | bias | daily corr | days corr>persist |
|---|---|---|---|---|---|
| **loadonly_d1** | **0.809** | **26.0** | +4.2 | **0.839** | 16/30 |
| ref_d1 | 0.566 | 30.2 | +6.4 | 0.831 | 20/30 |
| persist_p7 | 0.694 | 29.5 | +2.8 | 0.806 | — |
| fc_persist | 0.450 | 39.2 | +8.4 | 0.735 | 10/30 |
| model_lead1 | 0.398 | 40.6 | +20.4 | 0.732 | 12/30 |
| model_lead4 | 0.373 | 44.7 | +23.6 | 0.733 | 7/30 |
| model_lead7 | 0.599 | 39.1 | +11.5 | 0.641 | 7/30 |
| respers_lead1 | 0.662 | 33.1 | +11.2 | 0.707 | 10/30 |
| respers_lead4 | 0.625 | 34.3 | +9.7 | 0.709 | 11/30 |
| respers_lead7 | 0.561 | 36.0 | +8.6 | 0.653 | 6/30 |

(Full per-day tables: `price_metrics*.csv` from the script. Uncalibrated
weather-RES is ~1–5 € worse per lead with bias up to +33 — the calibration
helps but cannot fix shape.)

### The decisive diagnostic: wind, not load

Substituting ONLY the load (`loadonly_d1`) **improves** on the reference clear
(26.0 vs 30.2 MAE) — our load model costs nothing at the price level; it even
smooths ENTSO-E load-forecast noise. The full lead-n chain fails on the RES
side. Per-component check of the production RES pack driven by GFS vintages
(vs per-type actuals, test year):

| lead | wind corr | wind level (act/pred) | solar corr | solar level |
|---|---|---|---|---|
| 1 | 0.829 | **1.41** | 0.963 | 0.97 |
| 4 | 0.674 | **1.40** | 0.959 | 0.96 |
| 7 | 0.414 | **1.45** | 0.937 | 0.97 |

Solar is production-ready at every lead. **Wind is the blocker**: the committed
pack (`bin/res_models_v1.json`, fit on ERA5 100 m wind) under a GFS feed
predicts −29 % too little wind on GR — and a level calibration cannot repair
the shape (corr is scale-invariant). NOTE: this same level mismatch applies to
the LIVE ex-ante weather track, which runs this pack on live GFS forecasts —
worth an independent check on the production scoreboard.

### Go/no-go verdict — GO, staged

The comparison bar that matters for the product is `fc_persist` — the
current leads-2..7 fill — at 39.2 MAE / 0.450 pooled corr. Against it:

1. **Load model: GO now.** Beats load persistence at every zone and lead; on
   the GR price test it *improves* the D-1 clear outright (26.0 vs 30.2 MAE,
   0.839 vs 0.831 daily corr) and is buildable for any zone today.
2. **Leads 2..7 with load model + persisted per-type RES (`respers`): GO now.**
   33–37 MAE beats the current fill's 39.2 at every lead (one bad-day outlier
   at lead 5 aside), pooled corr 0.56–0.66 vs 0.45. This needs NO new weather
   infrastructure at all — actual per-type generation is already in the DB.
3. **Full weather-RES chain at leads 2..7: NOT YET — blocked by the wind pack,
   not by the concept.** With the current pack, lead-n clears (39–45 MAE) do
   not improve on the fill. The fix is known and scoped: refit the wind model
   per zone on GFS-vintage features (the `fit_res_v2.jl` recipe from
   docs/experiments/res-forecasting reached GR wind corr 0.87–0.96 with the
   multi-model ensemble) — previous-runs vintages for training exist TODAY for
   all zones. Once wind approaches the loadonly ceiling (26.0 MAE at lead 1),
   the weather chain should overtake respers, whose wind persistence decays
   fast with lead.

Note: T−7 *actual-price* persistence (29.5 MAE) remains stronger than every
lead-n config tested — the honest statement is that at leads 2..7 the model
does not yet beat actual-price persistence on GR, but it already beats the
product's own persistence fill, and the wind refit is the identified path to
parity and beyond.

## 5. Honesty notes (what is and isn't lead-n-legal here)

- **Weather vintages are honest**: previous-runs `_previous_dayN` is the value
  predicted N days ahead by the GFS run of that day — no lookahead.
- **Model FIT uses ERA5 actuals** (production would too — the fit maps weather
  to load; the vintage question only exists at inference). The **evaluation**
  uses only vintage weather.
- **Trailing 48 h temperature MA at lead n** is computed from the *same lead-n
  vintage series*, i.e. strictly older information than a real freeze would
  have (a real run knows realized temperatures up to the freeze). Our eval is
  therefore slightly pessimistic — fine.
- **Flow climatology at lead 7**: the D-7 draw in the 8-week median is the
  freeze day itself, whose flows are only ~complete at an evening freeze. The
  effect is 1/8 of one input; a production lead-7 run would use D-8..D-63.
- **GFS-only vintages**: production uses `gfs_seamless` + (pending infra sync)
  ICON/ECMWF ensemble; the RES numbers here are the single-model floor.
- **The persistence price baseline uses ACTUAL T−7 prices**, which is *stronger*
  than the product's current leads-2..7 fill (persistence of our *forecast* for
  T−7), so the reported edge understates the improvement over the product.

## 6. Production design sketch

**Where the model lives.** A committed pack `bin/load_models_v1.json`
(res_models_v1.json-style): per zone `{cities: [[lat,lon,weight]...], coef,
mu_x, sd_x, mu_y, lambda, hdh_base, cdh_base, tz_base, holiday_country,
train_window}`. Feature construction is pure Julia shared between fit and
inference (as `bin/weather_res.jl` does for RES). A `bin/weather_load.jl`
include provides `predict_load(pack, zone, hours, weather)`.

**Freeze times per lead.** One daily run right after the evening weather ETL
(~18:30 UTC, after the 17:30 UTC forecast pull): for each lead n = 2..7 predict
the Athens market day D = today + n with the freshest forecast vintage. Load
model + RES pack read the SAME open-meteo fetch (temperature/GHI added to the
`weather_res.jl` variable list). Lead 1 stays on the ENTSO-E reference track
(and the pre-auction weather track) exactly as today; the load model replaces
the ENTSO-E load gate only for n ≥ 2 where that gate can never pass.

**Vintage stamping.** Rows go to `simulations.forecast_prices` with
`prediction_made_utc = now()`, `lead_days = n`, and a new
`input_mode = 'weather_load'` (or reuse `'weather'` + a `load_source` column) so
the per-lead scoreboard (`bin/score_forecasts.jl`) separates true model
re-forecasts from the weekly-persistence fill they replace. The no-clobber rule
in `bin/horizon_forecast.jl` already guarantees a genuine model slice is never
overwritten by the persistence relabel — ship the model runs and the fill
becomes the fallback for gap days only.

**Code version (REQUIRED).** Wiring lead-n model forecasts into the product is
a model change: it MUST bump `ENERGY_PRICES_CODE_VERSION` to **17+** (which
stamps the `forecast_prices` rows it writes), with the matching code_version
history entry in CLAUDE.md. The cv16 record stays immutable, and
persisted-vs-model leads are never mixed under one version — the scoreboard
comparison of "leads 2..7 before/after" is exactly a cv16-vs-cv17 comparison.
This experiment writes NO forecast rows (prototypes under `test/scripts/`,
nothing wired into CI), so no bump happens here.

**Fuel/ATC persistence.** TTF/EUA: cache-seed with the last close ≤ freeze
(exactly what the price test does). Flows: `EUPHEMIA_FLOW_ASOF_MODE=clim` (or
:v2 with the climatology window shifted to D-(n+7)..D-(n+56) for strict
legality — a small MeritOrderBook parameter). Offered ATC (11.1) publishes
D-2+; for n ≥ 3 fall back to same-weekday-lagged ATC — needs a small
`Network.jl` as-of hook (not built here).

**Retraining cadence.** Annual (with the inference-cache refresh), or quarterly
if the trend term drifts; the pack is versioned like the RES pack
(`load_models_v2.json`, ...). Fit is closed-form ridge — minutes, no GPU.

**What ceres must add.**
1. Non-GR temperature: extend the weather ETL city set beyond GR (or add a
   per-zone big-cities list) into `city_measure` + `city_forecast_vintage`;
   one-shot ERA5 backfill per new city for training. Until then the public
   open-meteo APIs suffice (that is what this prototype runs on).
2. Nothing for holidays (computus in code).
3. Optional: ENTSO-E 6.1.C week-ahead load (min/max) as a benchmark input —
   not currently ingested.

## 7. Caveats / next steps

- ES load has near-zero-hour glitches in `actual_total_load` (filtered here);
  a production loader needs the same guard.
- DE_LU underperforms the other zones in MAPE — one national model struggles
  with the Luxembourg mix and industrial structure; per-zone feature work
  (e.g. school-holiday calendars, wind-chill) is the obvious next iteration.
- The GR-only price test answers go/no-go; the multi-zone (39-zone) lead-n
  product additionally needs the load model for ALL footprint zones and the
  ATC as-of hook above.
- Previous-runs GFS has a coverage gap around 2024-01 — irrelevant for the
  test year used here, but a longer backtest must handle missing vintages.
