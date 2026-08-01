#!/usr/bin/env python3
"""Equivalence-harness dumper (input-upgrade → pure-Julia scorer validation).

For each pilot zone × UTC hour in [d0, d1], emit the EXACT feature vectors
(in each model's feat_cols order), the NEW post-processed model outputs, and the
committed-pack baseline outputs — so the Julia scorer/feature-port can be
validated against IDENTICAL inputs. Mirrors predict_inputs.py's build steps.

Usage: dump_eval.py 2026-07-24 2026-07-27  -> writes eval_ref.json in SP.
Keyed: zone -> "yyyymmdd-HHMM" -> {feats_solar, feats_wind, feats_load,
 new_solar, new_wind, new_load, base_solar, base_wind, base_load, se}.
"""
import os as _os, sys, json, numpy as np, pandas as pd, lightgbm as lgb
import features as F, baseline as B
SP = F.SP; ZONES = F.ZONES
d0 = pd.Timestamp(sys.argv[1]); d1 = pd.Timestamp(sys.argv[2])
hours = pd.date_range(d0, d1 + pd.Timedelta(hours=23), freq="h")
meta = json.load(open(f"{SP}/models/meta.json"))

resagg, cellmat = F.res_weather(); loadagg = F.load_weather(); cap = F.capacity_p95()


def build_zone_res(z):
    lat0, lon0 = F.zone_centroid(z)
    ra = resagg[resagg.zone == z].sort_values("h").reset_index(drop=True)
    ra = B.add_cal(ra, lat0, lon0)
    ra["clearness"] = (ra["ghi"] / np.maximum(F.S0 * ra["se"], 1.0)).clip(0, 1.3)
    ra["d"] = ra["h"].dt.floor("D")
    for pt in ["solar", "wind"]:
        s = cap.get((z, pt)); ra[f"cap95_{pt}"] = ra["d"].map(s) if s is not None else np.nan
    return ra, cellmat[z]


def build_zone_load(z):
    lat0, lon0 = F.zone_centroid(z)
    la = loadagg[loadagg.zone == z].sort_values("h").reset_index(drop=True)
    la = B.add_cal(la, lat0, lon0)
    la["Tma"] = la["T"].rolling(48, min_periods=1).mean()
    la["cdh"] = np.maximum(la["T"] - 21.0, 0); la["hdh"] = np.maximum(16.5 - la["T"], 0)
    la["cdh2"] = la["cdh"] ** 2 / 10; la["hdh2"] = la["hdh"] ** 2 / 10
    tl = pd.read_parquet(f"{SP}/tgt_load.parquet"); tl["h"] = pd.to_datetime(tl["h"])
    tl = tl[tl.zone == z][["h", "load_da"]]; la = la.merge(tl, on="h", how="left")
    lser = la.set_index("h")["load_da"]
    la["ar1"] = la["h"].map(lambda t: lser.get(t - pd.Timedelta(days=1), np.nan))
    la["ar7"] = la["h"].map(lambda t: lser.get(t - pd.Timedelta(days=7), np.nan))
    holset = F.holidays(B.LOADP["zones"][z]["holiday_country"], range(2024, 2027))
    la["is_hol"] = la["h"].dt.normalize().isin(holset).astype(int)
    return la


def jnum(x):
    return None if (x is None or (isinstance(x, float) and np.isnan(x))) else float(x)


out = {}
for z in ZONES:
    ra, cellp = build_zone_res(z); la = build_zone_load(z)
    ms = lgb.Booster(model_file=f"{SP}/models/{z}_solar.txt")
    mw = lgb.Booster(model_file=f"{SP}/models/{z}_wind.txt")
    ml = lgb.Booster(model_file=f"{SP}/models/{z}_load.txt")
    fs = meta[f"{z}_solar"]["feat_cols"]; fw = meta[f"{z}_wind"]["feat_cols"]; fl = meta[f"{z}_load"]["feat_cols"]
    rs = meta[f"{z}_solar"].get("ref_col"); rw = meta[f"{z}_wind"].get("ref_col")
    ra_h = ra[ra["h"].isin(hours)].copy(); la_h = la[la["h"].isin(hours)].copy()

    sp = ms.predict(ra_h[fs])
    if rs is not None: sp = sp * ra_h[rs].values
    sp = np.maximum(sp, 0.0); sp = np.where(ra_h["se"].values <= 1e-6, 0.0, sp)
    wp = mw.predict(ra_h[fw])
    if rw is not None: wp = wp * ra_h[rw].values
    wp = np.maximum(wp, 0.0)
    lp = np.maximum(ml.predict(la_h[fl]), 0.0)

    cp = cellp.reindex(ra["h"].values); cp.index = ra.index
    bsolar = B.baseline_solar(z, ra).reindex(ra_h.index).values
    bwind = np.maximum(B.baseline_wind(z, cp).reindex(ra_h.index).values, 0.0)
    bload = B.baseline_load(z, la).reindex(la_h.index).values

    zo = {}
    la_idx = {pd.Timestamp(h): i for i, h in enumerate(la_h["h"].values)}
    for i in range(len(ra_h)):
        h = pd.Timestamp(ra_h["h"].values[i]); key = h.strftime("%Y%m%d-%H%M")
        rec = {
            "feats_solar": [jnum(ra_h[c].values[i]) for c in fs],
            "feats_wind": [jnum(ra_h[c].values[i]) for c in fw],
            "new_solar": jnum(sp[i]), "new_wind": jnum(wp[i]),
            "base_solar": jnum(bsolar[i]), "base_wind": jnum(bwind[i]),
            "se": jnum(ra_h["se"].values[i]),
        }
        if h in la_idx:
            li = la_idx[h]
            rec["feats_load"] = [jnum(la_h[c].values[li]) for c in fl]
            rec["new_load"] = jnum(lp[li]); rec["base_load"] = jnum(bload[li])
        zo[key] = rec
    out[z] = zo

json.dump(out, open(f"{SP}/eval_ref.json", "w"))
print("wrote eval_ref.json zones", list(out.keys()), "hours/zone", len(out[ZONES[0]]))
print("DUMP_DONE")
