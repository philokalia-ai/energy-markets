import duckdb
EXTRACT='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
con=duckdb.connect(EXTRACT, read_only=True); con.execute("SET TimeZone='UTC'")
# PL net imports by hour (physical flows), 2024-06..2025-06
r=con.execute("""
with imp as (select date_time_utc, sum(flow_mw) v from entsoe.physical_flows where in_area_map_code='PL' group by 1),
     exp as (select date_time_utc, sum(flow_mw) v from entsoe.physical_flows where out_area_map_code='PL' group by 1)
select extract(hour from imp.date_time_utc) hr, avg(imp.v - coalesce(exp.v,0)) net
from imp left join exp using(date_time_utc)
where imp.date_time_utc>=timestamp '2024-06-01' and imp.date_time_utc<timestamp '2025-06-01'
group by 1 order by 1""").fetchall()
print("PL physical net import (MW, +=import) by UTC hour (2024-06..2025-06):")
for hr,net in r:
    if int(hr) in (2,5,8,10,12,15,17,18,20,22): print(f"  h{int(hr):02d}: {net:+8.0f}")

# PL settled minus DE_LU settled by hour (coupling / congestion signature)
r=con.execute("""
with p as (select date_trunc('hour',date_time_utc) t, avg(price_currency_mwh) v from entsoe.energy_prices where map_code='PL' and contract_type='Day-ahead' and currency='EUR' group by 1),
     d as (select date_trunc('hour',date_time_utc) t, avg(price_currency_mwh) v from entsoe.energy_prices where map_code='DE_LU' and contract_type='Day-ahead' and currency='EUR' group by 1)
select extract(hour from p.t) hr, avg(p.v-d.v) spread, avg(p.v) pl, avg(d.v) de
from p join d using(t) group by 1 order by 1""").fetchall()
print("\nSettled PL - DE_LU spread by UTC hour (all data). PL evening premium over DE = congestion/scarcity/conduct:")
for hr,sp,pl,de in r:
    if int(hr) in (2,5,8,10,12,15,17,18,20,22): print(f"  h{int(hr):02d}: PL-DE={sp:+7.2f}  (PL={pl:6.2f} DE={de:6.2f})")
