import duckdb
DDB='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
c=duckdb.connect(DDB, read_only=True); c.execute("SET TimeZone='UTC'")
# Forecast solar (D-1, what model uses) hourly avg, IT-NORTH, midday UTC 10-13
fc=c.execute("""
select extract(year from date_time_utc) yr, avg(day_ahead_generation_forecast_mw) fc_solar
from entsoe.generation_forecasts_for_wind_and_solar
where area_map_code='IT-NORTH' and production_type='Solar'
  and area_type_code in ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
  and extract(hour from date_time_utc) between 10 and 13
group by 1 order by 1
""").fetchall()
# Actual solar output hourly avg, IT-NORTH, midday UTC 10-13
ac=c.execute("""
select extract(year from date_time_utc) yr, avg(actual_generation_output_mw) act_solar
from entsoe.aggregated_generation_per_type
where area_map_code='IT-NORTH' and production_type='Solar'
  and extract(hour from date_time_utc) between 10 and 13
group by 1 order by 1
""").fetchall()
fcd=dict(fc); acd=dict(ac)
print("IT-NORTH midday (UTC 10-13) solar, MW avg:")
print(f"{'yr':>5} {'D-1 forecast':>13} {'actual':>10} {'act-fc':>8}")
for yr in sorted(set(fcd)|set(acd)):
    f=fcd.get(yr); a=acd.get(yr)
    print(f"{int(yr):>5} {f:>13.0f} {a:>10.0f} {a-f:>8.0f}" if f and a else f"{int(yr):>5} {f} {a}")
# Also: how much does model's net-demand-at-midday differ. Actual total load and solar share.
print("\nIT-NORTH midday solar as % of settled-price-relevant load (actual total load):")
ld=c.execute("""
select extract(year from date_time_utc) yr, avg(actual_total_load_mw) load
from entsoe.actual_total_load where area_map_code='IT-NORTH'
  and extract(hour from date_time_utc) between 10 and 13 group by 1 order by 1
""").fetchall()
ldd=dict(ld)
for yr in sorted(acd):
    a=acd.get(yr); l=ldd.get(yr)
    if a and l: print(f"{int(yr)}: solar {a:.0f} / load {l:.0f} = {100*a/l:.1f}%")
