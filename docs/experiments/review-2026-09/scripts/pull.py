import os, psycopg2, pandas as pd, numpy as np, sys
c = psycopg2.connect(os.environ['ENERGY_CONN_STR'])
def q(sql): return pd.read_sql(sql, c)
cov = q("""SELECT code_version, clearing_mode, count(*) n, count(distinct bidding_zone) nz,
  min(date_time_utc) d0, max(date_time_utc) d1, count(distinct date_time_utc::date) nd
  FROM simulations.energy_prices WHERE code_version=37 AND order_method='merit_order'
  GROUP BY 1,2 ORDER BY 1,2""")
print(cov.to_string())
sim = q("""SELECT bidding_zone z, date_trunc('hour', date_time_utc) h, avg(price_eur_mwh) sim
  FROM simulations.energy_prices WHERE code_version=37 AND clearing_mode='multi_zone_eu' AND order_method='merit_order'
  GROUP BY 1,2""")
print('sim rows', len(sim), sim.h.min(), sim.h.max())
zones = tuple(sim.z.unique())
act = q(f"""SELECT map_code z, date_trunc('hour', date_time_utc) h, avg(price_currency_mwh) act
  FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND map_code IN {zones}
  AND date_time_utc >= '{sim.h.min()}' AND date_time_utc <= '{sim.h.max()}' GROUP BY 1,2""")
print('act rows', len(act))
ld = q(f"""SELECT area_map_code z, date_trunc('hour', date_time_utc) h, avg(total_load_mw) load
  FROM entsoe.actual_total_load WHERE area_type_code LIKE 'BZN%%' AND area_map_code IN {zones}
  AND date_time_utc >= '{sim.h.min()}' AND date_time_utc <= '{sim.h.max()}' GROUP BY 1,2""")
print('load rows', len(ld))
for d in (sim,act,ld): d["h"]=pd.to_datetime(d["h"], utc=True).dt.tz_localize(None)
df = sim.merge(act, on=['z','h'], how='inner').merge(ld, on=['z','h'], how='left')
print('joined', len(df), df.z.nunique(), df.h.dt.date.nunique())
df.to_parquet(os.environ['S']+'/cv37_joined.parquet')
