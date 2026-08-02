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
    # Western (Gregorian) Easter — Meeus/Butcher. Used for the Catholic/Protestant zones.
    a=y%19;b=y//100;c=y%100;d=b//4;e=b%4;f=(b+8)//25;g=(b-f+1)//3
    h=(19*a+b-d-g+15)%30;i=c//4;k=c%4;l=(32+2*e+2*i-h-k)%7
    m=(a+11*h+22*l)//451;mo=(h+l-7*m+114)//31;da=((h+l-7*m+114)%31)+1
    return pd.Timestamp(y,mo,da)
def orthodox_easter(y):
    # Orthodox (Julian) Easter — Meeus Julian algorithm, +13d to the Gregorian
    # calendar (valid 1900-2099). rollout-39 amendment 1: GR/BG/RO/RS movable
    # feasts are computed from THIS, not the Western easter() (fixes the pilot's
    # disclosed Western-Easter approximation). Mirrored bit-for-bit in
    # bin/ml_inputs.jl `ml_orthodox_easter` — change both together.
    a=y%4;b=y%7;c=y%19
    d=(19*c+15)%30
    e=(2*a+4*b-d+34)%7
    month=(d+e+114)//31; day=((d+e+114)%31)+1
    return pd.Timestamp(y,month,day)+pd.Timedelta(days=13)
def holidays(country,years):
    # Fixed national holidays + movable (Easter-anchored) feasts. ORTHODOX_ZONES use
    # the Orthodox computus for the movable feasts; ES/DE/SE use the Western one; any
    # other country returns only its fixed map (empty if unlisted). Mirrored exactly
    # in bin/ml_inputs.jl `ml_holidays` (train/serve lockstep — change both together).
    ORTHODOX={"GR","BG","RO","RS"}
    FIXED={"GR":[(1,1),(1,6),(3,25),(5,1),(8,15),(10,28),(12,25),(12,26)],
           "BG":[(1,1),(3,3),(5,1),(5,6),(5,24),(9,6),(9,22),(12,24),(12,25),(12,26)],
           "RO":[(1,1),(1,2),(1,24),(5,1),(6,1),(8,15),(11,30),(12,1),(12,25),(12,26)],
           "RS":[(1,1),(1,2),(1,7),(2,15),(2,16),(5,1),(5,2),(11,11)],
           "ES":[(1,1),(1,6),(5,1),(8,15),(10,12),(11,1),(12,6),(12,8),(12,25)],
           "DE":[(1,1),(5,1),(10,3),(12,25),(12,26)],
           "SE":[(1,1),(1,6),(5,1),(6,6),(12,25),(12,26)],
           # fit-iteration 2: national fixed holidays for the remaining footprint
           # countries (all Western-Easter). Mirrored byte-for-byte in ml_inputs.jl
           # ml_holidays; lands at the NEXT retrain (current models trained is_hol=0
           # here so is_hol is a zero-variance, unsplit feature — inert until then).
           "AT":[(1,1),(1,6),(5,1),(8,15),(10,26),(11,1),(12,8),(12,25),(12,26)],
           "BE":[(1,1),(5,1),(7,21),(8,15),(11,1),(11,11),(12,25)],
           "CH":[(1,1),(8,1),(12,25),(12,26)],
           "CZ":[(1,1),(5,1),(5,8),(7,5),(7,6),(9,28),(10,28),(11,17),(12,24),(12,25),(12,26)],
           "DK":[(1,1),(12,25),(12,26)],
           "EE":[(1,1),(2,24),(5,1),(6,23),(6,24),(8,20),(12,24),(12,25),(12,26)],
           "FI":[(1,1),(1,6),(5,1),(12,6),(12,24),(12,25),(12,26)],
           "FR":[(1,1),(5,1),(5,8),(7,14),(8,15),(11,1),(11,11),(12,25)],
           "HU":[(1,1),(3,15),(5,1),(8,20),(10,23),(11,1),(12,25),(12,26)],
           "IT":[(1,1),(1,6),(4,25),(5,1),(6,2),(8,15),(11,1),(12,8),(12,25),(12,26)],
           "LT":[(1,1),(2,16),(3,11),(5,1),(6,24),(7,6),(8,15),(11,1),(11,2),(12,24),(12,25),(12,26)],
           "LV":[(1,1),(5,1),(5,4),(6,23),(6,24),(11,18),(12,24),(12,25),(12,26),(12,31)],
           "NL":[(1,1),(4,27),(12,25),(12,26)],
           "NO":[(1,1),(5,1),(5,17),(12,25),(12,26)],
           "PL":[(1,1),(1,6),(5,1),(5,3),(8,15),(11,1),(11,11),(12,25),(12,26)],
           "PT":[(1,1),(4,25),(5,1),(6,10),(8,15),(10,5),(11,1),(12,1),(12,8),(12,25)],
           "SI":[(1,1),(1,2),(2,8),(4,27),(5,1),(5,2),(6,25),(8,15),(10,31),(11,1),(12,25),(12,26)],
           "SK":[(1,1),(1,6),(5,1),(5,8),(7,5),(8,29),(9,1),(9,15),(11,1),(11,17),(12,24),(12,25),(12,26)]}
    MOVABLE={"GR":(-48,-2,0,1,50),"BG":(-2,-1,0,1),"RO":(-2,0,1,49,50),"RS":(-2,0,1),
             "ES":(-2,0),"DE":(-2,1,39,50),"SE":(-2,0,1,39,49),
             # Western-Easter offsets: -3 Maundy Thu, -2 Good Fri, 0 Easter Sun,
             # 1 Easter Mon, 39 Ascension, 49 Whit Sun, 50 Whit Mon, 60 Corpus.
             "AT":(1,39,50,60),"BE":(1,39,50),"CH":(-2,1,39,50),
             "CZ":(-2,1),"DK":(-3,-2,0,1,39,50),"EE":(-2,0,49),
             "FI":(-2,0,1,39,49),"FR":(1,39,50),"HU":(-2,0,1,49,50),
             "IT":(0,1),"LT":(0,1),"LV":(-2,0,1),
             "NL":(-2,1,39,50),"NO":(-3,-2,0,1,39,49,50),"PL":(0,1,49,60),
             "PT":(-2,0,60),"SI":(0,1),"SK":(-2,0,1)}
    hs=set()
    for y in years:
        E=orthodox_easter(y) if country in ORTHODOX else easter(y)
        for md in FIXED.get(country,[]): hs.add(pd.Timestamp(y,md[0],md[1]))
        for o in MOVABLE.get(country,()): hs.add(E+pd.Timedelta(days=o))
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
