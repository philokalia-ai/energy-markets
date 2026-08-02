#!/usr/bin/env python3
"""Rollout-39 trainer. Trains LightGBM ex-ante input models for GR (retrain, Orthodox
holidays) + the 34 new footprint zones, scores NEW vs the committed linear packs on
the frozen VALID window, and emits a per-zone-winner ship map. Reuses the FROZEN
protocol exactly (features.py functions imported for holiday/calendar lockstep)."""
import os, sys, json, glob, numpy as np, pandas as pd, lightgbm as lgb
sys.path.insert(0, "/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a534d70e414d18b80/docs/experiments/input-upgrade")
import features as F   # holidays(), orthodox_easter(), sinel(), eu_dst_offset(), S0

SP=F.SP; BIN="/home/pgeorgakopoulos/armada/energy-markets/bin"
GFS=f"{SP}/gfs"
RESP=json.load(open(f"{BIN}/res_models_v2.json"))["zones"]
LOADP=json.load(open(f"{BIN}/load_models_v1.json"))["zones"]
GEOM=json.load(open(f"{SP}/geom39.json"))
OUTDIR=f"{SP}/models39"; os.makedirs(OUTDIR, exist_ok=True)
S0=F.S0
TRAIN_END=pd.Timestamp("2026-04-30 23:00")
VAL0,VAL1=pd.Timestamp("2026-05-01"),pd.Timestamp("2026-07-22 23:00")

ZONES=[z for z in (["GR"]+sorted(set(GEOM)-{"GR","ES","DE_LU","SE2","NL"})) ]
ZONES=[z for z in ZONES if z in GEOM]
_only=os.environ.get("ZONES_ONLY","")
if _only: ZONES=[z for z in ZONES if z in set(_only.split(","))]

# ---- per-zone weather file resolution (pilot multi-zone files vs new per-zone) ----
PILOT_MULTI={"GR","ES","DE_LU","SE2"}
def res_files(z):
    if z in PILOT_MULTI: return sorted(glob.glob(f"{GFS}/res_ch*_b*.parquet"))
    if z=="NL": return sorted(glob.glob(f"{GFS}/res_nl_ch*.parquet"))
    return sorted(glob.glob(f"{GFS}/res_{z}_ch*.parquet"))
def load_files(z):
    if z in PILOT_MULTI: return sorted(glob.glob(f"{GFS}/load_ch*_b*.parquet"))
    if z=="NL": return sorted(glob.glob(f"{GFS}/load_nl_ch*.parquet"))
    return sorted(glob.glob(f"{GFS}/load_{z}_ch*.parquet"))

def zone_centroid(z):
    cells=np.array(GEOM[z]["cells"],dtype=float); return cells[:,0].mean(),cells[:,1].mean()

def res_weather(z):
    fs=res_files(z)
    if not fs: return None,None
    df=pd.concat([pd.read_parquet(f) for f in fs],ignore_index=True)
    df=df[df.zone==z].copy()
    if df.empty: return None,None
    df["h"]=pd.to_datetime(df["h"]); df["ci"]=df["loc_id"].str.split("#c").str[1].astype(int)
    agg=df.groupby("h").agg(ghi=("shortwave_radiation","mean"),cloud=("cloud_cover","mean"),
        pres=("surface_pressure","mean"),v100m=("wind_speed_100m","mean")).reset_index()
    p=df.pivot_table(index="h",columns="ci",values="wind_speed_100m")
    p=p.reindex(columns=sorted(p.columns))
    return agg,p

def load_weather(z):
    fs=load_files(z)
    if not fs: return None
    df=pd.concat([pd.read_parquet(f) for f in fs],ignore_index=True)
    df=df[df.zone==z].copy()
    if df.empty: return None
    df["h"]=pd.to_datetime(df["h"]); df["li"]=df["loc_id"].str.split("#l").str[1].astype(int)
    wmap={i:c[2] for i,c in enumerate(GEOM[z]["cities"])}
    df["w"]=df["li"].map(wmap)
    out=None
    for col in ["temperature_2m","shortwave_radiation"]:
        pres=df[col].notna(); wv=df["w"].where(pres,0.0)*df[col].fillna(0.0); ww=df["w"].where(pres,0.0)
        g=pd.DataFrame({"h":df["h"],"wv":wv,"ww":ww}).groupby("h").sum()
        s=(g["wv"]/g["ww"].replace(0,np.nan)); s.name={"temperature_2m":"T","shortwave_radiation":"ghi"}[col]
        out=s.to_frame() if out is None else out.join(s)
    return out.reset_index()

