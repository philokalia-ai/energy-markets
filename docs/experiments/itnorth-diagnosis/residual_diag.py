import duckdb, numpy as np, sys
DDB='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
MODEL='/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/cv23_model.csv'
c=duckdb.connect(DDB, read_only=True)
c.execute("SET TimeZone='UTC'")
c.execute("""
create temp table settled as
select map_code as zone, date_trunc('hour', date_time_utc) as h_utc,
       avg(price_currency_mwh) as settled
from entsoe.energy_prices
where contract_type='Day-ahead' and map_code like 'IT-%'
group by 1,2;
""")
c.execute(f"""
create temp table model as
select bidding_zone as zone,
       date_trunc('hour', (h::timestamptz at time zone 'UTC')) as h_utc,
       price_eur_mwh as model
from read_csv_auto('{MODEL}', header=true)
where bidding_zone like 'IT-%';
""")
df = c.execute("""
select m.zone, m.h_utc, m.model, s.settled, m.model - s.settled as resid
from model m join settled s on m.zone=s.zone and m.h_utc=s.h_utc
where s.settled is not null
""").df()
df['year']=df.h_utc.dt.year
df['month']=df.h_utc.dt.month
df['hour']=df.h_utc.dt.hour
df['season']=df.month.map(lambda m:'DJF' if m in(12,1,2) else 'MAM' if m in(3,4,5) else 'JJA' if m in(6,7,8) else 'SON')
def corr(a,b):
    if len(a)<3: return np.nan
    return np.corrcoef(a,b)[0,1]
def stats(g):
    return {'n':len(g),'MAE':g.resid.abs().mean(),'bias':g.resid.mean(),'corr':corr(g.model,g.settled),'settled_mean':g.settled.mean(),'model_mean':g.model.mean()}
print("=== IT-NORTH by year ===")
itn=df[df.zone=='IT-NORTH']
for y in sorted(itn.year.unique()):
    g=itn[itn.year==y]; s=stats(g)
    print(f"{y}: n={s['n']:5d} corr={s['corr']:.3f} MAE={s['MAE']:5.1f} bias={s['bias']:+6.1f} settled_mean={s['settled_mean']:6.1f} model_mean={s['model_mean']:6.1f}")
print("\n=== IT-NORTH by year x season ===")
for y in sorted(itn.year.unique()):
    for sea in ['DJF','MAM','JJA','SON']:
        g=itn[(itn.year==y)&(itn.season==sea)]
        if len(g)<20: continue
        s=stats(g)
        print(f"{y} {sea}: n={s['n']:5d} corr={s['corr']:.3f} MAE={s['MAE']:5.1f} bias={s['bias']:+6.1f} sett={s['settled_mean']:6.1f} mod={s['model_mean']:6.1f}")
print("\n=== IT-NORTH bias by hour-of-day (UTC), per year ===")
years=sorted(itn.year.unique())
print("hour  "+" ".join(f"  {y}" for y in years))
for hr in range(24):
    row=[]
    for y in years:
        g=itn[(itn.year==y)&(itn.hour==hr)]
        row.append(f"{g.resid.mean():+6.1f}" if len(g)>5 else "   -  ")
    print(f"{hr:2d}h  "+" ".join(row))
print("\n=== IT family by year (corr) ===")
for z in ['IT-NORTH','IT-CNORTH','IT-CSOUTH','IT-SOUTH','IT-Calabria','IT-Sicily','IT-Sardinia']:
    zz=df[df.zone==z]
    line=f"{z:12s}"
    for y in years:
        g=zz[zz.year==y]
        line+=f" {corr(g.model,g.settled):.2f}/{g.resid.abs().mean():4.1f}" if len(g)>20 else "   -   "
    print(line)
