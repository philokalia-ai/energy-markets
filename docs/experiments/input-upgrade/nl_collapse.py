import json,duckdb,numpy as np,pandas as pd
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
EXT="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
hr=json.load(open(f"{SP}/nlwind_hourly.json"))
con=duckdb.connect(EXT,read_only=True)
s=con.execute("""SELECT date_trunc('hour',date_time_utc) h, avg(price_currency_mwh) p
 FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
 AND map_code='NL' AND price_currency_mwh IS NOT NULL
 AND date_time_utc>=TIMESTAMP '2026-07-24' AND date_time_utc<TIMESTAMP '2026-07-28' GROUP BY 1""").df()
settled={pd.Timestamp(r.h).strftime("%Y%m%d-%H%M"):r.p for r in s.itertuples()}
rows=[]
for rec in hr:
    for ts,sp in rec["ref"].items():
        st=settled.get(ts)
        if st is None: continue
        rows.append(dict(ts=ts,settled=st,ref=sp,base=rec["base"].get(ts),new=rec["new"].get(ts)))
df=pd.DataFrame(rows)
def conf(pred,truth,thr):
    pt=pred<=thr; tt=truth<=thr
    return int((pt&tt).sum()),int((~pt&tt).sum()),int((pt&~tt).sum()),int(pt.sum())
print(f"NL new-wind panel, n={len(df)} hrs")
for arm in ["ref","base","new"]:
    mae=np.mean(np.abs(df[arm]-df.settled))
    h5,m5,fa5,p5=conf(df[arm].values,df.settled.values,5.0)
    hn,mn,fan,pn=conf(df[arm].values,df.settled.values,0.0)
    print(f"  {arm:5s} MAE={mae:6.1f}  <=5: settledP={int((df.settled<=5).sum())} predP={p5} hit={h5} FA={fa5} | <0: predP={pn}")
print("NL_COLLAPSE_DONE")
