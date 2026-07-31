#!/usr/bin/env python3
"""Emit per-day predicted inputs parquet (the pipeline-consumable artifact) for
given UTC days, for both the NEW LightGBM models and the committed baseline packs.
Usage: predict_inputs.py 2026-07-24 2026-07-28  -> writes inputs_new.parquet, inputs_base.parquet
Columns: zone, ts (naive UTC hour), load_mw, solar_mw, wind_mw"""
import sys, json, numpy as np, pandas as pd, lightgbm as lgb
import features as F, baseline as B   # reuse baseline replication + feature build
SP=F.SP; ZONES=F.ZONES
d0=pd.Timestamp(sys.argv[1]); d1=pd.Timestamp(sys.argv[2])
hours=pd.date_range(d0, d1+pd.Timedelta(hours=23), freq="h")
meta=json.load(open(f"{SP}/models/meta.json"))

resagg,cellmat=F.res_weather(); loadagg=F.load_weather(); cap=F.capacity_p95()

def build_zone_res(z):
    lat0,lon0=F.zone_centroid(z)
    ra=resagg[resagg.zone==z].sort_values("h").reset_index(drop=True)
    ra=B.add_cal(ra,lat0,lon0)
    ra["clearness"]=(ra["ghi"]/np.maximum(F.S0*ra["se"],1.0)).clip(0,1.3)
    ra["d"]=ra["h"].dt.floor("D")
    for pt in ["solar","wind"]:
        s=cap.get((z,pt)); ra[f"cap95_{pt}"]=ra["d"].map(s) if s is not None else np.nan
    return ra,cellmat[z]

def build_zone_load(z):
    lat0,lon0=F.zone_centroid(z)
    la=loadagg[loadagg.zone==z].sort_values("h").reset_index(drop=True)
    la=B.add_cal(la,lat0,lon0)
    la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    la["cdh"]=np.maximum(la["T"]-21.0,0);la["hdh"]=np.maximum(16.5-la["T"],0)
    la["cdh2"]=la["cdh"]**2/10;la["hdh2"]=la["hdh"]**2/10
    tl=pd.read_parquet(f"{SP}/tgt_load.parquet"); tl["h"]=pd.to_datetime(tl["h"])
    tl=tl[tl.zone==z][["h","load_da"]]; la=la.merge(tl,on="h",how="left")
    lser=la.set_index("h")["load_da"]
    la["ar1"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=1),np.nan))
    la["ar7"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=7),np.nan))
    holset=F.holidays(B.LOADP["zones"][z]["holiday_country"],range(2024,2027))
    la["is_hol"]=la["h"].dt.normalize().isin(holset).astype(int)
    return la

new_rows=[]; base_rows=[]
for z in ZONES:
    ra,cellp=build_zone_res(z); la=build_zone_load(z)
    # NEW predictions
    ms=lgb.Booster(model_file=f"{SP}/models/{z}_solar.txt")
    mw=lgb.Booster(model_file=f"{SP}/models/{z}_wind.txt")
    ml=lgb.Booster(model_file=f"{SP}/models/{z}_load.txt")
    fs=meta[f"{z}_solar"]["feat_cols"]; fw=meta[f"{z}_wind"]["feat_cols"]; fl=meta[f"{z}_load"]["feat_cols"]
    ra_h=ra[ra["h"].isin(hours)].copy(); la_h=la[la["h"].isin(hours)].copy()
    rs=meta[f"{z}_solar"].get("ref_col"); rw=meta[f"{z}_wind"].get("ref_col")
    sp=ms.predict(ra_h[fs])
    if rs is not None: sp=sp*ra_h[rs].values
    sp=np.maximum(sp,0.0); sp=np.where(ra_h["se"].values<=1e-6,0.0,sp)
    # SHIP CONFIG: wind uses the committed physical power-curve baseline (beats ML
    # in 3/4 zones on VALID); ML load+solar are the wins. (ML wind model still
    # exported for the scorecard/record.)
    cp_all=cellp.reindex(ra["h"].values); cp_all.index=ra.index
    wp_series=B.baseline_wind(z,cp_all).reindex(ra_h.index)
    wp=np.maximum(wp_series.values,0.0)
    lp=np.maximum(ml.predict(la_h[fl]),0.0)
    rn=ra_h[["zone","h"]].copy(); rn["solar_mw"]=sp; rn["wind_mw"]=wp
    ln=la_h[["zone","h"]].copy(); ln["load_mw"]=lp
    nm=rn.merge(ln,on=["zone","h"],how="outer")
    new_rows.append(nm)
    # BASELINE packs (same weather)
    cp=cellp.reindex(ra["h"].values); cp.index=ra.index
    ra["bsolar"]=B.baseline_solar(z,ra); ra["bwind"]=B.baseline_wind(z,cp)
    la["bload"]=B.baseline_load(z,la)
    rb=ra[ra["h"].isin(hours)][["zone","h","bsolar","bwind"]].rename(columns={"bsolar":"solar_mw","bwind":"wind_mw"})
    lb=la[la["h"].isin(hours)][["zone","h","bload"]].rename(columns={"bload":"load_mw"})
    base_rows.append(rb.merge(lb,on=["zone","h"],how="outer"))

new=pd.concat(new_rows,ignore_index=True).rename(columns={"h":"ts"})
base=pd.concat(base_rows,ignore_index=True).rename(columns={"h":"ts"})
for df in (new,base):
    df["ts"]=pd.to_datetime(df["ts"])
    for c in ["load_mw","solar_mw","wind_mw"]: df[c]=df[c].astype(float)
new.to_parquet(f"{SP}/inputs_new.parquet"); base.to_parquet(f"{SP}/inputs_base.parquet")
def to_json(df):
    out={}
    for _,r in df.iterrows():
        z=r["zone"]; key=pd.Timestamp(r["ts"]).strftime("%Y%m%d-%H%M")
        out.setdefault(z,{})[key]=[None if pd.isna(r["load_mw"]) else round(float(r["load_mw"]),2),
                                   0.0 if pd.isna(r["solar_mw"]) else round(float(r["solar_mw"]),2),
                                   0.0 if pd.isna(r["wind_mw"]) else round(float(r["wind_mw"]),2)]
    return out
json.dump(to_json(new),open(f"{SP}/inputs_new.json","w"))
json.dump(to_json(base),open(f"{SP}/inputs_base.json","w"))
print("wrote inputs_new/base", new.shape, "days", d0.date(),"..",d1.date())
print(new.groupby("zone")[["load_mw","solar_mw","wind_mw"]].mean().round(0).to_string())
print("PREDICT_DONE")
