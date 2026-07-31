#!/usr/bin/env python3
"""Collapse hit/false-alarm metrics (SCIENTIST.md first-class) at PRICE level.
Ground truth = settled DA prices. Classify collapse (<=EUR5) and negative (<0)
per zone-hour; compare each arm (ref/base/new) confusion vs settled.
Also midday MAE-vs-settled per arm."""
import json, duckdb, numpy as np, pandas as pd
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
EXT="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
PILOTS=["GR","ES","DE_LU","SE2","NL"]
hr=json.load(open(f"{SP}/price_hourly.json"))
# settled hourly (naive UTC hour)
con=duckdb.connect(EXT,read_only=True)
s=con.execute(f"""SELECT map_code z, date_trunc('hour',date_time_utc) h, avg(price_currency_mwh) p
 FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
 AND price_currency_mwh IS NOT NULL AND map_code IN ({','.join(chr(39)+z+chr(39) for z in PILOTS)})
 AND date_time_utc>=TIMESTAMP '2026-07-24' AND date_time_utc<TIMESTAMP '2026-07-28'
 GROUP BY 1,2""").df()
settled={(r.z, pd.Timestamp(r.h).strftime("%Y%m%d-%H%M")):r.p for r in s.itertuples()}

rows=[]  # long: zone,ts,settled,ref,base,new
for rec in hr:
    z=rec["zone"]
    for ts,sp in rec["ref"].items():
        key=(z,ts); st=settled.get(key)
        if st is None: continue
        rows.append(dict(zone=z,ts=ts,settled=st,ref=rec["ref"].get(ts),
                         base=rec["base"].get(ts),new=rec["new"].get(ts)))
df=pd.DataFrame(rows)

def confusion(pred,truth,thr):
    pt=pred<=thr; tt=truth<=thr
    hit=int((pt&tt).sum()); miss=int((~pt&tt).sum()); fa=int((pt&~tt).sum())
    hr_=hit/max(hit+miss,1); far=fa/max((pred>thr).sum()+fa,1)
    return dict(pos_truth=int(tt.sum()),pred_pos=int(pt.sum()),hit=hit,miss=miss,
                false_alarm=fa,hit_rate=round(hr_,3),false_alarm_rate=round(far,3))

print("="*70)
print("COLLAPSE CLASSIFICATION vs settled (all pilot zone-hours, 07-24..27)")
for label,thr in [("<=EUR5",5.0),("<0 (negative)",0.0)]:
    print(f"\n-- threshold {label}: settled positives = {int((df.settled<=thr).sum())}/{len(df)} --")
    for arm in ["ref","base","new"]:
        c=confusion(df[arm].values,df.settled.values,thr)
        print(f"  {arm:5s} predP={c['pred_pos']:3d} hit={c['hit']:3d} miss={c['miss']:3d} "
              f"FA={c['false_alarm']:3d} hit_rate={c['hit_rate']} FA_rate={c['false_alarm_rate']}")

print("\n"+"="*70)
print("PER-ZONE all-hour MAE vs settled + collapse(<=5) confusion")
for z in PILOTS:
    d=df[df.zone==z]
    print(f"\n{z} (n={len(d)} hrs):")
    for arm in ["ref","base","new"]:
        mae=np.mean(np.abs(d[arm]-d.settled))
        c=confusion(d[arm].values,d.settled.values,5.0)
        print(f"  {arm:5s} MAE={mae:6.1f}  collapse: settledP={c['pos_truth']} predP={c['pred_pos']} "
              f"hit={c['hit']} FA={c['false_alarm']}")
df.to_parquet(f"{SP}/price_hourly_long.parquet")
print("\nCOLLAPSE_DONE")
