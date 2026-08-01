#!/usr/bin/env python3
"""Build the 39-zone geom.json (rollout-39) from the committed packs + decide
solar/wind presence per zone (amendment 2). cells<-res_models_v2, cities<-load_models_v1.
Solar/wind skip decision: a target is MODELED if the trailing p95 of actual per-type
generation reaches a meaningful level, else skip (pack/zero passthrough)."""
import json, duckdb, numpy as np
BIN="/home/pgeorgakopoulos/armada/energy-markets/bin"
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
EXT="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
RESP=json.load(open(f"{BIN}/res_models_v2.json"))["zones"]
LOADP=json.load(open(f"{BIN}/load_models_v1.json"))["zones"]
con=duckdb.connect(EXT, read_only=True)

# peak actual generation per zone/type (p99 of hourly mean, whole history) as the
# installed-scale signal; also peak load for context.
gen=con.execute("""
 SELECT area_map_code AS zone,
   CASE WHEN production_type='Solar' THEN 'solar'
        WHEN production_type LIKE 'Wind%' THEN 'wind' END AS pt,
   quantile_cont(mw,0.999) AS peak
 FROM (SELECT area_map_code, production_type, date_trunc('hour',date_time_utc) t,
              avg(actual_generation_output_mw) mw
       FROM entsoe.aggregated_generation_per_type
       WHERE (production_type='Solar' OR production_type LIKE 'Wind%')
         AND actual_generation_output_mw IS NOT NULL GROUP BY 1,2,3)
 GROUP BY 1,2""").df()
peak={}
for _,r in gen.iterrows():
    if r.pt: peak[(r.zone,r.pt)]=float(r.peak)
loadpk=con.execute("""SELECT area_map_code AS zone, quantile_cont(mw,0.99) AS pk FROM
  (SELECT area_map_code, date_trunc('hour',date_time_utc) AS t, avg(total_load_mw) AS mw
   FROM entsoe.day_ahead_total_load_forecast WHERE area_type_code LIKE 'BZN%'
     AND total_load_mw IS NOT NULL GROUP BY 1,2) GROUP BY 1""").df()
lpk={r.zone:float(r.pk) for _,r in loadpk.iterrows()}

# DA-forecast TARGET peaks (what we actually predict/score) — the principled skip
# signal; robust to under-reported actual generation (e.g. NL behind-the-meter solar).
fc=con.execute("""SELECT area_map_code AS zone,
   CASE WHEN production_type='Solar' THEN 'solar'
        WHEN production_type LIKE 'Wind%' THEN 'wind' END AS pt,
   quantile_cont(mw,0.999) AS peak FROM
  (SELECT area_map_code, production_type, date_trunc('hour',date_time_utc) AS t,
          avg(day_ahead_generation_forecast_mw) AS mw
   FROM entsoe.generation_forecasts_for_wind_and_solar
   WHERE (production_type='Solar' OR production_type LIKE 'Wind%')
     AND day_ahead_generation_forecast_mw IS NOT NULL AND area_type_code LIKE 'BZN%'
   GROUP BY 1,2,3) GROUP BY 1,2""").df()
fpk={}
for _,r in fc.iterrows():
    if r.pt: fpk[(r.zone,r.pt)]=float(r.peak)

ZONES=sorted(set(RESP)&set(LOADP))
# thresholds: model a RES target if peak >= max(150 MW, 3% of peak load)
geom={}; decisions=[]
for z in ZONES:
    rz=RESP[z]; lz=LOADP[z]
    # skip signal = max(actual-gen peak, DA-forecast-target peak) per type
    ps=max(peak.get((z,"solar"),0.0), fpk.get((z,"solar"),0.0))
    pw=max(peak.get((z,"wind"),0.0),  fpk.get((z,"wind"),0.0))
    pl=lpk.get(z,0.0)
    thr=max(150.0, 0.03*pl)
    has_solar = ps>=thr and rz.get("solar") is not None
    has_wind  = pw>=thr and rz.get("wind")  is not None
    geom[z]={"cells":rz["cells"],"cities":lz["cities"],
             "wind":bool(has_wind),"solar":bool(has_solar),
             "cdh_base":float(lz.get("cdh_base",21.0)),
             "holiday_country":lz.get("holiday_country","")}
    decisions.append((z,round(ps),round(pw),round(pl),round(thr),has_solar,has_wind,
                      len(rz["cells"]),len(lz["cities"])))
json.dump(geom,open(f"{SP}/geom39.json","w"))
print(f"{'zone':10s}{'p_sol':>7}{'p_wnd':>7}{'p_load':>8}{'thr':>7}  solar wind  ncell ncity")
for d in decisions:
    print(f"{d[0]:10s}{d[1]:>7}{d[2]:>7}{d[3]:>8}{d[4]:>7}  {str(d[5]):5s} {str(d[6]):5s} {d[7]:>5} {d[8]:>5}")
print("nzones",len(ZONES))
