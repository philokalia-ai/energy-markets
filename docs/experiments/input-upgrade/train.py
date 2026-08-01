#!/usr/bin/env python3
"""Train LightGBM ex-ante input models + score vs committed baseline packs.
Writes: models/*.txt, models/meta.json, scorecard.csv, valid_preds.parquet."""
import os, json, numpy as np, pandas as pd, lightgbm as lgb
import features as F
SP=F.SP; ZONES=F.ZONES
BIN="/home/pgeorgakopoulos/armada/energy-markets/bin"
RESP=json.load(open(f"{BIN}/res_models_v2.json"))
LOADP=json.load(open(f"{BIN}/load_models_v1.json"))
os.makedirs(f"{SP}/models",exist_ok=True)
TRAIN_END=pd.Timestamp("2026-04-30 23:00")
VAL0,VAL1=pd.Timestamp("2026-05-01"),pd.Timestamp("2026-07-22 23:00")

def add_cal(df,lat0,lon0):
    h=df["h"].dt; doy=h.dayofyear.values.astype(float); hod=h.hour.values.astype(float)
    df=df.copy()
    df["hod"]=hod; df["dow"]=h.dayofweek.values
    df["se"]=F.sinel(hod,doy,lat0,lon0)
    df["doy_s"]=np.sin(2*np.pi*doy/365.25); df["doy_c"]=np.cos(2*np.pi*doy/365.25)
    df["doy_s2"]=np.sin(4*np.pi*doy/365.25); df["doy_c2"]=np.cos(4*np.pi*doy/365.25)
    return df

def metrics(pred,tgt):
    m=~(np.isnan(pred)|np.isnan(tgt))
    p,t=pred[m],tgt[m]
    if len(p)<5: return dict(n=len(p),mae=np.nan,bias=np.nan,corr=np.nan,nmae=np.nan)
    mae=np.mean(np.abs(p-t)); bias=np.mean(p-t)
    corr=np.corrcoef(p,t)[0,1] if np.std(p)>0 and np.std(t)>0 else np.nan
    nmae=mae/max(np.mean(np.abs(t)),1e-6)
    return dict(n=int(len(p)),mae=mae,bias=bias,corr=corr,nmae=nmae)

# ---------- baseline pack replication (identical weather inputs) ----------
def pcurve(v_kmh):
    x=v_kmh/3.6
    out=np.where((x<3)|(x>=25),0.0,np.where(x>=12,1.0,((x-3)/9.0)**3))
    return out
def baseline_wind(z,cellp):
    wm=RESP["zones"][z].get("wind");
    if wm is None: return pd.Series(0.0,index=cellp.index)
    coef=np.array(wm["coef"]); V=cellp.values  # hours x ncells (km/h)
    X=np.column_stack([np.ones(len(V)), pcurve(V), V/3.6])
    return pd.Series(np.maximum(X@coef,0.0),index=cellp.index)
def baseline_solar(z,agg):
    sm=RESP["zones"][z].get("solar")
    if sm is None: return pd.Series(0.0,index=agg.index)
    coef=np.array(sm["coef"]); lat0=sm["lat0"]; lon0=sm["lon0"]
    g=agg["ghi"].values; hod=agg["h"].dt.hour.values.astype(float)
    doy=agg["h"].dt.dayofyear.values.astype(float)
    se=F.sinel(hod,doy,lat0,lon0)
    cols=[np.ones(len(g)),g,se,g*se,np.sqrt(np.maximum(g,0))]
    for k in range(3,20): cols.append(np.where(hod==k,g,0.0))
    for k in range(3,20): cols.append(np.where(hod==k,1.0,0.0))
    X=np.column_stack(cols)
    return pd.Series(np.maximum(X@coef,0.0),index=agg.index)
