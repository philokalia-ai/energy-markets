import os, psycopg2
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor()
cur.execute("set statement_timeout = '900s'")
def q(sql, args=()):
    try: cur.execute(sql, args); return cur.fetchall()
    except Exception as e: cx.rollback(); return [("ERR", str(e).splitlines()[0][:160])]
# gate = (delivery UTC-day − 1 day) 10:00 UTC  (D-1 12:00 CEST; conservative in winter)
GATE = "((date_trunc('day', {dt}) - interval '1 day') + interval '10 hours')"
W0, W1 = '2026-06-01', '2026-09-01'
print("## share of stored rows whose update_time_utc is AFTER the D-1 10:00 UTC gate, per zone, %s..%s" % (W0, W1))
for t, zc, extra in [("entsoe.day_ahead_total_load_forecast","area_map_code","and area_type_code like 'BZN%%'"),
                     ("entsoe.generation_forecasts_for_wind_and_solar","area_map_code","and area_type_code like 'BZN%%' and day_ahead_generation_forecast_mw is not null"),
                     ("entsoe.offered_transfer_capacities_implicit","out_map_code","")]:
    g = GATE.format(dt="date_time_utc")
    rows = q(f"""select {zc}, count(*), round(100.0*avg((update_time_utc > {g})::int),1) post_gate_pct,
                 round(100.0*avg((update_time_utc > date_time_utc)::int),1) post_delivery_pct
                 from {t} where date_time_utc >= %s and date_time_utc < %s {extra}
                 group by 1 order by 3 desc""", (W0, W1))
    print(f"\n### {t}  (zone, n, %post-gate, %post-delivery)")
    for r in rows: print("  ", r)
    tot = q(f"""select count(*), round(100.0*avg((update_time_utc > {g})::int),2) from {t}
                where date_time_utc >= %s and date_time_utc < %s {extra}""", (W0, W1))
    print("   TOTAL:", tot)

print("\n## same, by month since 2025-07 (all zones) — when does update_time become informative?")
for t, extra in [("entsoe.day_ahead_total_load_forecast","and area_type_code like 'BZN%%'"),
                 ("entsoe.generation_forecasts_for_wind_and_solar","and area_type_code like 'BZN%%' and day_ahead_generation_forecast_mw is not null")]:
    g = GATE.format(dt="date_time_utc")
    rows = q(f"""select date_trunc('month',date_time_utc)::date m, count(*),
                 round(100.0*avg((update_time_utc > {g})::int),1) post_gate_pct,
                 round(100.0*avg((update_time_utc > date_time_utc + interval '30 days')::int),1) backfill_pct
                 from {t} where date_time_utc >= '2025-07-01' and date_time_utc < '2026-09-01' {extra}
                 group by 1 order by 1""")
    print(f"\n### {t} (month, n, %post-gate, %updated>30d after delivery = backfill stamp)")
    for r in rows: print("  ", r)

print("\n## JAO: last_modified_utc vs gate (2026-06..08)")
g = GATE.format(dt="date_time_utc")
for t in ["jao.max_exchanges","jao.hub_net_positions"]:
    print(" ", t, q(f"""select count(*), round(100.0*avg((last_modified_utc > {g})::int),2) post_gate_pct,
        round(100.0*avg((last_modified_utc > {g} - interval '1 hour')::int),2) post_gate_minus1h_pct,
        min(last_modified_utc), max(last_modified_utc)
        from {t} where date_time_utc >= %s and date_time_utc < %s""", (W0, W1)))
    print("   post-gate by ccr/day sample:", q(f"""select ccr, date_time_utc::date d, min(last_modified_utc), max(last_modified_utc)
        from {t} where date_time_utc >= %s and date_time_utc < %s and last_modified_utc > {g} group by 1,2 order by 2 limit 8""",(W0,W1)))

print("\n## outages: versions published after the gate but before start, by month — the ones the cv34 gate handles; and NULL publication share")
print(q("""select date_trunc('month', start_outage_utc::timestamp)::date m, count(*),
   count(*) filter (where version_publication_timestamp_utc is null) nulls,
   count(*) filter (where version_publication_timestamp_utc::timestamp >= date_trunc('day',start_outage_utc::timestamp) - interval '14 hours'
                     and version_publication_timestamp_utc::timestamp < start_outage_utc::timestamp) pub_between_gate_and_start,
   count(*) filter (where version = 1) v1,
   count(*) filter (where version = 1 and version_publication_timestamp_utc::timestamp > start_outage_utc::timestamp) v1_pub_after_start
   from entsoe.unavailability_of_production_and_generation_units
   where start_outage_utc ~ '^\\d{4}-' and start_outage_utc::timestamp >= '2025-07-01' and start_outage_utc::timestamp < '2026-09-01'
   group by 1 order by 1"""))

print("\n## hydro fill: publication lag of each week's first appearance (min update_time − end of ISO week), 2026 wk 1..35, zones NO4/ES/PT/CH/AT")
print(q("""select area_map_code, count(*), 
   percentile_cont(0.5) within group (order by extract(epoch from (mn - (to_date(year||'-'||week||'-1','IYYY-IW-ID') + 7)))/86400) lag_days_p50,
   min(extract(epoch from (mn - (to_date(year||'-'||week||'-1','IYYY-IW-ID') + 7)))/86400) lag_min,
   max(extract(epoch from (mn - (to_date(year||'-'||week||'-1','IYYY-IW-ID') + 7)))/86400) lag_max
   from (select area_map_code, year, week, min(update_time_utc) mn from entsoe.aggregated_hydro_storage_filling_rate
         where year=2026 and week between 1 and 35 and area_map_code in ('NO4','ES','PT','CH','AT','SE1','FR') group by 1,2,3) s
   group by 1 order by 1"""))
