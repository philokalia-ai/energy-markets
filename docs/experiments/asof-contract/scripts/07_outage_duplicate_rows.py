# Duplicate (instance_code, version) rows in the ENTSO-E outage tables: one
# row per time-series interval of a message. The readers' ROW_NUMBER() ...
# ORDER BY version DESC has no tie-breaker, so rn = 1 is an arbitrary
# interval -> nondeterministic available capacity / NTC per process.
import os, psycopg2
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor(); cur.execute("set statement_timeout='600s'")
q = lambda s: (cur.execute(s), cur.fetchall())[1]
for day in ("2026-08-20", "2025-08-20"):
    print(f"## generation outages touching {day}: groups, dup groups, dup groups disagreeing on capacity, on times, on status")
    print(q(f"""with t as (select instance_code, version, count(*) n, count(distinct coalesce(available_capacity_mw,-1)) nv,
         count(distinct start_outage_utc||'|'||end_outage_utc) nt, count(distinct status) ns
         from entsoe.unavailability_of_production_and_generation_units
         where start_outage_utc < '{day}'::date + 1 and end_outage_utc > '{day}' group by 1,2)
       select count(*), count(*) filter (where n>1), count(*) filter (where nv>1), count(*) filter (where nt>1), count(*) filter (where ns>1) from t"""))
print("## transmission-grid outages touching 2026-08-20: groups, dup groups, dup groups disagreeing on new_ntc_mw")
print(q("""with t as (select instance_code, version, count(*) n, count(distinct coalesce(new_ntc_mw,-1)) nv
     from entsoe.unavailability_in_the_transmission_grid
     where start_outage_utc < '2026-08-21' and end_outage_utc > '2026-08-20' group by 1,2)
   select count(*), count(*) filter (where n>1), count(*) filter (where nv>1) from t"""))
print("## example: one message, its interval rows")
for r in q("""select instance_code, version, available_capacity_mw, start_time_series_utc, end_time_series_utc, start_outage_utc, end_outage_utc
   from entsoe.unavailability_of_production_and_generation_units where instance_code='0DJLlZnIqrsQN7lAOmDEbQ' order by version, start_time_series_utc limit 8"""): print("  ", r)
