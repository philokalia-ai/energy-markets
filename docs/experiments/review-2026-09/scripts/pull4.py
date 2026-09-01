import os, psycopg2, pandas as pd, numpy as np
pd.set_option('display.width', 250)
c = psycopg2.connect(os.environ['ENERGY_CONN_STR']); S=os.environ['S']
def q(s): return pd.read_sql(s,c)
print(q("select * from yfinance.sgb_f order by date desc limit 2").to_string())
print(q("select code_version, clearing_mode, count(*) n, min(date_time_utc), max(date_time_utc) from simulations.transmission_flows where code_version=37 group by 1,2").to_string())
print(q("select * from simulations.transmission_flows where code_version=37 limit 2").to_string())
print(q("select min(mtu), max(mtu) from jao.final_domain").to_string())
print(q("select presolved, count(*) from jao.final_domain where mtu = '2026-08-18 17:00:00+00' group by 1").to_string())
print(q("select presolved, count(*) from jao.final_domain where mtu = '2025-02-12 17:00:00+00' group by 1").to_string())
# hydro filling rate weekly
hf = q("""select area_map_code z, year, week, avg(stored_energy_mwh) mwh from entsoe.aggregated_hydro_storage_filling_rate
 where area_map_code in ('NO4','NO3','NO1','NO5','NO2','SE1','SE2','SE3','FI','ES','PT','CH','AT') and year>=2022 group by 1,2,3 order by 1,2,3""")
hf.to_parquet(S+'/hydro_fill.parquet'); print(hf.groupby('z').size().to_dict())
