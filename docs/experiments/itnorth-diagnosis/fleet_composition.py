import duckdb
DDB='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
c=duckdb.connect(DDB, read_only=True); c.execute("SET TimeZone='UTC'")
# Actual generation by type, IT-NORTH, evening peak (UTC 16-19) vs midday (10-13), 2025
for lbl,lo,hi in [("midday",10,13),("evening",16,19)]:
    rows=c.execute(f"""
    select production_type, avg(actual_generation_output_mw) mw
    from entsoe.aggregated_generation_per_type
    where area_map_code='IT-NORTH' and extract(year from date_time_utc)=2025
      and extract(hour from date_time_utc) between {lo} and {hi}
    group by 1 order by 2 desc
    """).fetchall()
    print(f"\n=== IT-NORTH 2025 {lbl} (UTC {lo}-{hi}) avg output by type ===")
    for pt,mw in rows:
        if mw and mw>50: print(f"  {pt:35s} {mw:7.0f}")
# Installed capacity of hydro reservoir + pumped storage in registry
print("\n=== IT-NORTH registry installed capacity by fuel (hydro/storage/gas) ===")
reg=c.execute("""
select fuel_type_code, count(*), sum(installed_capacity_mw) mw
from entsoe.production_and_generation_units
where area_map_code='IT-NORTH' and installed_capacity_mw < 25000
group by 1 order by 3 desc
""").fetchall()
for ft,n,mw in reg:
    if mw and mw>100: print(f"  {ft:35s} n={n:4d} {mw:8.0f} MW")
