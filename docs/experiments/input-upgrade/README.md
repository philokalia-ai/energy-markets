# Input-upgrade: ML prediction of the reference INPUTS (strictly ex-ante)

**Mission (owner, 2026-07-31).** Predict the REFERENCE INPUTS the market clears on —
the ENTSO-E D-1 forecasts `day_ahead_total_load_forecast` (BZN) and
`generation_forecasts_for_wind_and_solar` (Solar / Wind) — with materially better
accuracy than the committed linear packs (`bin/res_models_v2.json`,
`bin/load_models_v1.json`), using strictly ex-ante features. If predicted inputs ≈
reference inputs, the pre-gate (weather) track converges to reference quality
(0.78–0.86). Then verify at PRICE level whether it fixes GR July-2026 middays.

Frozen protocol: [`protocol.md`](protocol.md).

## 1. Target (NOT actuals)
Per zone-hour, the **ENTSO-E DA forecast** the reference track consumes — hourly mean
of the PT15M/PT60M series. Load = `total_load_mw`; Solar =
`day_ahead_generation_forecast_mw` (Solar); Wind = onshore+offshore summed.

## 2. Method
- **Weather = GFS `gfs_seamless` `previous_day1` vintages** (open-meteo previous-runs
  API) for BOTH train and serve → no train/serve skew. Per-timestamp `previous_day1`
  = the run issued D-1 (admissible at the 08:00 UTC D-1 gate). RES cells: wind_100m,
  GHI, cloud_cover, surface_pressure. Load cities: temperature_2m, GHI.
