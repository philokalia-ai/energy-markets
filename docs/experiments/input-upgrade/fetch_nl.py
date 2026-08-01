import json,os,time,urllib.request,urllib.parse,numpy as np,pandas as pd
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
OUT=os.path.join(SP,"gfs");PREV="https://previous-runs-api.open-meteo.com/v1/forecast"
UA={"User-Agent":"philokalia-energy/1.0 (contact: pankgeorg@gmail.com)"}
CHUNKS=[("2024-07-14","2024-12-31"),("2025-01-01","2025-06-30"),("2025-07-01","2025-12-31"),("2026-01-01","2026-07-27")]
geom=json.load(open(SP+"/geom.json"))["NL"]
res=[(f"NL#c{i}",'NL',float(c[0]),float(c[1])) for i,c in enumerate(geom["cells"])]
load=[(f"NL#l{i}",'NL',float(c[0]),float(c[1]),float(c[2])) for i,c in enumerate(geom["cities"])]
def get(p,t=7):
    q=PREV+"?"+urllib.parse.urlencode(p,safe=",")
    for i in range(t):
        try:
            return json.loads(urllib.request.urlopen(urllib.request.Request(q,headers=UA),timeout=180).read())
        except Exception as e:
            w=25*(0.75+0.5*np.random.rand()) if getattr(e,'code',None)==429 else 4*(i+1)
            print("retry",i+1,e,flush=True);time.sleep(w)
    raise RuntimeError("fail")
def fetch(kind,pts,vars):
    vsfx=[v+"_previous_day1" for v in vars]
    for ci,(d0,d1) in enumerate(CHUNKS):
        fn=os.path.join(OUT,f"{kind}_nl_ch{ci}.parquet")
        if os.path.exists(fn): print(fn,"cached",flush=True);continue
        lats=",".join(str(p[2]) for p in pts);lons=",".join(str(p[3]) for p in pts)
        d=get({"latitude":lats,"longitude":lons,"hourly":",".join(vsfx),"models":"gfs_seamless","start_date":d0,"end_date":d1,"timezone":"UTC"})
        locs=d if isinstance(d,list) else [d];rows=[]
        for p,loc in zip(pts,locs):
            h=loc["hourly"];t=h["time"];rec={"loc_id":p[0],"zone":p[1],"h":t}
            for bv,sv in zip(vars,vsfx): rec[bv]=h.get(sv,[None]*len(t))
            rows.append(pd.DataFrame(rec))
        o=pd.concat(rows,ignore_index=True);o["h"]=pd.to_datetime(o["h"]);o.to_parquet(fn)
        print("wrote",fn,len(o),flush=True);time.sleep(1.2)
fetch("res",res,["wind_speed_100m","shortwave_radiation","cloud_cover","surface_pressure"])
fetch("load",load,["temperature_2m","shortwave_radiation"])
print("NL_FETCH_DONE",flush=True)