# ---- capacity p95 (trailing 30d ending D-2), per zone ----
CAPRAW=pd.read_parquet(f"{SP}/cap_all39.parquet"); CAPRAW["h"]=pd.to_datetime(CAPRAW["h"])
CAPRAW["d"]=CAPRAW["h"].dt.floor("D")
def capacity_p95(z):
    out={}
    for ptk,sel in [("solar",["Solar"]),("wind",["Wind Onshore","Wind Offshore"])]:
        sub=CAPRAW[(CAPRAW.zone==z)&(CAPRAW.pt.isin(sel))]
        if sub.empty: out[ptk]=None; continue
        daily=sub.groupby("d")["mw"].apply(list)
        days=pd.date_range(daily.index.min(),daily.index.max(),freq="D")
        arr={d:np.array(v) for d,v in daily.items()}; vals=[]
        for d in days:
            win=[arr[d-pd.Timedelta(days=k)] for k in range(1,31) if (d-pd.Timedelta(days=k)) in arr]
            vals.append(np.percentile(np.concatenate(win),95) if win else np.nan)
        out[ptk]=pd.Series(vals,index=days).shift(2)
    return out

TGT_LOAD=pd.read_parquet(f"{SP}/tgt_load39.parquet"); TGT_LOAD["h"]=pd.to_datetime(TGT_LOAD["h"])
TGT_RES =pd.read_parquet(f"{SP}/tgt_res39.parquet");  TGT_RES["h"]=pd.to_datetime(TGT_RES["h"])

def add_cal(df,lat0,lon0):
    h=df["h"].dt; doy=h.dayofyear.values.astype(float); hod=h.hour.values.astype(float)
    df=df.copy(); df["hod"]=hod; df["dow"]=h.dayofweek.values
    df["se"]=F.sinel(hod,doy,lat0,lon0)
    df["doy_s"]=np.sin(2*np.pi*doy/365.25); df["doy_c"]=np.cos(2*np.pi*doy/365.25)
    df["doy_s2"]=np.sin(4*np.pi*doy/365.25); df["doy_c2"]=np.cos(4*np.pi*doy/365.25)
    return df

def metrics(pred,tgt):
    m=~(np.isnan(pred)|np.isnan(tgt)); p,t=pred[m],tgt[m]
    if len(p)<5: return dict(n=len(p),mae=np.nan,bias=np.nan,corr=np.nan,nmae=np.nan)
    mae=float(np.mean(np.abs(p-t))); bias=float(np.mean(p-t))
    corr=float(np.corrcoef(p,t)[0,1]) if np.std(p)>0 and np.std(t)>0 else np.nan
    return dict(n=int(len(p)),mae=mae,bias=bias,corr=corr,nmae=mae/max(np.mean(np.abs(t)),1e-6))

# ---- baseline pack replication (same weather) ----
def pcurve(v_kmh):
    x=v_kmh/3.6; return np.where((x<3)|(x>=25),0.0,np.where(x>=12,1.0,((x-3)/9.0)**3))
def baseline_wind(z,cellp):
    wm=RESP[z].get("wind")
    if wm is None: return pd.Series(0.0,index=cellp.index)
    coef=np.array(wm["coef"]); V=cellp.values
    X=np.column_stack([np.ones(len(V)),pcurve(V),V/3.6]); return pd.Series(np.maximum(X@coef,0.0),index=cellp.index)
def baseline_solar(z,agg):
    sm=RESP[z].get("solar")
    if sm is None: return pd.Series(0.0,index=agg.index)
    coef=np.array(sm["coef"]);lat0=sm["lat0"];lon0=sm["lon0"]
    g=agg["ghi"].values;hod=agg["h"].dt.hour.values.astype(float);doy=agg["h"].dt.dayofyear.values.astype(float)
    se=F.sinel(hod,doy,lat0,lon0); cols=[np.ones(len(g)),g,se,g*se,np.sqrt(np.maximum(g,0))]
    for k in range(3,20): cols.append(np.where(hod==k,g,0.0))
    for k in range(3,20): cols.append(np.where(hod==k,1.0,0.0))
    return pd.Series(np.maximum(np.column_stack(cols)@coef,0.0),index=agg.index)
