import duckdb
EXTRACT='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
CSV='/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/cv23_model.csv'
con=duckdb.connect(EXTRACT, read_only=True); con.execute("SET TimeZone='UTC'")
con.execute(f"""create temp table model as select bidding_zone as zn,(h::timestamptz at time zone 'UTC') ts_utc, price_eur_mwh model
from read_csv_auto('{CSV}',header=true)""")
con.execute("""create temp table settled as select map_code as zn, date_trunc('hour',date_time_utc) ts_utc, avg(price_currency_mwh) settled
from entsoe.energy_prices where contract_type='Day-ahead' and currency='EUR' group by 1,2""")
con.execute("""create temp table j as select m.zn as zone,m.ts_utc,m.model,s.settled,
extract(year from m.ts_utc) yr, extract(hour from m.ts_utc) hr from model m join settled s on m.zn=s.zn and m.ts_utc=s.ts_utc""")

print("Neighbours: EVENING (h16-19 UTC) and MIDDAY (h10-12) bias/corr, all years pooled")
print(f"{'zone':10s} {'even_n':>6} {'even_bias':>9} {'even_MAE':>8} {'even_corr':>9} | {'mid_bias':>8} {'day_corr':>8}")
for z in ['PL','DE_LU','CZ','SK','SE4','LT','FR','GR']:
    e=con.execute(f"select count(*),avg(model-settled),avg(abs(model-settled)),corr(model,settled) from j where zone='{z}' and hr in (16,17,18,19)").fetchone()
    mid=con.execute(f"select avg(model-settled) from j where zone='{z}' and hr in (10,11,12)").fetchone()
    dc=con.execute(f"select corr(model,settled) from j where zone='{z}'").fetchone()
    if e[0] and e[0]>0:
        print(f"{z:10s} {e[0]:6d} {e[1]:+9.2f} {e[2]:8.2f} {e[3] or 0:9.3f} | {mid[0] or 0:+8.2f} {dc[0] or 0:8.3f}")

# PL net position at evening in reality: physical flows sign. Is PL importing at evening peak?
print("\nPL physical net imports (MW, +=import) by hour UTC, 2024-2025 avg:")
r=con.execute("""select extract(hour from date_time_utc) hr, avg(
  (select coalesce(sum(f2.flow_mw),0) from entsoe.physical_flows f2 where f2.in_map_code='PL' and f2.date_time_utc=f.date_time_utc)
 -(select coalesce(sum(f3.flow_mw),0) from entsoe.physical_flows f3 where f3.out_map_code='PL' and f3.date_time_utc=f.date_time_utc)
) net from (select distinct date_time_utc from entsoe.physical_flows where date_time_utc>=timestamp '2024-01-01' and date_time_utc<timestamp '2025-01-01') f group by 1 order by 1""").fetchall() if False else None
# simpler net import query
try:
    r=con.execute("""
    with imp as (select date_time_utc, sum(flow_mw) v from entsoe.physical_flows where in_map_code='PL' group by 1),
         exp as (select date_time_utc, sum(flow_mw) v from entsoe.physical_flows where out_map_code='PL' group by 1)
    select extract(hour from imp.date_time_utc) hr, avg(imp.v - coalesce(exp.v,0)) net
    from imp left join exp using(date_time_utc)
    where imp.date_time_utc>=timestamp '2024-06-01' and imp.date_time_utc<timestamp '2025-06-01'
    group by 1 order by 1""").fetchall()
    for hr,net in r:
        if hr in (2,5,10,12,17,18,20): print(f"  h{int(hr):02d}: net_import={net:+8.0f} MW")
except Exception as ex:
    print("flow query failed:", ex)