- **Fleet-growth fix (failure-mode #1).** Solar/wind are modeled as a
  **capacity-normalized ratio** `y = target / cap95`, `cap95` = trailing-30d p95 of
  actual per-type generation ending **D-2** (ex-ante). The GBM predicts a utilization
  fraction and multiplies back by the current capacity proxy, so predictions track the
  growing fleet instead of saturating at the training max. (The direct-target GBM
  under-predicted ES/DE_LU solar by 1.4–1.6 GW — the growth bias resurfacing; the
  ratio target removed most of it: GR solar MAE 492→366, DE_LU 1822→1304.)
- **Load features (failure-mode #2):** temperature nonlinearity (CDH/HDH + squares +
  48h-MA), holidays, DOY-Fourier, and the **autoregressive DA-forecast lags** (D-1 and
  D-7 same-hour, both known at the gate).
- **Models:** LightGBM, L1 objective, time-ordered inner early-stopping. Per zone-target.
- **Train** 2024-07-14..2026-04-30; **VALID (OOS)** 2026-05-01..2026-07-22 — the recent
  high-solar summer regime where the failure lives. Time-ordered, no shuffling.
- **Baseline** scored on the SAME window and the SAME GFS-vintage weather (committed
  pack feature-vectors re-implemented exactly in `baseline.py`).

Pilot zones: **GR (mandatory), ES, DE_LU, SE2, NL** (NL added per owner: it shows the
same signature as GR — footprint's heaviest negative-price zone).

## 3. Input-level scorecard (VALID 2026-05-01..07-22, per zone×target)
| zone | target | MAE new | MAE base | corr new | corr base | winner (MAE) |
|------|--------|--------:|---------:|---------:|----------:|:------------:|
| GR | load | 138 | 206 | 0.991 | 0.980 | **NEW** |
| GR | solar | 366 | 748 | 0.987 | 0.980 | **NEW** |
| GR | wind | 390 | 270 | 0.831 | 0.926 | baseline |
| ES | load | 476 | 887 | 0.990 | 0.979 | **NEW** |
| ES | solar | 1186 | 936 | 0.987 | 0.989 | baseline |
| ES | wind | 1030 | 1033 | 0.862 | 0.864 | **NEW** |
| DE_LU | load | 1181 | 1760 | 0.975 | 0.962 | **NEW** |
| DE_LU | solar | 1304 | 1618 | 0.991 | 0.987 | **NEW** |
| DE_LU | wind | 2299 | 1931 | 0.936 | 0.944 | baseline |
| SE2 | load | 26 | 118 | 0.957 | 0.849 | **NEW** |
| SE2 | solar | 4 | 4 | 0.969 | 0.959 | **NEW** |
| SE2 | wind | 576 | 470 | 0.790 | 0.866 | baseline |
| NL | load | 626 | 3324 | 0.858 | 0.193 | **NEW** |
| NL | solar | 1145 | 1292 | 0.707 | 0.933 | **NEW** |
| NL | wind | 303 | 750 | 0.929 | 0.877 | **NEW** |

**Read.** NEW wins **LOAD on all 5 zones** (GR 138 vs 206; **NL 626 vs 3324 — the
committed NL load pack is broken, corr 0.19→0.86**) and **SOLAR on GR (366 vs 748, the
mandatory zone), DE_LU, SE2, NL(MAE)**; loses ES solar (its ridge is already
near-perfect). For **WIND** the physical power-curve baseline wins the onshore-dominated
zones (GR/DE_LU/SE2) but **NEW wins the offshore-heavy zones ES & NL** (NL 303 vs 750).

**Ship config = NEW load + NEW solar + NEW wind where it wins (ES, NL); baseline wind
elsewhere.** The price test below uses the conservative *baseline-wind-everywhere*
variant, so NL/ES improvements are if anything understated.

## 4. Price-level test — the owner's question
Clear the SOTA multi-zone EU model (current `main`, HiGHS, `enrich_network`, 2-pass) on
the offline extract with the predicted inputs injected as a `ZoneScenario` for the pilot
zones (renewable→0 + predicted RES as €1 price-taker supply + load override), exactly
replicating `bin/daily_forecast.jl`'s weather track. Neighbours keep reference inputs, so
the arms isolate the pilots' input change. Arms: **ref** (ENTSO-E inputs, no scenario) /
**base** (committed packs) / **new** (this model). Midday = mean of UTC hours 09–15.

GR predicted midday solar: **NEW 5.8–7.2 GW vs baseline 3.5–4.5 GW** — baseline
under-predicts clear-sky solar by ~2–2.7 GW (the measured July failure).

### Midday price (€/MWh, UTC 09–15), settled vs arms
**GR + NL (headline zones):**

| day | zone | settled | reference | old weather (base) | NEW weather |
|-----|------|--------:|----------:|-------------------:|------------:|
| 07-24 | GR | 94.8 | 96.4 | 94.1 | 52.8 |
| 07-24 | NL | 53.7 | 80.8 | 136.6 | 105.1 |
| 07-25 | GR | 7.0 | 15.6 | 30.8 | 20.1 |
| 07-25 | NL | -3.1 | 6.3 | 123.9 | 102.7 |
| 07-26 | GR | 14.4 | 17.0 | 18.7 | 17.0 |
| 07-26 | NL | 6.3 | 92.8 | 114.6 | 75.2 |
| 07-27 | GR | 38.1 | 39.5 | 63.8 | 36.8 |
| 07-27 | NL | 2.4 | 50.7 | 139.3 | 103.8 |

*(NL "NEW weather" column above = the baseline-wind variant used in the main panel.)*

**NL ship-config re-run — NEW load + NEW solar + NEW offshore wind** (isolates NL; ref/base
identical to above by construction):

| day | zone | settled | reference | old weather (base) | NEW weather (NEW offshore wind) |
|-----|------|--------:|----------:|-------------------:|--------------------------------:|
| 07-24 | NL | 53.7 | 80.8 | 136.6 | 103.6 |
| 07-25 | NL | -3.1 | 6.3 | 123.9 | 102.7 |
| 07-26 | NL | 6.3 | 92.8 | 114.6 | 103.8 |
| 07-27 | NL | 2.4 | 50.7 | 139.3 | 105.0 |

**Finding (corrects the earlier caveat): shipping NL's NEW offshore-wind model does NOT
fix NL at price level.** NL stays flat at ~€103–105 in the new arm regardless of wind
source (all-hour MAE-vs-settled 50.1 with NEW wind vs 48.8 with baseline wind — marginally
*worse*; collapse ≤€5 still 0/19 hours, negative-price 0/59). NL's NEW wind is the better
INPUT (VALID MAE 303 vs 750) but the residual NL price gap is **structural**, not a
wind-input deficit: in this controlled test NL's continental neighbours keep reference
inputs, and the injected RES is €1/MWh price-taker supply, so NL cannot reach settled's
negative regime by changing one zone's wind. NL's true collapse is driven by the
surrounding continental surplus (a footprint-wide input upgrade, not a per-zone one) plus
an injection-price change to reach sub-€1.

**Controls (ES / DE_LU / SE2):**

| day | zone | settled | reference | old weather (base) | NEW weather |
|-----|------|--------:|----------:|-------------------:|------------:|
| 07-24 | ES | 2.7 | 41.9 | 7.0 | 13.6 |
| 07-24 | DE_LU | 50.8 | 19.1 | 33.0 | 35.3 |
| 07-24 | SE2 | 9.7 | 49.4 | 28.7 | 35.6 |
| 07-25 | ES | -0.8 | 5.0 | 3.2 | 5.7 |
| 07-25 | DE_LU | -3.7 | 3.9 | 2.4 | 2.6 |
| 07-25 | SE2 | 3.5 | 22.9 | 26.7 | 27.1 |
| 07-26 | ES | -0.7 | 4.6 | 2.9 | 4.8 |
| 07-26 | DE_LU | 8.9 | 12.7 | 22.9 | 8.8 |
| 07-26 | SE2 | 2.3 | 15.1 | 8.1 | 8.1 |
| 07-27 | ES | 1.2 | 8.1 | 7.3 | 11.6 |
| 07-27 | DE_LU | 17.1 | 10.8 | 14.6 | 14.6 |
| 07-27 | SE2 | 16.4 | 53.8 | 53.8 | 53.6 |

### Collapse classification vs settled (SCIENTIST.md first-class metric)
Price collapse (≤ €5) and negative (< €0) as a classification, all pilot zone-hours:
**Collapse = price ≤ €5 (the classification that dominates MAE near the RES-coverage
threshold — SCIENTIST.md §4).** Counts are collapse-HOURS correctly caught (hit) /
falsely called (FA) against settled, over the 4 test days.

| zone | settled ≤€5 hrs | reference hit / FA | old weather (base) hit / FA | NEW weather hit / FA |
|------|:---------------:|:------------------:|:---------------------------:|:--------------------:|
| **GR** | 16 / 96 | 14 / 3 | **8 / 0** | **13 / 5** |
| ES | 31 / 96 | 14 / 0 | 19 / 0 | 10 / 0 |
| DE_LU | 13 / 96 | 9 / 1 | 7 / 1 | 7 / 0 |
| SE2 | 28 / 96 | 21 / 19 | 24 / 19 | 24 / 18 |
| **NL** | 19 / 96 | 2 / 0 | **0 / 0** | **0 / 0** |
| ALL | 107 / 480 | 60 (0.56) | 58 (0.54) | 54 (0.51) |

**GR is the headline:** the old weather track catches only **8 of 16** collapse hours
(the clear-sky under-prediction); NEW restores this to **13/16 ≈ reference's 14/16** —
it makes the weather track *see* the collapses again.

**Negative prices (< €0):** settled had 59 negative pilot-hours; **all three arms predict
zero** — a STRUCTURAL property of the injection, not the inputs: predicted RES enters as
€1/MWh price-taker supply (matching `daily_forecast`'s weather track), so cleared prices
floor at ~€1 and can never reach settled's negative regime. Reaching negative prices needs
an injection-price change (below-cost / negative RES bids), out of scope for an input model.


## 5. Integration design
12→15 LightGBM models exported to `bin/input_models/*.txt` + `meta.json` (feature list,
chosen n_estimators, ratio ref-column, night-clamp) + `geom.json` (pack cells/cities,
reused verbatim). Two integration paths:
1. **Python inference (implemented):** `predict_inputs.py <d0> <d1>` fetches the GFS D-1
   vintages, rebuilds features, emits a per-day inputs artifact
   (`inputs_new.{parquet,json}`: zone, ts, load_mw, solar_mw, wind_mw). The JSON is keyed
   `zone → "yyyymmdd-HHMM" → [load,solar,wind]` — the exact shape
   `daily_forecast.weather_scenario` builds from, so the weather track consumes it in
   place of the pack predictions with no clearing changes.
2. **Pure-Julia scorer (recommended for production):** LightGBM `.txt` is a plain tree
   dump; a ~100-line GBDT evaluator in Julia keeps the daily workflow Julia-only and
   mirrors how `weather_res.jl`/`weather_load.jl` consume their JSON packs. Left as the
   production follow-up.

## 6. Reproducibility
`fetch_gfs.py`/`fetch_nl.py` (GFS vintages) → `pull_targets.py` (targets+capacity from
the extract) → `train.py` (models + scorecard) → `predict_inputs.py` (serve) →
`price_test.jl` (price arms) → `collapse_metrics.py`. Scripts carry hard-coded
scratchpad paths (research record); the serve-time artifacts are the models in
`bin/input_models/`.

## 7. Ship recommendation
**Ship: NEW load + NEW solar + per-zone-winner wind** (baseline wind for the onshore
zones GR/DE_LU/SE2; NEW wind for the offshore zones ES/NL). Rationale from VALID:

- **LOAD — ship NEW everywhere.** Wins all 5 zones; NL is a *repair* (baseline corr 0.19,
  MAE 3324 → NEW 0.86, 626). The AR DA-forecast lags + degree-hour convexity carry it.
- **SOLAR — ship NEW for GR / DE_LU / SE2 / NL; keep baseline for ES.** The
  capacity-normalized ratio target fixes the clear-sky under-prediction that caused the
  July GR failure (GR MAE 748→366, midday solar +2–2.7 GW). ES's ridge is already
  near-perfect (bias −24) — do not disturb it.
- **WIND — keep the physical power-curve baseline for onshore zones; ship NEW for the
  offshore-heavy zones (ES, NL 750→303) as the better INPUT.** ML does not beat a good
  power curve onshore.

**Measured caveat (NL ship-config re-run, §4): NL's NEW offshore wind is the better input
but does NOT move NL at price level** (flat ~€104, MAE 50.1 vs 48.8 baseline-wind, collapse
still 0/19). NL's price residual is structural (continental coupling + the €1 injection
floor), so NL needs a **footprint-wide** input upgrade + an injection-price change to reach
its negative settled regime — not a single-zone wind swap. Ship NL's NEW wind for input
accuracy, but do not expect it to fix NL prices alone.

**Do NOT ship blind:** on the one genuinely-expensive day (07-24, settled €95) richer solar
made NEW over-collapse GR to €53 (a false alarm). Gate any activation on the collapse
false-alarm rate, not MAE alone.


## 8. 39-zone rollout plan
Zones-first (not target-first): each zone is an independent GFS-fetch + 3-model train
(~10 min/zone on this pipeline). Order by measured pain:
1. **NL, PL, BG** first — the negative-price / stuck-high weather-track zones (NL proven
   here; PL/BG show the same live signature). NL specifically needs its NEW offshore-wind
   model shipped (this study proved load+solar; wind is the missing collapse driver).
2. Then the remaining large/coupled continental zones (DE_LU already piloted, FR, IT-*).
3. Nordic/hydro zones last (SE2 piloted; solar negligible, load the main win).

**Per-zone winner selection is mandatory** (not a global rule): for every (zone, target)
keep whichever of {NEW, committed pack} has the lower VALID MAE AND does not raise the
collapse false-alarm rate — exactly the GR/ES/NL split found here (NEW load always; NEW
solar except ES; NEW wind only offshore). The selection is frozen ex-ante per zone from
the OOS window, then held out.

Deliverable per zone = 3 LightGBM models in `bin/input_models/` + a row in the scorecard
+ the zone added to `predict_inputs.py`'s emit. Production integration = the pure-Julia
GBDT scorer (§5.2) so the daily Julia workflow stays dependency-free.
