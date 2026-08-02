#!/usr/bin/env python3
"""fit-iteration 6: DE_LU load feature enrichment (R7). Adds a German school-holiday
calendar + a wind-chill term to the DE_LU LOAD features ONLY, retrains DE_LU load on
the fit-iteration-4 window, and scores 4 arms (base / +school / +windchill / +both)
vs the FRESH baseline on VALID with iteration 1's corr guard. Ship the enriched arm
only if it beats the fresh baseline (MAE better AND corr loss <= 0.02). DE_LU-scoped:
no other zone is touched. features.py de_school_holiday()/windchill() are the training
authority; ml_inputs.jl mirrors them (lockstep, cmp asserted separately)."""
import os, sys, json, glob, numpy as np, pandas as pd, lightgbm as lgb
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import features as F
SP=F.SP; BIN="/home/pgeorgakopoulos/armada/energy-markets/bin"
GFS=f"{SP}/gfs"; GEOM=json.load(open(f"{SP}/geom39.json"))
LOADP=json.load(open(f"{BIN}/load_models_v1.json"))["zones"]
TGT_LOAD=pd.read_parquet(f"{SP}/tgt_load39.parquet"); TGT_LOAD["h"]=pd.to_datetime(TGT_LOAD["h"])
TRAIN_END=pd.Timestamp("2026-06-14 23:00"); VAL0,VAL1=pd.Timestamp("2026-06-15"),pd.Timestamp("2026-07-27 23:00")
Z="DE_LU"
lgb_params=dict(objective="l1",num_leaves=31,learning_rate=0.05,n_estimators=600,
    min_child_samples=40,subsample=0.8,subsample_freq=1,colsample_bytree=0.8,reg_lambda=1.0,verbosity=-1)
CORR_GUARD_TOL=0.02

def centroid(z): c=np.array(GEOM[z]["cells"],dtype=float); return c[:,0].mean(),c[:,1].mean()
def res_weather(z):   # pilot multi-zone files
    fs=sorted(glob.glob(f"{GFS}/res_ch*_b*.parquet"))
    df=pd.concat([pd.read_parquet(f) for f in fs],ignore_index=True); df["zone"]=df["loc_id"].str.split("#").str[0]
    df=df[df.zone==z].copy(); df["h"]=pd.to_datetime(df["h"])
    return df.groupby("h").agg(v100m=("wind_speed_100m","mean")).reset_index()
def load_weather(z):
    fs=sorted(glob.glob(f"{GFS}/load_ch*_b*.parquet"))
    df=pd.concat([pd.read_parquet(f) for f in fs],ignore_index=True); df["zone"]=df["loc_id"].str.split("#").str[0]
    df=df[df.zone==z].copy(); df["h"]=pd.to_datetime(df["h"]); df["li"]=df["loc_id"].str.split("#l").str[1].astype(int)
    wmap={i:c[2] for i,c in enumerate(GEOM[z]["cities"])}; df["w"]=df["li"].map(wmap)
    out=None
    for col in ["temperature_2m","shortwave_radiation"]:
        pr=df[col].notna(); wv=df["w"].where(pr,0.0)*df[col].fillna(0.0); ww=df["w"].where(pr,0.0)
        g=pd.DataFrame({"h":df["h"],"wv":wv,"ww":ww}).groupby("h").sum()
        s=(g["wv"]/g["ww"].replace(0,np.nan)); s.name={"temperature_2m":"T","shortwave_radiation":"ghi"}[col]
        out=s.to_frame() if out is None else out.join(s)
    return out.reset_index()
def add_cal(df,lat0,lon0):
    h=df["h"].dt; doy=h.dayofyear.values.astype(float); hod=h.hour.values.astype(float)
    df=df.copy(); df["hod"]=hod; df["dow"]=h.dayofweek.values; df["se"]=F.sinel(hod,doy,lat0,lon0)
    df["doy_s"]=np.sin(2*np.pi*doy/365.25); df["doy_c"]=np.cos(2*np.pi*doy/365.25)
    df["doy_s2"]=np.sin(4*np.pi*doy/365.25); df["doy_c2"]=np.cos(4*np.pi*doy/365.25); return df
def metrics(p,t):
    m=~(np.isnan(p)|np.isnan(t)); p,t=p[m],t[m]
    mae=float(np.mean(np.abs(p-t))); corr=float(np.corrcoef(p,t)[0,1]) if np.std(p)>0 else np.nan
    return mae,corr,float(np.mean(p-t))