def baseline_load(z,la):
    zm=LOADP[z];coef=np.array(zm["coef"]);mu_x=np.array(zm["mu_x"]);sd_x=np.array(zm["sd_x"]);mu_y=zm["mu_y"];tzb=zm["tz_base"]
    hdh_b=zm.get("hdh_base",16.5);cdh_b=zm.get("cdh_base",21.0)
    trend0=pd.Timestamp(json.load(open(f"{BIN}/load_models_v1.json")).get("trend_origin","2022-07-01"))
    yrs=range(la["h"].dt.year.min()-1,la["h"].dt.year.max()+2)
    hol=F.holidays(zm["holiday_country"],yrs)
    la=la.sort_values("h").copy(); la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    X=np.zeros((len(la),207))
    for i,(_,r) in enumerate(la.iterrows()):
        ts=r["h"];off=F.eu_dst_offset(ts,tzb);lt=ts+pd.Timedelta(hours=off)
        how=(lt.dayofweek)*24+lt.hour; X[i,how]=1.0
        is_hol=lt.normalize() in hol; o=168
        if is_hol: X[i,o+lt.hour]=1.0
        o+=24; X[i,o]=1.0 if is_hol else 0.0; o+=1
        T=r["T"];G=r["ghi"];Tma=r["Tma"]
        hdh=max(hdh_b-T,0);cdh=max(T-cdh_b,0);hdhm=max(hdh_b-Tma,0);cdhm=max(Tma-cdh_b,0)
        X[i,o:o+8]=[hdh,cdh,hdh**2/10,cdh**2/10,hdhm,cdhm,hdhm**2/10,cdhm**2/10];o+=8
        X[i,o]=G/100;o+=1
        doy=lt.dayofyear/365.25; X[i,o:o+4]=[np.sin(2*np.pi*doy),np.cos(2*np.pi*doy),np.sin(4*np.pi*doy),np.cos(4*np.pi*doy)];o+=4
        X[i,o]=(ts-trend0).total_seconds()/(3600*24*365.25)
    return pd.Series(np.maximum(((X-mu_x)/sd_x)@coef+mu_y,0.0),index=la.index)

lgb_params=dict(objective="l1",num_leaves=31,learning_rate=0.05,n_estimators=600,
    min_child_samples=40,subsample=0.8,subsample_freq=1,colsample_bytree=0.8,reg_lambda=1.0,verbosity=-1)
CORR_GUARD_TOL=0.02   # fit-iteration 1 (R1): NEW may lose at most this much VALID corr vs pack
scorecard=[]; meta={}; winners={}

def fit_score(z,target,df,feat_cols,tgt_col,baseline_pred,clamp_night=False,ref_col=None):
    d=df.dropna(subset=[tgt_col]).copy()
    if ref_col is not None:
        d=d[d[ref_col]>1.0].copy()
        if len(d)<500:
            print(f"  {z}_{target}: too few ref>1 rows ({len(d)}) -> pack"); return
        d["_y"]=(d[tgt_col]/d[ref_col]).clip(0,1.3); ycol="_y"
    else: ycol=tgt_col
    tr=d[d["h"]<=TRAIN_END]; va=d[(d["h"]>=VAL0)&(d["h"]<=VAL1)]
    if len(tr)<500 or len(va)<50:
        print(f"  {z}_{target}: SKIP tr={len(tr)} va={len(va)} -> pack"); return
    cut=tr["h"].quantile(0.9); itr=tr[tr["h"]<=cut]; iva=tr[tr["h"]>cut]
    m=lgb.LGBMRegressor(**lgb_params)
    m.fit(itr[feat_cols],itr[ycol],eval_set=[(iva[feat_cols],iva[ycol])],eval_metric="l1",
          callbacks=[lgb.early_stopping(40,verbose=False)])
    best=m.best_iteration_ or lgb_params["n_estimators"]
    p2=dict(lgb_params);p2["n_estimators"]=best; m=lgb.LGBMRegressor(**p2); m.fit(tr[feat_cols],tr[ycol])
    raw=m.predict(va[feat_cols]); pv=np.maximum(raw*(va[ref_col].values if ref_col is not None else 1.0),0.0)
    if clamp_night: pv=np.where(va["se"].values<=1e-6,0.0,pv)
    bv=baseline_pred.reindex(va.index).values
    mn=metrics(pv,va[tgt_col].values); mb=metrics(bv,va[tgt_col].values)
    # Winner selection: NEW ships only when it beats the pack on VALID MAE AND does
    # not lose more than CORR_GUARD_TOL correlation vs the pack (fit-iteration 1,
    # R1). MAE-only was blind to shape and shipped corr regressions (NO2/FR wind,
    # NL solar). corr_ok is vacuously true when either corr is NaN (degenerate).
    mae_better = (not np.isnan(mn["mae"])) and (np.isnan(mb["mae"]) or mn["mae"]<mb["mae"])
    corr_ok = np.isnan(mn["corr"]) or np.isnan(mb["corr"]) or (mn["corr"] >= mb["corr"]-CORR_GUARD_TOL)
    win = mae_better and corr_ok
    scorecard.append(dict(zone=z,target=target,model="NEW",win=win,**mn))
    scorecard.append(dict(zone=z,target=target,model="pack",win=win,**mb))
    winners[(z,target)]=bool(win)
    m.booster_.save_model(f"{OUTDIR}/{z}_{target}.txt")
    meta[f"{z}_{target}"]=dict(feat_cols=feat_cols,best_iter=int(best),clamp_night=clamp_night,
        n_train=int(len(tr)),ref_col=ref_col)
    print(f"  {z}_{target:5s} NEW mae={mn['mae']:.1f} corr={mn['corr']:.3f} | pack mae={mb['mae']:.1f} corr={mb['corr']:.3f} -> {'NEW' if win else 'pack'}")

