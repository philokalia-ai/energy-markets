#!/usr/bin/env python3
"""rollout-39 equivalence dumper. For a spot set of zones (pilots + new), read the
COMMITTED models/meta/geom from bin/input_models and emit eval_ref.json: per
zone-hour the feature vectors (in each committed model's feat_cols order), the NEW
post-processed outputs, and pack baselines — for the Julia scorer/port to match.
Only committed (winner) targets are dumped per zone. Usage: dump_eval39.py d0 d1"""
import os, sys, json, glob, numpy as np, pandas as pd, lightgbm as lgb
sys.path.insert(0, "/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a534d70e414d18b80/docs/experiments/input-upgrade")
import features as F
SP=F.SP; GFS=f"{SP}/gfs"
WT="/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a534d70e414d18b80"
BIN=f"{WT}/bin"                 # packs (res/load models) — read from the worktree
MODELS=f"{BIN}/input_models"    # the COMMITTED rollout models (worktree)
RESP=json.load(open(f"{BIN}/res_models_v2.json"))["zones"]
LOADP=json.load(open(f"{BIN}/load_models_v1.json"))["zones"]
meta=json.load(open(f"{MODELS}/meta.json")); geom=json.load(open(f"{MODELS}/geom.json"))
d0=pd.Timestamp(sys.argv[1]); d1=pd.Timestamp(sys.argv[2])
hours=pd.date_range(d0,d1+pd.Timedelta(hours=23),freq="h")
ZONES=[z for z in os.environ.get("EVAL_ZONES","GR,PL,FR,NO2,ES").split(",") if z in geom]

PILOT_MULTI={"GR","ES","DE_LU","SE2"}
def res_files(z):
    if z in PILOT_MULTI: return sorted(glob.glob(f"{GFS}/res_ch*_b*.parquet"))
    if z=="NL": return sorted(glob.glob(f"{GFS}/res_nl_ch*.parquet"))
    return sorted(glob.glob(f"{GFS}/res_{z}_ch*.parquet"))
def load_files(z):
    if z in PILOT_MULTI: return sorted(glob.glob(f"{GFS}/load_ch*_b*.parquet"))
    if z=="NL": return sorted(glob.glob(f"{GFS}/load_nl_ch*.parquet"))
    return sorted(glob.glob(f"{GFS}/load_{z}_ch*.parquet"))
def centroid(z):
    c=np.array(geom[z]["cells"],dtype=float); return c[:,0].mean(),c[:,1].mean()
def res_weather(z):
    df=pd.concat([pd.read_parquet(f) for f in res_files(z)],ignore_index=True); df=df[df.zone==z].copy()
    df["h"]=pd.to_datetime(df["h"]); df["ci"]=df["loc_id"].str.split("#c").str[1].astype(int)
    agg=df.groupby("h").agg(ghi=("shortwave_radiation","mean"),cloud=("cloud_cover","mean"),
        pres=("surface_pressure","mean"),v100m=("wind_speed_100m","mean")).reset_index()
    p=df.pivot_table(index="h",columns="ci",values="wind_speed_100m").reindex(columns=sorted(df.ci.unique()))
    return agg,p
def load_weather(z):
    df=pd.concat([pd.read_parquet(f) for f in load_files(z)],ignore_index=True); df=df[df.zone==z].copy()
    df["h"]=pd.to_datetime(df["h"]); df["li"]=df["loc_id"].str.split("#l").str[1].astype(int)
    wmap={i:c[2] for i,c in enumerate(geom[z]["cities"])}; df["w"]=df["li"].map(wmap)
    out=None
    for col in ["temperature_2m","shortwave_radiation"]:
        pr=df[col].notna(); wv=df["w"].where(pr,0.0)*df[col].fillna(0.0); ww=df["w"].where(pr,0.0)
        g=pd.DataFrame({"h":df["h"],"wv":wv,"ww":ww}).groupby("h").sum()
        s=(g["wv"]/g["ww"].replace(0,np.nan)); s.name={"temperature_2m":"T","shortwave_radiation":"ghi"}[col]
        out=s.to_frame() if out is None else out.join(s)
    return out.reset_index()
CAP=pd.read_parquet(f"{SP}/cap_all39.parquet"); CAP["h"]=pd.to_datetime(CAP["h"]); CAP["d"]=CAP["h"].dt.floor("D")
def capacity_p95(z):
    out={}
    for ptk,sel in [("solar",["Solar"]),("wind",["Wind Onshore","Wind Offshore"])]:
        sub=CAP[(CAP.zone==z)&(CAP.pt.isin(sel))]
        if sub.empty: out[ptk]=None; continue
        daily=sub.groupby("d")["mw"].apply(list); days=pd.date_range(daily.index.min(),daily.index.max(),freq="D")
        arr={d:np.array(v) for d,v in daily.items()}; vals=[]
        for d in days:
            win=[arr[d-pd.Timedelta(days=k)] for k in range(1,31) if (d-pd.Timedelta(days=k)) in arr]
            vals.append(np.percentile(np.concatenate(win),95) if win else np.nan)
        out[ptk]=pd.Series(vals,index=days).shift(2)
    return out
TGT_LOAD=pd.read_parquet(f"{SP}/tgt_load39.parquet"); TGT_LOAD["h"]=pd.to_datetime(TGT_LOAD["h"])
def add_cal(df,lat0,lon0):
    h=df["h"].dt; doy=h.dayofyear.values.astype(float); hod=h.hour.values.astype(float)
    df=df.copy(); df["hod"]=hod; df["dow"]=h.dayofweek.values; df["se"]=F.sinel(hod,doy,lat0,lon0)
    df["doy_s"]=np.sin(2*np.pi*doy/365.25); df["doy_c"]=np.cos(2*np.pi*doy/365.25)
    df["doy_s2"]=np.sin(4*np.pi*doy/365.25); df["doy_c2"]=np.cos(4*np.pi*doy/365.25); return df