def baseline_load(z,la):
    zm=LOADP["zones"][z]; coef=np.array(zm["coef"]); mu_x=np.array(zm["mu_x"])
    sd_x=np.array(zm["sd_x"]); mu_y=zm["mu_y"]; tzb=zm["tz_base"]
    hdh_b=zm.get("hdh_base",16.5); cdh_b=zm.get("cdh_base",21.0)
    trend0=pd.Timestamp(LOADP.get("trend_origin","2022-07-01"))
    yrs=range(la["h"].dt.year.min()-1,la["h"].dt.year.max()+2)
    hol=F.holidays(zm["holiday_country"],yrs)
    # trailing-48h MA of T
    la=la.sort_values("h").copy()
    la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    X=np.zeros((len(la),207))
    for i,(_,r) in enumerate(la.iterrows()):
        ts=r["h"]; off=F.eu_dst_offset(ts,tzb); lt=ts+pd.Timedelta(hours=off)
        how=(lt.dayofweek)*24+lt.hour  # 0..167
        X[i,how]=1.0
        is_hol=lt.normalize() in hol; o=168
        if is_hol: X[i,o+lt.hour]=1.0
        o+=24; X[i,o]=1.0 if is_hol else 0.0; o+=1
        T=r["T"]; G=r["ghi"]; Tma=r["Tma"]
        hdh=max(hdh_b-T,0);cdh=max(T-cdh_b,0);hdhm=max(hdh_b-Tma,0);cdhm=max(Tma-cdh_b,0)
        X[i,o:o+8]=[hdh,cdh,hdh**2/10,cdh**2/10,hdhm,cdhm,hdhm**2/10,cdhm**2/10]; o+=8
        X[i,o]=G/100; o+=1
        doy=lt.dayofyear/365.25
        X[i,o:o+4]=[np.sin(2*np.pi*doy),np.cos(2*np.pi*doy),np.sin(4*np.pi*doy),np.cos(4*np.pi*doy)];o+=4
        X[i,o]=(ts-trend0).total_seconds()/(3600*24*365.25)
    pred=((X-mu_x)/sd_x)@coef+mu_y
    return pd.Series(np.maximum(pred,0.0),index=la.index)

# ---------- build per (zone,target) frames, train, score ----------
scorecard=[]; valid_rows=[]; meta={}
lgb_params=dict(objective="l1",num_leaves=31,learning_rate=0.05,n_estimators=600,
    min_child_samples=40,subsample=0.8,subsample_freq=1,colsample_bytree=0.8,
    reg_lambda=1.0,verbosity=-1)

def fit_score(name,z,df,feat_cols,tgt_col,baseline_pred,clamp_night=False,ref_col=None):
    d=df.dropna(subset=[tgt_col]).copy()
    # ratio target: y = tgt/ref (capacity-normalized utilization) -> lets the model
    # extrapolate as the fleet grows (ref = ex-ante trailing-p95 capacity). Requires ref>0.
    if ref_col is not None:
        d=d[d[ref_col]>1.0].copy()
        d["_y"]=(d[tgt_col]/d[ref_col]).clip(0,1.3); ycol="_y"
    else:
        ycol=tgt_col
    tr=d[d["h"]<=TRAIN_END]; va=d[(d["h"]>=VAL0)&(d["h"]<=VAL1)]
    if len(tr)<500 or len(va)<50:
        print(f"  SKIP {name} tr={len(tr)} va={len(va)}"); return None
    # inner early-stop tail (last 10% of train, time-ordered)
    cut=tr["h"].quantile(0.9)
    itr=tr[tr["h"]<=cut]; iva=tr[tr["h"]>cut]
    model=lgb.LGBMRegressor(**lgb_params)
    model.fit(itr[feat_cols],itr[ycol],eval_set=[(iva[feat_cols],iva[ycol])],
              eval_metric="l1",callbacks=[lgb.early_stopping(40,verbose=False)])
    # refit on full train at chosen n_estimators
    best=model.best_iteration_ or lgb_params["n_estimators"]
    p2=dict(lgb_params); p2["n_estimators"]=best
    model=lgb.LGBMRegressor(**p2); model.fit(tr[feat_cols],tr[ycol])
    raw=model.predict(va[feat_cols])
    pv=np.maximum(raw*(va[ref_col].values if ref_col is not None else 1.0),0.0)
    if clamp_night: pv=np.where(va["se"].values<=1e-6,0.0,pv)
    bv=baseline_pred.reindex(va.index).values
    mn=metrics(pv,va[tgt_col].values); mb=metrics(bv,va[tgt_col].values)
    scorecard.append(dict(zone=z,target=name.split("_")[-1],model="NEW",**mn))
    scorecard.append(dict(zone=z,target=name.split("_")[-1],model="baseline",**mb))
    model.booster_.save_model(f"{SP}/models/{z}_{name.split('_')[-1]}.txt")
    meta[f"{z}_{name.split('_')[-1]}"]=dict(feat_cols=feat_cols,best_iter=int(best),
        clamp_night=clamp_night,n_train=int(len(tr)),ref_col=ref_col)
    vh=va["h"].values; vt=va[tgt_col].values; tname=name.split("_")[-1]
    for i in range(len(va)):
        valid_rows.append(dict(zone=z,h=vh[i],target=tname,tgt=vt[i],new=pv[i],base=bv[i]))
    print(f"  {name:16s} NEW mae={mn['mae']:.1f} corr={mn['corr']:.3f} | base mae={mb['mae']:.1f} corr={mb['corr']:.3f} (best_iter={best})")
    return model

