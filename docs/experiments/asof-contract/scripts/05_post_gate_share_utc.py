import os, psycopg2
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor(); cur.execute("set statement_timeout='900s'")
def q(s,a=()):
    try: cur.execute(s,a); return cur.fetchall()
    except Exception as e: cx.rollback(); return [("ERR",str(e)[:200])]
print("## session TimeZone:", q("show timezone"), " server:", q("select current_setting('log_timezone')"))
print("## full column types (date_time_utc / update_time_utc / version_publication_timestamp_utc)")
for r in q("""select table_name, column_name, data_type from information_schema.columns where table_schema='entsoe'
   and column_name in ('date_time_utc','update_time_utc','version_publication_timestamp_utc','start_time_series_utc')
   and table_name in ('day_ahead_total_load_forecast','generation_forecasts_for_wind_and_solar','offered_transfer_capacities_implicit',
   'unavailability_of_production_and_generation_units','aggregated_generation_per_type','actual_generation_output_per_generation_unit','aggregated_hydro_storage_filling_rate')
   order by 1,2"""): print("  ",r)
# explicit-UTC gate: delivery UTC-day start − 14h  (= D-1 10:00 UTC; 12:00 CEST. In CET the true gate is 11:00 UTC → we are 1h conservative in winter)
UT  = "(update_time_utc AT TIME ZONE 'UTC')"
DT  = "(date_time_utc AT TIME ZONE 'UTC')"
GATE= f"(date_trunc('day', {DT}) - interval '14 hours')"
W0,W1='2026-06-01','2026-09-01'
print(f"\n## D-1 LOAD FORECAST: per zone, {W0}..{W1}: n, %stored-revision-after-gate, median publication time-of-day UTC of D-1 (only rows updated on D-1), %updated after delivery start")
for r in q(f"""select area_map_code, count(*),
   round(100.0*avg(({UT} > {GATE})::int),1) post_gate,
   to_char(interval '1 second' * percentile_cont(0.5) within group (order by extract(epoch from {UT}::time)) filter (where {UT}::date = {DT}::date - 1), 'HH24:MI') pub_tod_dminus1,
   round(100.0*avg(({UT} >= {DT})::int),1) post_delivery
   from entsoe.day_ahead_total_load_forecast where date_time_utc >= %s and date_time_utc < %s and area_type_code like 'BZN%%'
   group by 1 order by 3 desc""",(W0,W1)): print("  ",r)
print(f"\n## OFFERED ATC (implicit): per out_map_code: n, %post-gate, median update time-of-day on D-1, %post-delivery")
for r in q(f"""select out_map_code, count(*),
   round(100.0*avg(({UT} > {GATE})::int),1),
   to_char(interval '1 second' * percentile_cont(0.5) within group (order by extract(epoch from {UT}::time)) filter (where {UT}::date = {DT}::date - 1), 'HH24:MI'),
   round(100.0*avg(({UT} >= {DT})::int),1)
   from entsoe.offered_transfer_capacities_implicit where date_time_utc >= %s and date_time_utc < %s
   group by 1 order by 3 desc""",(W0,W1)): print("  ",r)
print(f"\n## RES D-1 forecast: %rows whose stored update is after delivery start (=> intraday/current overwrite; D-1 column publication unknowable)")
print(q(f"""select count(*), round(100.0*avg(({UT} >= {DT})::int),1), round(100.0*avg(({UT} > {GATE})::int),1)
   from entsoe.generation_forecasts_for_wind_and_solar where date_time_utc >= %s and date_time_utc < %s and area_type_code like 'BZN%%' and day_ahead_generation_forecast_mw is not null""",(W0,W1)))
print("\n## LOAD by month since 2025-07 with explicit UTC: %post-gate, %backfill-stamped (>30d)")
for r in q(f"""select date_trunc('month',{DT})::date, count(*), round(100.0*avg(({UT} > {GATE})::int),1), round(100.0*avg(({UT} > {DT} + interval '30 days')::int),1)
   from entsoe.day_ahead_total_load_forecast where date_time_utc >= '2025-07-01' and date_time_utc < '2026-09-01' and area_type_code like 'BZN%%' group by 1 order by 1"""): print("  ",r)
print("\n## OUTAGES: what the registry's `::timestamp` cast does in this session — gate as evaluated vs explicit UTC, versions in Oct-2025..Aug-2026")
print(q("""select count(*),
   count(*) filter (where version_publication_timestamp_utc::timestamp < date_trunc('day', start_outage_utc::timestamp) - interval '14 hours') passes_as_coded,
   count(*) filter (where (version_publication_timestamp_utc at time zone 'UTC') < date_trunc('day', (start_time_series_utc at time zone 'UTC')) - interval '14 hours') passes_explicit_utc
   from entsoe.unavailability_of_production_and_generation_units
   where start_outage_utc ~ '^\\d{4}-' and start_outage_utc::timestamp >= '2025-10-01' and start_outage_utc::timestamp < '2026-09-01'"""))
print("## start_outage_utc text sample + version_publication sample:", q("select start_outage_utc, version_publication_timestamp_utc, update_time_utc from entsoe.unavailability_of_production_and_generation_units where start_outage_utc >= '2026-08-20' limit 3"))
