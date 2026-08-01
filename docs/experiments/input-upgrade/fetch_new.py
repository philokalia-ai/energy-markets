#!/usr/bin/env python3
"""Rollout-39 weather fetch: GFS gfs_seamless previous_day1 vintages for the 34
new zones' RES cells + load cities, per-zone resumable, priority-ordered so a
partial night still ships the high-value zones. Files: gfs/res_<zone>_ch<ci>.parquet,
gfs/load_<zone>_ch<ci>.parquet (skip if present). Progress -> fetch_status.json."""
import json, time, os, sys, urllib.request, urllib.parse, datetime
import pandas as pd, numpy as np

SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
OUT=os.path.join(SP,"gfs"); os.makedirs(OUT,exist_ok=True)
PREV="https://previous-runs-api.open-meteo.com/v1/forecast"
UA={"User-Agent":"philokalia-energy/1.0 (contact: pankgeorg@gmail.com)"}
CHUNKS=[("2024-07-14","2024-12-31"),("2025-01-01","2025-06-30"),
        ("2025-07-01","2025-12-31"),("2026-01-01","2026-07-29")]
RES_VARS=["wind_speed_100m","shortwave_radiation","cloud_cover","surface_pressure"]
LOAD_VARS=["temperature_2m","shortwave_radiation"]
GEOM=json.load(open(f"{SP}/geom39.json"))
# priority order (task directive). NL/GR/ES/DE_LU/SE2 are pilots (cached) -> excluded.
PRIORITY=["PL","BG","CZ","AT","HU","RO","RS","FR","IT-NORTH",
          "BE","SK","SI","PT","CH","FI","SE3","SE1","SE4","DK1","DK2","EE","LT","LV",
          "NO1","NO2","NO3","NO4","NO5","IT-CNORTH","IT-CSOUTH","IT-SOUTH",
          "IT-Sicily","IT-Sardinia","IT-Calabria"]
STATUS=os.path.join(SP,"fetch_status.json")

def load_status():
    return json.load(open(STATUS)) if os.path.exists(STATUS) else {"done":[],"log":[]}
def save_status(s):
    json.dump(s,open(STATUS,"w"),indent=1)

def get(params):
    # open-meteo bills per (location × day × variable), so heavy batched requests
    # drain the HOURLY quota after a few zones. On the hourly-limit 429 we PARK
    # until the next clock hour (+buffer) — the overnight-pacing strategy; minutely
    # 429s get a short backoff; genuine errors give up after a bounded burst.
    q=PREV+"?"+urllib.parse.urlencode(params,safe=",")
    i=0; nonrate=0
    while True:
        i+=1
        try:
            req=urllib.request.Request(q,headers=UA)
            with urllib.request.urlopen(req,timeout=240) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            body=""
            try: body=e.read().decode()[:200]
            except Exception: pass
            if e.code==429:
                if "hour" in body.lower():
                    now=time.time(); wait=3600-(now%3600)+90   # to next clock hour + buffer
                    print(f"  HOURLY limit — parking {wait:.0f}s to next hour ({body[:60]})",flush=True)
                else:
                    wait=min(20+8*i, 90.0)
                    print(f"  minutely 429 wait {wait:.0f}s",flush=True)
                time.sleep(wait)
            else:
                nonrate+=1
                if nonrate>=10: raise RuntimeError(f"failed(http {e.code}) "+q[:120])
                print(f"  http {e.code} retry {nonrate} wait {5*nonrate}s",flush=True); time.sleep(5*nonrate)
        except Exception as e:
            nonrate+=1
            if nonrate>=10: raise RuntimeError("failed(non-429) "+str(e)[:120]+" "+q[:120])
            print(f"  err retry {nonrate} ({str(e)[:70]}) wait {5*nonrate}s",flush=True); time.sleep(5*nonrate)

def fetch_zone_kind(zone, kind, pts, base_vars):
    """pts: list of (idx, lat, lon). Writes res_/load_ <zone>_ch<ci>.parquet."""
    if not pts: return True
    vsfx=[v+"_previous_day1" for v in base_vars]
    for ci,(d0,d1) in enumerate(CHUNKS):
        fn=os.path.join(OUT,f"{kind}_{zone}_ch{ci}.parquet")
        if os.path.exists(fn):
            continue
        rows=[]
        for bi in range(0,len(pts),50):
            batch=pts[bi:bi+50]
            lats=",".join(str(p[1]) for p in batch)
            lons=",".join(str(p[2]) for p in batch)
            params={"latitude":lats,"longitude":lons,"hourly":",".join(vsfx),
                    "models":"gfs_seamless","start_date":d0,"end_date":d1,"timezone":"UTC"}
            d=get(params); locs=d if isinstance(d,list) else [d]
            assert len(locs)==len(batch),f"{len(locs)} vs {len(batch)} {zone} {kind}"
            pfx="c" if kind=="res" else "l"
            for p,loc in zip(batch,locs):
                h=loc["hourly"]; t=h["time"]
                rec={"loc_id":f"{zone}#{pfx}{p[0]}","zone":zone,"h":t}
                for bv,sv in zip(base_vars,vsfx):
                    rec[bv]=h.get(sv,[None]*len(t))
                rows.append(pd.DataFrame(rec))
            time.sleep(1.0)
        out=pd.concat(rows,ignore_index=True); out["h"]=pd.to_datetime(out["h"])
        out.to_parquet(fn)
        print(f"  wrote {os.path.basename(fn)} rows={len(out)}",flush=True)
    return True

def main():
    st=load_status()
    todo=[z for z in PRIORITY if z in GEOM and z not in st["done"]]
    print(f"fetch_new start {datetime.datetime.now()} todo={len(todo)}: {todo}",flush=True)
    for z in todo:
        g=GEOM[z]
        cells=[(i,float(c[0]),float(c[1])) for i,c in enumerate(g["cells"])]
        cities=[(i,float(c[0]),float(c[1])) for i,c in enumerate(g["cities"])]
        t0=time.time()
        try:
            fetch_zone_kind(z,"res",cells,RES_VARS)
            fetch_zone_kind(z,"load",cities,LOAD_VARS)
        except Exception as e:
            print(f"ZONE {z} FAILED ({str(e)[:100]}) — leaving for a later pass",flush=True)
            st=load_status(); st.setdefault("failed",[]).append(f"{z}: {str(e)[:80]}"); save_status(st)
            continue
        st=load_status(); st["done"].append(z)
        st["log"].append(f"{z} done {time.time()-t0:.0f}s @ {datetime.datetime.now().isoformat(timespec='seconds')}")
        save_status(st)
        print(f"ZONE {z} DONE ({time.time()-t0:.0f}s) [{len(st['done'])}/{len(PRIORITY)}]",flush=True)
    print("FETCH_NEW_DONE",flush=True)

if __name__=="__main__":
    main()