def pcurve(v): x=v/3.6; return np.where((x<3)|(x>=25),0.0,np.where(x>=12,1.0,((x-3)/9.0)**3))
def baseline_wind(z,cellp):
    wm=RESP[z].get("wind")
    if wm is None: return pd.Series(0.0,index=cellp.index)
    coef=np.array(wm["coef"]);V=cellp.values;X=np.column_stack([np.ones(len(V)),pcurve(V),V/3.6]);return pd.Series(np.maximum(X@coef,0.0),index=cellp.index)
def baseline_solar(z,agg):
    sm=RESP[z].get("solar")
    if sm is None: return pd.Series(0.0,index=agg.index)
    coef=np.array(sm["coef"]);lat0=sm["lat0"];lon0=sm["lon0"];g=agg["ghi"].values
    hod=agg["h"].dt.hour.values.astype(float);doy=agg["h"].dt.dayofyear.values.astype(float);se=F.sinel(hod,doy,lat0,lon0)
    cols=[np.ones(len(g)),g,se,g*se,np.sqrt(np.maximum(g,0))]
    for k in range(3,20): cols.append(np.where(hod==k,g,0.0))
    for k in range(3,20): cols.append(np.where(hod==k,1.0,0.0))
    return pd.Series(np.maximum(np.column_stack(cols)@coef,0.0),index=agg.index)
def jnum(x): return None if (x is None or (isinstance(x,float) and np.isnan(x))) else float(x)

out={}
for z in ZONES:
    lat0,lon0=centroid(z); ra,cellp=res_weather(z); la=load_weather(z); cap=capacity_p95(z)
    ra=add_cal(ra,lat0,lon0); ra["clearness"]=(ra["ghi"]/np.maximum(F.S0*ra["se"],1.0)).clip(0,1.3); ra["d"]=ra["h"].dt.floor("D")
    for pt in ["solar","wind"]:
        s=cap.get(pt); ra[f"cap95_{pt}"]=ra["d"].map(s) if s is not None else np.nan
    la=add_cal(la,lat0,lon0); la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    la["cdh"]=np.maximum(la["T"]-21.0,0);la["hdh"]=np.maximum(16.5-la["T"],0);la["cdh2"]=la["cdh"]**2/10;la["hdh2"]=la["hdh"]**2/10
    tl=TGT_LOAD[TGT_LOAD.zone==z][["h","load_da"]]; la=la.merge(tl,on="h",how="left"); lser=la.set_index("h")["load_da"]
    la["ar1"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=1),np.nan)); la["ar7"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=7),np.nan))
    holset=F.holidays(LOADP[z]["holiday_country"],range(2024,2027)); la["is_hol"]=la["h"].dt.normalize().isin(holset).astype(int)
    ra_h=ra[ra["h"].isin(hours)].copy(); la_h=la[la["h"].isin(hours)].copy()
    cp=cellp.reindex(ra["h"].values); cp.index=ra.index
    has_s=f"{z}_solar" in meta; has_w=f"{z}_wind" in meta; has_l=f"{z}_load" in meta
    if has_s:
        fs=meta[f"{z}_solar"]["feat_cols"]; rs=meta[f"{z}_solar"].get("ref_col")
        ms=lgb.Booster(model_file=f"{MODELS}/{z}_solar.txt"); sp=ms.predict(ra_h[fs])
        if rs is not None: sp=sp*ra_h[rs].values
        sp=np.maximum(sp,0.0); sp=np.where(ra_h["se"].values<=1e-6,0.0,sp)
    if has_w:
        fw=meta[f"{z}_wind"]["feat_cols"]; rw=meta[f"{z}_wind"].get("ref_col")
        mw=lgb.Booster(model_file=f"{MODELS}/{z}_wind.txt"); wp=mw.predict(ra_h[fw])
        if rw is not None: wp=wp*ra_h[rw].values
        wp=np.maximum(wp,0.0)
    if has_l:
        fl=meta[f"{z}_load"]["feat_cols"]; ml=lgb.Booster(model_file=f"{MODELS}/{z}_load.txt"); lp=np.maximum(ml.predict(la_h[fl]),0.0)
    bsolar=baseline_solar(z,ra).reindex(ra_h.index).values
    bwind=np.maximum(baseline_wind(z,cp).reindex(ra_h.index).values,0.0)
    zo={}; la_idx={pd.Timestamp(h):i for i,h in enumerate(la_h["h"].values)}
    for i in range(len(ra_h)):
        h=pd.Timestamp(ra_h["h"].values[i]); key=h.strftime("%Y%m%d-%H%M"); rec={"se":jnum(ra_h["se"].values[i])}
        if has_s: rec["feats_solar"]=[jnum(ra_h[c].values[i]) for c in fs]; rec["new_solar"]=jnum(sp[i])
        if has_w: rec["feats_wind"]=[jnum(ra_h[c].values[i]) for c in fw]; rec["new_wind"]=jnum(wp[i])
        rec["base_solar"]=jnum(bsolar[i]); rec["base_wind"]=jnum(bwind[i])
        if has_l and h in la_idx:
            li=la_idx[h]; rec["feats_load"]=[jnum(la_h[c].values[li]) for c in fl]; rec["new_load"]=jnum(lp[li])
        zo[key]=rec
    out[z]=zo
    print(f"  {z}: solar={has_s} wind={has_w} load={has_l} hours={len(zo)}")
json.dump(out,open(f"{SP}/eval_ref.json","w"))
print("wrote eval_ref.json zones",list(out.keys())); print("DUMP39_DONE")