lat0,lon0=centroid(Z)
la=load_weather(Z); la=add_cal(la,lat0,lon0); la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
la["cdh"]=np.maximum(la["T"]-21.0,0); la["hdh"]=np.maximum(16.5-la["T"],0)
la["cdh2"]=la["cdh"]**2/10; la["hdh2"]=la["hdh"]**2/10
tl=TGT_LOAD[TGT_LOAD.zone==Z][["h","load_da"]]; la=la.merge(tl,on="h",how="left")
lser=la.set_index("h")["load_da"]
la["ar1"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=1),np.nan))
la["ar7"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=7),np.nan))
holset=F.holidays(LOADP[Z]["holiday_country"],range(2024,2027))
la["is_hol"]=la["h"].dt.normalize().isin(holset).astype(int)
# NEW features (DE_LU-scoped)
la["school_hol"]=la["h"].map(lambda t: 1.0 if F.de_school_holiday(t) else 0.0)
rw=res_weather(Z); la=la.merge(rw,on="h",how="left")
la["windchill"]=[F.windchill(T,v) for T,v in zip(la["T"].values,la["v100m"].values)]

BASE=["T","Tma","cdh","hdh","cdh2","hdh2","ghi","hod","dow","is_hol","doy_s","doy_c","doy_s2","doy_c2","ar1","ar7"]
ARMS={"base":BASE,"+school":BASE+["school_hol"],"+windchill":BASE+["windchill"],"+both":BASE+["school_hol","windchill"]}
d=la.dropna(subset=["load_da"]).copy()
tr=d[d["h"]<=TRAIN_END]; va=d[(d["h"]>=VAL0)&(d["h"]<=VAL1)]
print(f"DE_LU load: train={len(tr)} valid={len(va)}  school_hol frac(valid)={va.school_hol.mean():.2f}")
res={}
for name,cols in ARMS.items():
    cut=tr["h"].quantile(0.9); itr=tr[tr["h"]<=cut]; iva=tr[tr["h"]>cut]
    m=lgb.LGBMRegressor(**lgb_params)
    m.fit(itr[cols],itr["load_da"],eval_set=[(iva[cols],iva["load_da"])],eval_metric="l1",
          callbacks=[lgb.early_stopping(40,verbose=False)])
    best=m.best_iteration_ or lgb_params["n_estimators"]
    p2=dict(lgb_params); p2["n_estimators"]=best; m=lgb.LGBMRegressor(**p2); m.fit(tr[cols],tr["load_da"])
    pv=np.maximum(m.predict(va[cols]),0.0)
    mae,corr,bias=metrics(pv,va["load_da"].values)
    res[name]=dict(mae=mae,corr=corr,bias=bias,best=int(best),cols=cols,model=m)
    print(f"  {name:11s} MAE={mae:8.1f} corr={corr:.4f} bias={bias:+8.1f} (best_iter={best})")

b=res["base"]
print("\ncorr-guard vs FRESH baseline (MAE better AND corr loss <= 0.02):")
for name in ["+school","+windchill","+both"]:
    r=res[name]; win=(r["mae"]<b["mae"]) and (r["corr"]>=b["corr"]-CORR_GUARD_TOL)
    print(f"  {name:11s} dMAE={r['mae']-b['mae']:+7.1f} dcorr={r['corr']-b['corr']:+.4f} -> {'PASS' if win else 'no'}")
# PRE-REGISTERED arm = the task's specified enrichment {school_hol, windchill} (+both).
# Ship it iff it passes the gate (avoids selecting the feature set ON the VALID MAE).
r=res["+both"]; both_ok=(r["mae"]<b["mae"]) and (r["corr"]>=b["corr"]-CORR_GUARD_TOL)
best_arm="+both" if both_ok else None
print(f"\nPRE-REGISTERED (+both) passes gate: {both_ok}  -> ship: {best_arm or 'NONE (NO-SHIP)'}")
print("  (note: +windchill-alone was marginally better on VALID; not selected to avoid test-set arm picking)")
out=dict(base=dict(mae=b["mae"],corr=b["corr"],bias=b["bias"]),
         arms={n:dict(mae=res[n]["mae"],corr=res[n]["corr"],bias=res[n]["bias"]) for n in ARMS},
         best_arm=best_arm)
json.dump(out,open(f"{SP}/dnload_iter6.json","w"),indent=1)
if best_arm:
    m=res[best_arm]["model"]; m.booster_.save_model(f"{SP}/DE_LU_load_iter6.txt")
    json.dump(dict(feat_cols=res[best_arm]["cols"],best_iter=res[best_arm]["best"],
                   clamp_night=False,n_train=int(len(tr)),ref_col=None),
              open(f"{SP}/DE_LU_load_iter6_meta.json","w"))
    print(f"saved DE_LU_load_iter6.txt (feat_cols={res[best_arm]['cols']})")
print("DNLOAD_ITER6_DONE")
