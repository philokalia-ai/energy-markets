import os, psycopg2, sys
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor()
cur.execute("set statement_timeout = '600s'")
def q(sql, args=()):
    try:
        cur.execute(sql, args); return cur.fetchall()
    except Exception as e:
        cx.rollback(); return [("ERR", str(e).splitlines()[0][:120])]
def cols(t):
    s,n=t.split("."); return q("select column_name from information_schema.columns where table_schema=%s and table_name=%s order by ordinal_position",(s,n))
for t in ["entsoe.generation_forecasts_for_wind_and_solar","entsoe.offered_transfer_capacities_implicit",
          "entsoe.offered_transfer_capacities_explicit","entsoe.actual_generation_output_per_generation_unit",
          "entsoe.unavailability_in_the_transmission_grid","carbon.uka_price","simulations.input_corrections"]:
    print(f"\n## {t}\n  ", ", ".join(c for (c,) in cols(t)))

# --- Meaning of update_time_utc: lag from update to delivery, hour-of-day of update, dup keys
ZONES=("DE_LU","GR","FR","NO4","ES")
probes = {
 "entsoe.day_ahead_total_load_forecast": ("area_map_code","date_time_utc","total_load_mw"),
 "entsoe.generation_forecasts_for_wind_and_solar": ("area_map_code","date_time_utc",None),
 "entsoe.aggregated_generation_per_type": ("area_map_code","date_time_utc",None),
 "entsoe.actual_generation_output_per_generation_unit": ("area_map_code","date_time_utc",None),
 "entsoe.offered_transfer_capacities_implicit": ("out_area_map_code","date_time_utc",None),
 "entsoe.physical_flows": ("out_area_map_code","date_time_utc",None),
 "entsoe.actual_total_load": ("area_map_code","date_time_utc",None),
}
for t,(zc,tc,_) in probes.items():
    print(f"\n## {t} — update_time_utc semantics (2026-07-01..2026-08-31, zones {ZONES})")
    r = q(f"""
      with s as (select {tc} as dt, update_time_utc as ut from {t}
                 where {zc} = any(%s) and {tc} >= '2026-07-01' and {tc} < '2026-09-01')
      select count(*), count(ut), 
             percentile_cont(0.05) within group (order by extract(epoch from dt-ut)/3600),
             percentile_cont(0.5)  within group (order by extract(epoch from dt-ut)/3600),
             percentile_cont(0.95) within group (order by extract(epoch from dt-ut)/3600),
             count(distinct ut), count(distinct date_trunc('hour',ut))
      from s""",(list(ZONES),))
    print("  n, n_ut, lag_h p05/p50/p95 (delivery − update), distinct ut, distinct ut-hours:", r)
    r = q(f"""select extract(hour from update_time_utc)::int h, count(*) from {t}
              where {zc} = any(%s) and {tc} >= '2026-07-01' and {tc} < '2026-09-01' group by 1 order by 2 desc limit 6""",(list(ZONES),))
    print("  update hour-of-day (UTC) top6:", r)
    r = q(f"""select count(*) from (select {zc},{tc},count(*) c from {t}
              where {zc} = any(%s) and {tc} >= '2026-07-01' and {tc} < '2026-09-01' group by 1,2 having count(*)>1) d""",(list(ZONES),))
    print("  keys with >1 row (revisions kept?):", r)
    r = q(f"""select date_part('year',{tc})::int y, count(*) , count(update_time_utc), min(update_time_utc)::date, max(update_time_utc)::date
              from {t} where {zc} = any(%s) and {tc} >= '2024-01-01' and extract(day from {tc}) <= 3 group by 1 order by 1""",(list(ZONES),))
    print("  per year (days 1-3 sample): n, n_ut, min/max ut:", r)

# outages: update_time_utc vs version_publication_timestamp_utc over time
print("\n## outages: version_publication_timestamp_utc vs update_time_utc by month")
for row in q("""select date_trunc('month', start_outage_utc::timestamp)::date m, count(*),
      count(version_publication_timestamp_utc),
      count(*) filter (where version_publication_timestamp_utc::timestamp = update_time_utc) same_as_update,
      percentile_cont(0.5) within group (order by extract(epoch from (start_outage_utc::timestamp - version_publication_timestamp_utc))/3600) lead_h_p50,
      count(distinct instance_code) msgs, count(*) filter (where old_version) old
      from entsoe.unavailability_of_production_and_generation_units
      where start_outage_utc::timestamp >= '2024-07-01' and start_outage_utc::timestamp < '2026-09-01'
      and start_outage_utc ~ '^\\d{4}-'
      group by 1 order by 1"""):
    print("  ", row)

print("\n## jao: fetched_at vs last_modified_utc vs mtu (2026-07..08)")
for t in ["jao.max_exchanges","jao.hub_net_positions"]:
    print(" ", t, q(f"""select count(*), count(distinct fetched_at::date),
        percentile_cont(0.5) within group (order by extract(epoch from date_time_utc-last_modified_utc)/3600),
        percentile_cont(0.05) within group (order by extract(epoch from date_time_utc-last_modified_utc)/3600),
        percentile_cont(0.5) within group (order by extract(epoch from date_time_utc-fetched_at)/3600),
        min(date_time_utc)::date, max(date_time_utc)::date
        from {t} where date_time_utc >= '2026-07-01' and date_time_utc < '2026-09-01'"""))
print("\n## hydro fill: update_time_utc vs week")
print(q("""select year, week, min(update_time_utc)::date, max(update_time_utc)::date, count(*) from entsoe.aggregated_hydro_storage_filling_rate
           where year=2026 and week between 28 and 35 group by 1,2 order by 1,2"""))
