# Euphemia input model — open RES & load predictor (v1.0.0)

> **This bundle is the 5-zone pilot** (GR, ES, DE_LU, SE2, NL), frozen at v1.0.0.
> The live system has since been rolled out to the **whole 39-zone footprint** with
> per-(zone,target) winner selection and has been retrained; the numbers below are
> the pilot's, not today's. The current recipe, the live winner map and the
> full-footprint data plane are in
> [`docs/predictions.md`](https://github.com/philokalia-ai/energy-markets/blob/main/docs/predictions.md).

A **standalone** package of the fitted RES/load input model behind the Euphemia
day-ahead counterfactual: per delivery hour and bidding zone, the **wind, solar and
load** the market clears on — strictly **ex-ante** (D-1 weather only) — from free,
public weather data. Usable with **no Euphemia, no Julia, no Postgres**:

- **(a) Load our predictions as data** — `outputs/<ZONE>.parquet` are the model's
  own per-zone-hour predictions (plus the ENTSO-E reference and settled actuals)
  for a recent window.
- **(b) Run the model yourself for new days** — `python/` is a minimal,
  self-contained LightGBM predictor; `examples/predict_gr_tomorrow.py` forecasts
  tomorrow from the public open-meteo API in ~20 lines.

Provenance and licence match the source repo (`philokalia-ai/energy-markets`, EUPL
v1.2).

## What it predicts, and against what

The targets are the **ENTSO-E day-ahead forecasts the auction actually clears on**
— load, solar and wind — **not** the settled outturn, and the weather is always a
GFS vintage admissible at the 12:00 CET gate (the current run for a future day,
the `previous_day1` run to reconstruct settled history). Why, and the exact
tables, columns and vintage rules:
[`docs/predictions.md`](https://github.com/philokalia-ai/energy-markets/blob/main/docs/predictions.md)
§1–2. Each output row is labelled by `vintage_lag` (0 = current-run nowcast,
1 = the D-1 previous-run vintage).

**Two ex-ante scalars must be supplied by the caller** (both known before the gate):

- `cap95` (RES) — the trailing-30-day 95th-percentile of ENTSO-E **actual**
  per-type generation, window **ending D-2** (actual generation publishes with
  ~1–2 d lag). Solar/wind predict a **ratio** against it, so a growing fleet does
  not drift the forecast; slow-moving, and the example ships recent GR values.
- `ar1`/`ar7` (load) — the ENTSO-E **D-1 and D-7 same-hour day-ahead load
  forecasts** (both published before the gate).

## Per-zone winner scorecard (frozen, out-of-sample 2026-05-01…2026-07-22)

Provenance is per target: each (zone, target) ships whichever of {this LightGBM
model, the committed linear weather pack} won this frozen OOS window. The bundle
contains the **15 LightGBM boosters** (5 zones × 3 targets) and records which was
the production winner *at v1.0.0*; where the pack won, the ML model is still
shipped for study.

| zone | load | solar | wind | notes |
|------|:----:|:-----:|:----:|-------|
| **GR** | **ML** | **ML** | pack | ML solar drives GR midday collapse detection |
| **ES** | **ML** | pack | **ML** | ES solar pack ridge already near-perfect |
| **DE_LU** | **ML** | **ML** | pack | |
| **SE2** | **ML** | **ML** | pack | |
| **NL** | **ML** | pack \* | **ML** | ML wind wins offshore-heavy NL (MAE 303 vs 750) |

\* **NL solar shipped as the ML winner in v1.0.0.** It was demoted afterwards by
the correlation guard (ML corr 0.707 vs pack 0.933 below — a lower MAE bought by
flattening the shape), and the shipped `models/meta.json` now records
`winners["NL_solar"] = false`. The booster is still in the bundle; the production
system uses the pack.

OOS MAE (MW) / Pearson corr, LightGBM ("new") vs the linear pack ("base"):

| zone | target | MAE new | MAE base | corr new | corr base | winner |
|------|--------|--------:|---------:|---------:|----------:|:------:|
| GR | load | 138 | 206 | 0.991 | 0.980 | **ML** |
| GR | solar | 366 | 748 | 0.987 | 0.980 | **ML** |
| GR | wind | 390 | 270 | 0.831 | 0.926 | pack |
| ES | load | 476 | 887 | 0.990 | 0.979 | **ML** |
| ES | solar | 1186 | 936 | 0.987 | 0.989 | pack |
| ES | wind | 1030 | 1033 | 0.862 | 0.864 | **ML** |
| DE_LU | load | 1181 | 1760 | 0.975 | 0.962 | **ML** |
| DE_LU | solar | 1304 | 1618 | 0.991 | 0.987 | **ML** |
| DE_LU | wind | 2299 | 1931 | 0.936 | 0.944 | pack |
| SE2 | load | 26 | 118 | 0.957 | 0.849 | **ML** |
| SE2 | solar | 4 | 4 | 0.969 | 0.959 | **ML** |
| SE2 | wind | 576 | 470 | 0.790 | 0.866 | pack |
| NL | load | 626 | 3324 | 0.858 | 0.193 | **ML** |
| NL | solar | 1145 | 1292 | 0.707 | 0.933 | **ML** at v1.0.0, since demoted |
| NL | wind | 303 | 750 | 0.929 | 0.877 | **ML** |

> The other 34 footprint zones used the linear weather packs at v1.0.0 and are not
> in this bundle. They now have their own LightGBM winners in the source repo —
> see `docs/predictions.md`.

## Contents

```
euphemia-input-model-v1/
├── models/         15 LightGBM text dumps (<ZONE>_<solar|wind|load>.txt)
│                   + meta.json (feature order, ratio column, night-clamp flag)
│                   + geom.json (per-zone RES cells + pop-weighted load cities)
├── python/         minimal self-contained predictor (NO repo imports):
│                     fetch_gfs.py     public open-meteo fetch (2 vintage modes)
│                     features.py      ex-ante feature engineering (inference-only)
│                     predict.py       LightGBM scoring + post-processing
│                     requirements.txt pinned lightgbm / pandas / numpy / pyarrow / requests
├── examples/
│   └── predict_gr_tomorrow.py   forecast GR tomorrow from public open-meteo (~20 lines)
├── outputs/        per-zone predictions parquet for a recent window (see schema below)
├── README.md       this file
└── CHECKSUMS       sha256 of every shipped file
```

> **Rebuilding v1.0.0 from current HEAD does not work.** `bin/build_input_model_bundle.sh`
> copies all 15 `<ZONE>_<target>.txt` dumps out of `bin/input_models/`, but since
> the 39-zone rollout that directory holds **winners only** — the six pilot targets
> the pack won (GR wind, ES solar/wind, DE_LU wind, SE2 wind, NL solar) no longer
> have a committed dump, so the copy step fails. Take those boosters from the
> v1.0.0 release, or point the builder at the winners it can still ship.

### `outputs/<ZONE>.parquet` schema

One row per (zone, UTC delivery hour): `zone`, `date_time_utc`, `vintage_lag`
(0/1); the drivers `temp_c`, `ghi_wm2`, `cloud_pct`, `pressure_hpa`, `wind100_ms`;
the per-zone-winner predictions `pred_solar_mw`, `pred_wind_mw`, `pred_res_mw`,
`pred_load_mw`; the per-target provenance `src_solar`/`src_wind`/`src_load`
(`ml`|`pack`); the ENTSO-E day-ahead reference `ref_*_mw` (null where unpublished);
and the settled actual `act_*_mw` (null until settled). `manifest.json` carries the
window, column dictionary and the per-zone midday RES-coverage summary.

## Quick start

```bash
cd euphemia-input-model-v1
python3 -m venv .venv && . .venv/bin/activate
pip install -r python/requirements.txt
python examples/predict_gr_tomorrow.py      # GR wind & solar for tomorrow, from public GFS
```

Load the shipped predictions as data:

```python
import pandas as pd
gr = pd.read_parquet("outputs/GR.parquet")
print(gr[["date_time_utc", "pred_solar_mw", "pred_load_mw", "ref_solar_mw"]].head())
```

Score a new day yourself (solar/wind need only weather + `cap95`; load also needs
`ar1`/`ar7`):

```python
import sys; sys.path.insert(0, "python")
import fetch_gfs as G, features as F, predict as P
meta, geom, boosters = P.load_bundle()
lat0, lon0 = F.zone_centroid(geom, "GR")
cells = [(c[0], c[1]) for c in geom["GR"]["cells"]]
wx = G.fetch(cells, G.RES_VARS, vintage_lag=0, forecast_days=2)  # tomorrow, current run
feats = F.build_res_features(P.res_zone_hours(wx), lat0, lon0,
                             cap95_solar=7319.9, cap95_wind=2900.9)
feats["solar_mw"] = P.predict_solar("GR", feats, meta, boosters)
feats["wind_mw"]  = P.predict_wind("GR", feats, meta, boosters)
```

## Equivalence

The `python/` predictor is **bit-identical** to the production Julia scorer
(`bin/ml_inputs.jl`) that generated `outputs/`: scoring the four ML-solar pilot
zones from the parquet's own drivers reproduces `pred_solar_mw` with **max |Δ| = 0**
over 192 hours each. (The Julia scorer is in turn validated bit-for-bit against
python LightGBM at train time — see `docs/predictions.md` §6.)

## Licence & citation

Licensed under the **EUPL v1.2**, matching the source repository. If you use this
model, please cite:

- The open recipe: `docs/predictions.md` in `philokalia-ai/energy-markets`.
- The repository: <https://github.com/philokalia-ai/energy-markets>.
