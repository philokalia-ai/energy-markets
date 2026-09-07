import os, psycopg2
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor()
tables = ["entsoe.day_ahead_total_load_forecast","entsoe.day_ahead_generation_forecast_wind_solar",
 "entsoe.aggregated_generation_per_type","entsoe.actual_generation_output_per_unit",
 "entsoe.unavailability_of_production_and_generation_units","entsoe.unavailability_of_consumption_units",
 "entsoe.production_and_generation_units","entsoe.installed_capacity_per_production_unit",
 "entsoe.aggregated_hydro_storage_filling_rate","entsoe.forecasted_transfer_capacities",
 "entsoe.offered_capacity_implicit","entsoe.offered_capacity_explicit","entsoe.physical_flows",
 "entsoe.actual_total_load","entsoe.total_capacity_nominated","entsoe.unavailability_in_transmission_grid",
 "jao.max_exchanges","jao.hub_net_positions","jao.final_domain","jao.shadow_auctions",
 "yfinance.ttf_f","yfinance.eua_co2"]
for t in tables:
    s,n = t.split(".")
    cur.execute("""select column_name,data_type from information_schema.columns
                   where table_schema=%s and table_name=%s order by ordinal_position""",(s,n))
    cols = cur.fetchall()
    if not cols: print(f"\n## {t}: (not found)"); continue
    print(f"\n## {t}")
    print("  " + ", ".join(f"{c}:{d.split(' ')[0]}" for c,d in cols))
    tcols = [c for c,d in cols if any(k in c.lower() for k in ("update","publ","version","created","ingest","loaded","extracted","modified","doc","revision"))]
    print("  TIME/REV-ish:", tcols)
