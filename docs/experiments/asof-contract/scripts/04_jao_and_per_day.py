import os, psycopg2
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor(); cur.execute("set statement_timeout='600s'")
def q(s,a=()):
    try: cur.execute(s,a); return cur.fetchall()
    except Exception as e: cx.rollback(); return [("ERR",str(e)[:150])]
print("## jao.max_exchanges: last_modified null share by delivery month; fetched_at range; publication hour (UTC) when present")
for r in q("""select date_trunc('month',date_time_utc)::date m, count(*), count(last_modified_utc),
   min(fetched_at)::date, max(fetched_at)::date,
   percentile_cont(0.5) within group (order by extract(hour from (last_modified_utc at time zone 'UTC'))) pub_hour_utc_p50,
   round(100.0*avg(((last_modified_utc at time zone 'UTC') > (date_trunc('day',date_time_utc) - interval '14 hours'))::int),2) post_gate_pct
   from jao.max_exchanges where date_time_utc >= '2025-07-01' group by 1 order by 1"""): print("  ",r)
print("## column types"); print(q("select column_name,data_type from information_schema.columns where table_schema='jao' and table_name='max_exchanges'"))
print("## fetched_at vs delivery for max_exchanges (is the live ETL pre-gate?) last 20 days")
for r in q("""select date_time_utc::date d, min(fetched_at), max(fetched_at), count(*) from jao.max_exchanges
   where date_time_utc >= '2026-08-15' group by 1 order by 1"""): print("  ",r)
print("## load forecast: per-day first/last update_time for DE_LU, last 10 days (is it a single publication or revisions?)")
for r in q("""select date_time_utc::date d, min(update_time_utc), max(update_time_utc), count(distinct update_time_utc) from entsoe.day_ahead_total_load_forecast
   where area_map_code='DE_LU' and date_time_utc >= '2026-08-22' and date_time_utc < '2026-09-01' group by 1 order by 1"""): print("  ",r)
print("## same for GR and FR")
for z in ("GR","FR","NO4"):
    for r in q("""select date_time_utc::date d, min(update_time_utc), max(update_time_utc), count(distinct update_time_utc) from entsoe.day_ahead_total_load_forecast
       where area_map_code=%s and date_time_utc >= '2026-08-25' and date_time_utc < '2026-09-01' group by 1 order by 1""",(z,)): print("  ",z,r)
print("## RES D-1 forecast DE_LU solar: per-day update times")
for r in q("""select date_time_utc::date d, production_type, min(update_time_utc), max(update_time_utc), count(distinct update_time_utc) from entsoe.generation_forecasts_for_wind_and_solar
   where area_map_code='DE_LU' and date_time_utc >= '2026-08-25' and date_time_utc < '2026-09-01' and day_ahead_generation_forecast_mw is not null group by 1,2 order by 1,2"""): print("  ",r)