print("building weather features...",flush=True)
resagg,cellmat=F.res_weather()
loadagg=F.load_weather()
cap=F.capacity_p95()
tgt_load=pd.read_parquet(f"{SP}/tgt_load.parquet"); tgt_load["h"]=pd.to_datetime(tgt_load["h"])
tgt_res=pd.read_parquet(f"{SP}/tgt_res.parquet"); tgt_res["h"]=pd.to_datetime(tgt_res["h"])

for z in ZONES:
    lat0,lon0=F.zone_centroid(z)
    ra=resagg[resagg.zone==z].sort_values("h").reset_index(drop=True)
    ra=add_cal(ra,lat0,lon0)
    ra["clearness"]=ra["ghi"]/np.maximum(F.S0*ra["se"],1.0); ra["clearness"]=ra["clearness"].clip(0,1.3)
    # capacity join (daily -> hour)
    ra["d"]=ra["h"].dt.floor("D")
    for pt in ["solar","wind"]:
        s=cap.get((z,pt))
        ra[f"cap95_{pt}"]=ra["d"].map(s) if s is not None else np.nan
    tr=tgt_res[tgt_res.zone==z][["h","solar_da","wind_da"]]
    ra=ra.merge(tr,on="h",how="left")
    cellp=cellmat[z].reindex(ra["h"].values); cellp.index=ra.index
    # ----- SOLAR -----
    bs=baseline_solar(z,ra)
    feat_s=["ghi","cloud","pres","se","clearness","hod","doy_s","doy_c","doy_s2","doy_c2","cap95_solar","v100m"]
    fit_score("res_solar",z,ra,feat_s,"solar_da",bs,clamp_night=True,ref_col="cap95_solar")
    # ----- WIND -----
    bw=baseline_wind(z,cellp)
    feat_w=["v100m","cloud","pres","hod","dow","doy_s","doy_c","doy_s2","doy_c2","cap95_wind"]
    fit_score("res_wind",z,ra,feat_w,"wind_da",bw,ref_col="cap95_wind")
    # ----- LOAD -----
    la=loadagg[loadagg.zone==z].sort_values("h").reset_index(drop=True)
    la=add_cal(la,lat0,lon0)
    la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    la["cdh"]=np.maximum(la["T"]-21.0,0); la["hdh"]=np.maximum(16.5-la["T"],0)
    la["cdh2"]=la["cdh"]**2/10; la["hdh2"]=la["hdh"]**2/10
    tl=tgt_load[tgt_load.zone==z][["h","load_da"]]
    la=la.merge(tl,on="h",how="left")
    # AR features from the DA-forecast target itself (lag1d, lag7d same hour) - known at gate
    lser=la.set_index("h")["load_da"]
    la["ar1"]=la["h"].map(lambda t: lser.get(t-pd.Timedelta(days=1),np.nan))
    la["ar7"]=la["h"].map(lambda t: lser.get(t-pd.Timedelta(days=7),np.nan))
    la["is_hol"]=0  # simple flag via holidays set
    holset=F.holidays(LOADP["zones"][z]["holiday_country"],range(2024,2027))
    la["is_hol"]=la["h"].dt.normalize().isin(holset).astype(int)
    bl=baseline_load(z,la)
    feat_l=["T","Tma","cdh","hdh","cdh2","hdh2","ghi","hod","dow","is_hol",
            "doy_s","doy_c","doy_s2","doy_c2","ar1","ar7"]
    fit_score("load_load",z,la,feat_l,"load_da",bl)

sc=pd.DataFrame(scorecard); sc.to_csv(f"{SP}/scorecard.csv",index=False)
pd.DataFrame(valid_rows).to_parquet(f"{SP}/valid_preds.parquet")
json.dump(meta,open(f"{SP}/models/meta.json","w"),indent=0)
print("\n=== SCORECARD (valid 2026-05-01..07-22) ===")
piv=sc.pivot_table(index=["zone","target"],columns="model",values=["mae","corr","bias"])
print(piv.to_string())
print("TRAIN_DONE")
