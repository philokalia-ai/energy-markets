#!/usr/bin/env python3
# Fetch honest GFS gfs_seamless previous_day1 vintages for RES cells + load cities.
# Per-timestamp previous_day1 semantics = the run issued D-1 (ex-ante at D-1 gate).
# Batched <=50 locations/call, time-chunked ~6mo, resumable (skips written chunks).
import json, time, os, sys, urllib.request, urllib.parse
import pandas as pd, numpy as np

SP = "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
OUT = os.path.join(SP, "gfs"); os.makedirs(OUT, exist_ok=True)
PREV = "https://previous-runs-api.open-meteo.com/v1/forecast"
UA = {"User-Agent": "philokalia-energy/1.0 (contact: pankgeorg@gmail.com)"}
START, END = "2024-07-14", "2026-07-27"
# ~6-month chunks
CHUNKS = [("2024-07-14","2024-12-31"),("2025-01-01","2025-06-30"),
          ("2025-07-01","2025-12-31"),("2026-01-01","2026-07-27")]
RES_VARS  = ["wind_speed_100m","shortwave_radiation","cloud_cover","surface_pressure"]
LOAD_VARS = ["temperature_2m","shortwave_radiation"]

geom = json.load(open(os.path.join(SP,"geom.json")))

def build_points():
    res, load = [], []
    for z,g in geom.items():
        for i,c in enumerate(g["cells"]):
            res.append((f"{z}#c{i}", z, float(c[0]), float(c[1])))
        for i,c in enumerate(g["cities"]):
            load.append((f"{z}#l{i}", z, float(c[0]), float(c[1]), float(c[2])))
    return res, load

def get(params, tries=7):
    q = PREV + "?" + urllib.parse.urlencode(params, safe=",")
    for i in range(tries):
        try:
            req = urllib.request.Request(q, headers=UA)
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.loads(r.read())
        except Exception as e:
            code = getattr(e,'code',None)
            wait = 25*(0.75+0.5*np.random.rand()) if code==429 else 4*(i+1)
            print(f"  retry {i+1} ({e}) wait {wait:.0f}s", flush=True); time.sleep(wait)
    raise RuntimeError("failed "+q[:160])

def fetch_kind(kind, points, base_vars):
    vsfx = [v+"_previous_day1" for v in base_vars]
    for ci,(d0,d1) in enumerate(CHUNKS):
        for bi in range(0, len(points), 50):
            batch = points[bi:bi+50]
            fn = os.path.join(OUT, f"{kind}_ch{ci}_b{bi}.parquet")
            if os.path.exists(fn):
                print(f"  {os.path.basename(fn)} cached", flush=True); continue
            lats = ",".join(str(p[2]) for p in batch)
            lons = ",".join(str(p[3]) for p in batch)
            params = {"latitude":lats,"longitude":lons,"hourly":",".join(vsfx),
                      "models":"gfs_seamless","start_date":d0,"end_date":d1,"timezone":"UTC"}
            d = get(params)
            locs = d if isinstance(d,list) else [d]
            assert len(locs)==len(batch), f"{len(locs)} vs {len(batch)}"
            rows=[]
            for p,loc in zip(batch,locs):
                h=loc["hourly"]; t=h["time"]
                rec={"loc_id":p[0],"zone":p[1],"h":t}
                for bv,sv in zip(base_vars,vsfx):
                    rec[bv]=h.get(sv,[None]*len(t))
                df=pd.DataFrame(rec)
                rows.append(df)
            out=pd.concat(rows,ignore_index=True)
            out["h"]=pd.to_datetime(out["h"])
            out.to_parquet(fn)
            print(f"  wrote {os.path.basename(fn)} rows={len(out)}", flush=True)
            time.sleep(1.2)

res, load = build_points()
print(f"RES points={len(res)} LOAD points={len(load)}", flush=True)
stage = sys.argv[1] if len(sys.argv)>1 else "all"
if stage in ("all","res"):  fetch_kind("res", res, RES_VARS)
if stage in ("all","load"): fetch_kind("load", load, LOAD_VARS)
print("FETCH_DONE", flush=True)
