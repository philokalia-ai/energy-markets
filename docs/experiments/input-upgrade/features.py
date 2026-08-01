#!/usr/bin/env python3
"""Shared ex-ante feature engineering for the input-upgrade models.
Targets = ENTSO-E DA forecasts. Weather = GFS previous_day1 vintages.
All features available at the 08:00 UTC D-1 gate."""
import os, glob, json, numpy as np, pandas as pd

SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
import os as _os
ZONES=["GR","ES","DE_LU","SE2"]+(["NL"] if _os.path.exists(SP+"/gfs/res_nl_ch0.parquet") else [])
GEOM=json.load(open(f"{SP}/geom.json"))
S0=1361.0

def sinel(harr, doy, lat0, lon0):
    dec=0.409*np.sin(2*np.pi*(doy+284)/365.0)
    H=(harr+lon0/15.0-12.0)*15*np.pi/180.0
    return np.maximum(np.sin(np.radians(lat0))*np.sin(dec)+np.cos(np.radians(lat0))*np.cos(dec)*np.cos(H),0.0)

def zone_centroid(z):
    cells=np.array(GEOM[z]["cells"],dtype=float)
    return cells[:,0].mean(), cells[:,1].mean()

# ---- weather aggregation from GFS parquets ----
def load_gfs(kind):
    fs=sorted(glob.glob(f"{SP}/gfs/{kind}_ch*_b*.parquet")+glob.glob(f"{SP}/gfs/{kind}_nl_ch*.parquet"))
    df=pd.concat([pd.read_parquet(f) for f in fs],ignore_index=True)
    df["zone"]=df["loc_id"].str.split("#").str[0]
    df["h"]=pd.to_datetime(df["h"])
    return df

def res_weather():
    """Per zone-hour: mean GHI, cloud, pressure, mean v100; and per-cell v100 wide (pack order)."""
    df=load_gfs("res")
    df["ci"]=df["loc_id"].str.split("#c").str[1].astype(int)
    agg=df.groupby(["zone","h"]).agg(ghi=("shortwave_radiation","mean"),
        cloud=("cloud_cover","mean"),pres=("surface_pressure","mean"),
        v100m=("wind_speed_100m","mean")).reset_index()
    # per-cell v100 wide (for baseline wind); dict zone-> (hours index, ncells matrix)
    cellmat={}
    for z in ZONES:
        sub=df[df.zone==z]
        p=sub.pivot_table(index="h",columns="ci",values="wind_speed_100m")
        p=p.reindex(columns=sorted(p.columns))
        cellmat[z]=p
    return agg, cellmat

def load_weather():
    """Population-weighted zone T and GHI per hour."""
    df=load_gfs("load")
    df["li"]=df["loc_id"].str.split("#l").str[1].astype(int)
    wmap={}
    for z in ZONES:
        for i,c in enumerate(GEOM[z]["cities"]): wmap[(z,i)]=c[2]
    df["w"]=[wmap[(z,i)] for z,i in zip(df["zone"],df["li"])]
    # vectorized weighted mean: sum(w*v)/sum(w) over present values, per (zone,h)
    out=None
    for col in ["temperature_2m","shortwave_radiation"]:
        pres=df[col].notna()
        wv=df["w"].where(pres,0.0)*df[col].fillna(0.0)
        ww=df["w"].where(pres,0.0)
        g=pd.DataFrame({"zone":df["zone"],"h":df["h"],"wv":wv,"ww":ww}).groupby(["zone","h"]).sum()
        s=(g["wv"]/g["ww"].replace(0,np.nan)).rename({"temperature_2m":"T","shortwave_radiation":"ghi"}.get(col,col))
        s.name={"temperature_2m":"T","shortwave_radiation":"ghi"}[col]
        out=s.to_frame() if out is None else out.join(s)
    return out.reset_index()

# ---- capacity signal: trailing-30d p95 actual gen, shifted to end at D-2 ----
def capacity_p95():
    cap=pd.read_parquet(f"{SP}/cap_actual.parquet")
    cap["h"]=pd.to_datetime(cap["h"]); cap["d"]=cap["h"].dt.floor("D")
    out={}
    for z in ZONES:
        for pt_key,pt_sel in [("solar",["Solar"]),("wind",["Wind Onshore","Wind Offshore"])]:
            sub=cap[(cap.zone==z)&(cap.pt.isin(pt_sel))]
            if sub.empty: continue
            daily=sub.groupby("d")["mw"].apply(list)
            days=pd.date_range(daily.index.min(),daily.index.max(),freq="D")
            vals=[]
            arr={d:np.array(v) for d,v in daily.items()}
            for d in days:
                win=[]
                for k in range(1,31):
                    dd=d-pd.Timedelta(days=k)
                    if dd in arr: win.append(arr[dd])
                vals.append(np.percentile(np.concatenate(win),95) if win else np.nan)
            s=pd.Series(vals,index=days)
            # feature for target day D uses window ending D-2 => shift by 2 days
            out[(z,pt_key)]=s.shift(2)
    return out

# ---- calendar / holidays ----
def easter(y):
    a=y%19;b=y//100;c=y%100;d=b//4;e=b%4;f=(b+8)//25;g=(b-f+1)//3
    h=(19*a+b-d-g+15)%30;i=c//4;k=c%4;l=(32+2*e+2*i-h-k)%7
    m=(a+11*h+22*l)//451;mo=(h+l-7*m+114)//31;da=((h+l-7*m+114)%31)+1
    return pd.Timestamp(y,mo,da)
def holidays(country,years):
    hs=set()
    for y in years:
        E=easter(y)
        fixed={"GR":[(1,1),(1,6),(3,25),(5,1),(8,15),(10,28),(12,25),(12,26)],
               "ES":[(1,1),(1,6),(5,1),(8,15),(10,12),(11,1),(12,6),(12,8),(12,25)],
               "DE":[(1,1),(5,1),(10,3),(12,25),(12,26)],
               "SE":[(1,1),(1,6),(5,1),(6,6),(12,25),(12,26)]}.get(country,[])
        for md in fixed: hs.add(pd.Timestamp(y,md[0],md[1]))
        if country=="GR":
            for o in (-48,-2,0,1,50): hs.add((E+pd.Timedelta(days=o)))  # orthodox approx uses same E here (approx)
        elif country=="ES":
            for o in (-2,0): hs.add(E+pd.Timedelta(days=o))
        elif country=="DE":
            for o in (-2,1,39,50): hs.add(E+pd.Timedelta(days=o))
        elif country=="SE":
            for o in (-2,0,1,39,49): hs.add(E+pd.Timedelta(days=o))
    return {d.normalize() for d in hs}

def eu_dst_offset(ts, tz_base):
    """EU DST: last Sun Mar 01:00 UTC .. last Sun Oct 01:00 UTC -> +1."""
    y=ts.year
    def last_sun(mo):
        d=pd.Timestamp(y,mo,31)
        while d.dayofweek!=6: d-=pd.Timedelta(days=1)
        return d.replace(hour=1)
    start=last_sun(3); end=last_sun(10)
    return tz_base+(1 if (ts>=start and ts<end) else 0)