for z in ZONES:
    print(f"[{z}]",flush=True)
    lat0,lon0=zone_centroid(z)
    ra,cellp=res_weather(z); la=load_weather(z)
    if ra is None or la is None:
        print(f"  {z}: MISSING weather (ra={ra is not None} la={la is not None}) -> skip zone"); continue
    cap=capacity_p95(z)
    ra=add_cal(ra,lat0,lon0)
    ra["clearness"]=(ra["ghi"]/np.maximum(S0*ra["se"],1.0)).clip(0,1.3); ra["d"]=ra["h"].dt.floor("D")
    for pt in ["solar","wind"]:
        s=cap.get(pt); ra[f"cap95_{pt}"]=ra["d"].map(s) if s is not None else np.nan
    tr=TGT_RES[TGT_RES.zone==z][["h","solar_da","wind_da"]]; ra=ra.merge(tr,on="h",how="left")
    cp=cellp.reindex(ra["h"].values); cp.index=ra.index
    # SOLAR
    if GEOM[z]["solar"]:
        bs=baseline_solar(z,ra)
        feat_s=["ghi","cloud","pres","se","clearness","hod","doy_s","doy_c","doy_s2","doy_c2","cap95_solar","v100m"]
        fit_score(z,"solar",ra,feat_s,"solar_da",bs,clamp_night=True,ref_col="cap95_solar")
    else:
        print(f"  {z}_solar: no meaningful solar (geom) -> pack/zero passthrough")
    # WIND
    if GEOM[z]["wind"]:
        bw=baseline_wind(z,cp)
        feat_w=["v100m","cloud","pres","hod","dow","doy_s","doy_c","doy_s2","doy_c2","cap95_wind"]
        fit_score(z,"wind",ra,feat_w,"wind_da",bw,ref_col="cap95_wind")
    else:
        print(f"  {z}_wind: no meaningful wind (geom) -> pack/zero passthrough")
    # LOAD
    la=add_cal(la,lat0,lon0); la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    la["cdh"]=np.maximum(la["T"]-21.0,0);la["hdh"]=np.maximum(16.5-la["T"],0)
    la["cdh2"]=la["cdh"]**2/10;la["hdh2"]=la["hdh"]**2/10
    tl=TGT_LOAD[TGT_LOAD.zone==z][["h","load_da"]]; la=la.merge(tl,on="h",how="left")
    lser=la.set_index("h")["load_da"]
    la["ar1"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=1),np.nan))
    la["ar7"]=la["h"].map(lambda t:lser.get(t-pd.Timedelta(days=7),np.nan))
    holset=F.holidays(LOADP[z]["holiday_country"],range(2024,2027))
    la["is_hol"]=la["h"].dt.normalize().isin(holset).astype(int)
    bl=baseline_load(z,la)
    feat_l=["T","Tma","cdh","hdh","cdh2","hdh2","ghi","hod","dow","is_hol","doy_s","doy_c","doy_s2","doy_c2","ar1","ar7"]
    fit_score(z,"load",la,feat_l,"load_da",bl)

sc=pd.DataFrame(scorecard); sc.to_csv(f"{SP}/scorecard39.csv",index=False)
json.dump(meta,open(f"{OUTDIR}/meta.json","w"),indent=0)
json.dump({f"{z}|{t}":w for (z,t),w in winners.items()},open(f"{SP}/winners39.json","w"),indent=1)
print("\n=== WINNERS (NEW beats pack on VALID) ===")
for (z,t),w in sorted(winners.items()):
    print(f"  {z:12s} {t:5s} {'NEW ' if w else 'pack'}")
print("TRAIN39_DONE")
