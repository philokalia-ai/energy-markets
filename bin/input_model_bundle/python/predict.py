#!/usr/bin/env python3
"""Euphemia input model — self-contained LightGBM predictor (inference-only).

Loads the committed LightGBM boosters in ../models and scores wind / solar / load
for the five ML pilot zones (GR, ES, DE_LU, SE2, NL). NO repo imports, NO database
— weather comes from the public open-meteo API (fetch_gfs.py) and the two ex-ante
scalars (cap95 capacity, ar1/ar7 load lags) are passed in by the caller.

Provenance is per (zone, target): each series is either an ML LightGBM winner or a
linear-pack winner on the frozen out-of-sample scorecard (see WINNERS below and
the bundle README). This module scores the LightGBM models; WINNERS records which
target the pack wins in production so you can report provenance honestly.
"""
import json
import os
import numpy as np
import pandas as pd
import lightgbm as lgb

import features as F

MODELS_DIR = os.environ.get(
    "EUPHEMIA_MODELS_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models"))

# Frozen per-(zone,target) out-of-sample winner (docs/experiments/input-upgrade
# scorecard). True = the LightGBM model in this bundle is the production winner;
# False = the linear weather pack wins (the ML model is still shipped for study).
WINNERS = {
    ("GR", "load"): True,  ("GR", "solar"): True,  ("GR", "wind"): False,
    ("ES", "load"): True,  ("ES", "solar"): False, ("ES", "wind"): True,
    ("DE_LU", "load"): True, ("DE_LU", "solar"): True, ("DE_LU", "wind"): False,
    ("SE2", "load"): True, ("SE2", "solar"): True,  ("SE2", "wind"): False,
    ("NL", "load"): True,  ("NL", "solar"): True,   ("NL", "wind"): True,
}


def load_bundle(models_dir=MODELS_DIR):
    """Return (meta, geom, boosters) — boosters keyed '<ZONE>_<target>'."""
    meta = json.load(open(os.path.join(models_dir, "meta.json")))
    geom = json.load(open(os.path.join(models_dir, "geom.json")))
    boosters = {}
    for key in meta:
        boosters[key] = lgb.Booster(model_file=os.path.join(models_dir, key + ".txt"))
    return meta, geom, boosters


# ---- zone-hour weather aggregation (matches features.py res/load_weather) ----
def res_zone_hours(weather_long):
    """Zone-hour mean over cells (per-variable NaN handling): ghi, cloud, pres,
    v100m. `weather_long` is fetch_gfs.fetch(..., RES_VARS) output."""
    df = weather_long
    agg = df.groupby("h").agg(
        ghi=("shortwave_radiation", "mean"),
        cloud=("cloud_cover", "mean"),
        pres=("surface_pressure", "mean"),
        v100m=("wind_speed_100m", "mean"),
    ).reset_index()
    return agg


def load_zone_hours(weather_long, weights):
    """Population-weighted zone-hour (T, ghi). `weights[loc]` is a city weight;
    `weather_long` is fetch_gfs.fetch(..., LOAD_VARS) output over the city points."""
    df = weather_long.copy()
    df["w"] = df["loc"].map(weights)
    out = None
    for col, name in [("temperature_2m", "T"), ("shortwave_radiation", "ghi")]:
        pres = df[col].notna()
        wv = df["w"].where(pres, 0.0) * df[col].fillna(0.0)
        ww = df["w"].where(pres, 0.0)
        g = pd.DataFrame({"h": df["h"], "wv": wv, "ww": ww}).groupby("h").sum()
        s = (g["wv"] / g["ww"].replace(0, np.nan)).rename(name)
        out = s.to_frame() if out is None else out.join(s)
    return out.reset_index()


# ---- predictions (post-processing mirrors predict_inputs.py / ml_inputs.jl) ----
def predict_solar(zone, res_feats, meta, boosters):
    """Solar MW: ratio-model x cap95_solar, floored >=0, night-clamped (se<=1e-6)."""
    m = boosters[f"{zone}_solar"]
    x = res_feats[F.SOLAR_FEATS].values
    p = m.predict(x)
    ref = meta[f"{zone}_solar"].get("ref_col")
    if ref is not None:
        p = p * res_feats[ref].values
    p = np.maximum(p, 0.0)
    p = np.where(res_feats["se"].values <= 1e-6, 0.0, p)
    return p


def predict_wind(zone, res_feats, meta, boosters):
    """Wind MW: ratio-model x cap95_wind, floored >=0."""
    m = boosters[f"{zone}_wind"]
    x = res_feats[F.WIND_FEATS].values
    p = m.predict(x)
    ref = meta[f"{zone}_wind"].get("ref_col")
    if ref is not None:
        p = p * res_feats[ref].values
    return np.maximum(p, 0.0)


def predict_load(zone, load_feats, meta, boosters):
    """Load MW: model output floored >=0."""
    m = boosters[f"{zone}_load"]
    x = load_feats[F.LOAD_FEATS].values
    return np.maximum(m.predict(x), 0.0)
