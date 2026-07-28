#!/usr/bin/env python3
# Score a cv25 A/B window CSV (arm,zone,day,hour_utc,price) vs realized ENTSO-E Day-ahead.
import duckdb, numpy as np, pandas as pd, sys
DDB='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
csv=sys.argv[1]; label=sys.argv[2] if len(sys.argv)>2 else csv
c=duckdb.connect(DDB, read_only=True); c.execute("SET TimeZone='UTC'")
s=c.execute("""select map_code as zone, date_trunc('hour',date_time_utc) as hh, avg(price_currency_mwh) as settled
 from entsoe.energy_prices where contract_type='Day-ahead'
 and map_code in ('IT-NORTH','IT-CNORTH','IT-CSOUTH','IT-SOUTH','IT-Calabria','IT-Sicily','IT-Sardinia','CH','FR','AT','SI')
 group by 1,2""").df().rename(columns={'hh':'h'})
s['h']=pd.to_datetime(s['h'])
df=pd.read_csv(csv)
df['h']=pd.to_datetime(df['hour_utc'],format='%Y%m%d-%H%M')
m=df.merge(s,on=['zone','h'])
zones=['IT-NORTH','IT-CNORTH','IT-CSOUTH','IT-SOUTH','IT-Calabria','IT-Sicily','IT-Sardinia','CH','FR','AT','SI']
def st(g):
    r=g.price-g.settled
    cc=np.corrcoef(g.price,g.settled)[0,1] if len(g)>3 and g.price.std()>0 else np.nan
    return len(g),cc,r.abs().mean(),r.mean()
print(f"=== {label} ===")
print(f"{'zone':12s} {'n':>4s} | {'base corr/MAE/bias':>22s} | {'cv25 corr/MAE/bias':>22s} | {'dCORR':>6s} {'dMAE':>6s}")
itb=[];itt=[]
for z in zones:
    gb=m[(m.zone==z)&(m.arm=='base')]; gt=m[(m.zone==z)&(m.arm=='treat')]
    if len(gb)<10 or len(gt)<10:
        print(f"{z:12s}  base={len(gb)} treat={len(gt)} (insufficient)"); continue
    nb,cb,mb,bb=st(gb); nt,ct,mt,bt=st(gt)
    flag=""
    if z=='IT-NORTH': flag=" <<< target"
    print(f"{z:12s} {nb:>4d} | {cb:6.3f}/{mb:5.1f}/{bb:+6.1f}    | {ct:6.3f}/{mt:5.1f}/{bt:+6.1f}    | {ct-cb:+.3f} {mt-mb:+5.1f}{flag}")
    if z.startswith('IT-'): itb.append((mb,cb)); itt.append((mt,ct))
if itb:
    print(f"{'IT-agg MAE':12s}      | base {np.mean([x[0] for x in itb]):5.2f}            | cv25 {np.mean([x[0] for x in itt]):5.2f}            | dMAE {np.mean([x[0] for x in itt])-np.mean([x[0] for x in itb]):+5.2f}")
# evening bias (17-20 UTC) IT-NORTH
for arm in ['base','treat']:
    g=m[(m.zone=='IT-NORTH')&(m.arm==arm)&(m.h.dt.hour.between(16,19))]
    print(f"IT-NORTH evening(16-19UTC) {arm}: bias {(g.price-g.settled).mean():+.1f}")
# midday bias (8-13 UTC) IT-NORTH — the degradation lobe
for arm in ['base','treat']:
    g=m[(m.zone=='IT-NORTH')&(m.arm==arm)&(m.h.dt.hour.between(8,13))]
    print(f"IT-NORTH midday(8-13UTC) {arm}: bias {(g.price-g.settled).mean():+.1f}")
