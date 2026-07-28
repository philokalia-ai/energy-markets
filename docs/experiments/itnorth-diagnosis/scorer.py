#!/usr/bin/env python3
# Score IT-NORTH A/B arms vs realized ENTSO-E Day-ahead prices.
# Usage: scorer.py ab_base.csv ab_backstop.csv
import duckdb, numpy as np, pandas as pd, sys
DDB='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
base_csv, treat_csv = sys.argv[1], sys.argv[2]
c=duckdb.connect(DDB, read_only=True); c.execute("SET TimeZone='UTC'")
# settled hourly UTC
c.execute("""create temp table settled as
 select map_code zone, date_trunc('hour',date_time_utc) h, avg(price_currency_mwh) settled
 from entsoe.energy_prices where contract_type='Day-ahead'
 and map_code in ('IT-NORTH','IT-CNORTH','IT-CSOUTH','IT-SOUTH','IT-Calabria','IT-Sicily','IT-Sardinia','CH','FR','AT','SI')
 group by 1,2""")
def load(path,lbl):
    df=pd.read_csv(path)
    # ts key 'yyyymmdd-HHMM' is UTC (built from date_time_utc)
    df['h']=pd.to_datetime(df['hour_utc'],format='%Y%m%d-%H%M',utc=True).dt.tz_localize(None)
    df['arm']=lbl
    return df[['arm','zone','h','price']]
b=load(base_csv,'base'); t=load(treat_csv,'treat')
allm=pd.concat([b,t])
s=c.execute("select * from settled").df()
s['h']=pd.to_datetime(s['h'])
m=allm.merge(s,on=['zone','h'])
m['month']=m.h.dt.month
m['season']=np.where(m.month.isin([6,7,8]),'summer','winter')
def stat(g):
    r=g.price-g.settled
    corr=np.corrcoef(g.price,g.settled)[0,1] if len(g)>3 and g.price.std()>0 else np.nan
    return pd.Series({'n':len(g),'corr':corr,'MAE':r.abs().mean(),'bias':r.mean()})
print("=== per zone x season x arm ===")
for sea in ['summer','winter']:
    print(f"\n--- {sea} ---")
    print(f"{'zone':12s} {'base corr/MAE/bias':>26s}   {'treat corr/MAE/bias':>26s}   {'dCORR':>6s} {'dMAE':>6s}")
    for z in ['IT-NORTH','IT-CNORTH','IT-CSOUTH','IT-SOUTH','IT-Calabria','IT-Sicily','IT-Sardinia','CH','FR','AT','SI']:
        gb=m[(m.zone==z)&(m.season==sea)&(m.arm=='base')]
        gt=m[(m.zone==z)&(m.season==sea)&(m.arm=='treat')]
        if len(gb)<10 or len(gt)<10:
            print(f"{z:12s}  (insufficient: base={len(gb)} treat={len(gt)})"); continue
        sb=stat(gb); st=stat(gt)
        print(f"{z:12s} {sb['corr']:.3f}/{sb['MAE']:5.1f}/{sb['bias']:+6.1f}      {st['corr']:.3f}/{st['MAE']:5.1f}/{st['bias']:+6.1f}      {st['corr']-sb['corr']:+.3f} {st['MAE']-sb['MAE']:+5.1f}")
# IT aggregate
print("\n=== IT aggregate (mean over 7 IT zones) MAE by season/arm ===")
for sea in ['summer','winter']:
    for arm in ['base','treat']:
        g=m[(m.zone.str.startswith('IT-'))&(m.season==sea)&(m.arm==arm)]
        r=(g.price-g.settled)
        print(f"{sea} {arm}: MAE={r.abs().mean():.2f} bias={r.mean():+.2f} n={len(g)}")
