#!/usr/bin/env python3
"""Committed-pack baseline replication (identical GFS-vintage weather inputs) +
shared calendar feature helper. Imported by train.py and predict_inputs.py."""
import json, numpy as np, pandas as pd
import features as F
BIN="/home/pgeorgakopoulos/armada/energy-markets/bin"
RESP=json.load(open(f"{BIN}/res_models_v2.json"))
LOADP=json.load(open(f"{BIN}/load_models_v1.json"))

def add_cal(df,lat0,lon0):
    h=df["h"].dt; doy=h.dayofyear.values.astype(float); hod=h.hour.values.astype(float)
    df=df.copy()
    df["hod"]=hod; df["dow"]=h.dayofweek.values
    df["se"]=F.sinel(hod,doy,lat0,lon0)
    df["doy_s"]=np.sin(2*np.pi*doy/365.25); df["doy_c"]=np.cos(2*np.pi*doy/365.25)
    df["doy_s2"]=np.sin(4*np.pi*doy/365.25); df["doy_c2"]=np.cos(4*np.pi*doy/365.25)
    return df

def pcurve(v_kmh):
    x=v_kmh/3.6
    return np.where((x<3)|(x>=25),0.0,np.where(x>=12,1.0,((x-3)/9.0)**3))

def baseline_wind(z,cellp):
    wm=RESP["zones"][z].get("wind")
    if wm is None: return pd.Series(0.0,index=cellp.index)
    coef=np.array(wm["coef"]); V=cellp.values
    X=np.column_stack([np.ones(len(V)), pcurve(V), V/3.6])
    return pd.Series(np.maximum(X@coef,0.0),index=cellp.index)

def baseline_solar(z,agg):
    sm=RESP["zones"][z].get("solar")
    if sm is None: return pd.Series(0.0,index=agg.index)
    coef=np.array(sm["coef"]); lat0=sm["lat0"]; lon0=sm["lon0"]
    g=agg["ghi"].values; hod=agg["h"].dt.hour.values.astype(float); doy=agg["h"].dt.dayofyear.values.astype(float)
    se=F.sinel(hod,doy,lat0,lon0)
    cols=[np.ones(len(g)),g,se,g*se,np.sqrt(np.maximum(g,0))]
    for k in range(3,20): cols.append(np.where(hod==k,g,0.0))
    for k in range(3,20): cols.append(np.where(hod==k,1.0,0.0))
    return pd.Series(np.maximum(np.column_stack(cols)@coef,0.0),index=agg.index)

def baseline_load(z,la):
    zm=LOADP["zones"][z]; coef=np.array(zm["coef"]); mu_x=np.array(zm["mu_x"])
    sd_x=np.array(zm["sd_x"]); mu_y=zm["mu_y"]; tzb=zm["tz_base"]
    hdh_b=zm.get("hdh_base",16.5); cdh_b=zm.get("cdh_base",21.0)
    trend0=pd.Timestamp(LOADP.get("trend_origin","2022-07-01"))
    yrs=range(la["h"].dt.year.min()-1,la["h"].dt.year.max()+2)
    hol=F.holidays(zm["holiday_country"],yrs)
    la=la.sort_values("h").copy(); la["Tma"]=la["T"].rolling(48,min_periods=1).mean()
    X=np.zeros((len(la),207)); H=la["h"].values; Tv=la["T"].values; Gv=la["ghi"].values; Tm=la["Tma"].values
    for i in range(len(la)):
        ts=pd.Timestamp(H[i]); off=F.eu_dst_offset(ts,tzb); lt=ts+pd.Timedelta(hours=off)
        X[i,(lt.dayofweek)*24+lt.hour]=1.0
        is_hol=lt.normalize() in hol; o=168
        if is_hol: X[i,o+lt.hour]=1.0
        o+=24; X[i,o]=1.0 if is_hol else 0.0; o+=1
        T=Tv[i]; G=Gv[i]; Tma=Tm[i]
        hdh=max(hdh_b-T,0);cdh=max(T-cdh_b,0);hdhm=max(hdh_b-Tma,0);cdhm=max(Tma-cdh_b,0)
        X[i,o:o+8]=[hdh,cdh,hdh**2/10,cdh**2/10,hdhm,cdhm,hdhm**2/10,cdhm**2/10]; o+=8
        X[i,o]=G/100; o+=1
        doy=lt.dayofyear/365.25
        X[i,o:o+4]=[np.sin(2*np.pi*doy),np.cos(2*np.pi*doy),np.sin(4*np.pi*doy),np.cos(4*np.pi*doy)];o+=4
        X[i,o]=(ts-trend0).total_seconds()/(3600*24*365.25)
    return pd.Series(np.maximum(((X-mu_x)/sd_x)@coef+mu_y,0.0),index=la.index)
