import duckdb
EXTRACT='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
CSV='/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/cv23_model.csv'
con=duckdb.connect(EXTRACT, read_only=True); con.execute("SET TimeZone='UTC'")
con.execute(f"""create temp table model as select (h::timestamptz at time zone 'UTC') ts_utc, price_eur_mwh model
from read_csv_auto('{CSV}',header=true) where bidding_zone='PL'""")
con.execute("""create temp table settled as select date_trunc('hour',date_time_utc) ts_utc, avg(price_currency_mwh) settled
from entsoe.energy_prices where map_code='PL' and contract_type='Day-ahead' and currency='EUR' group by 1""")
con.execute("""create temp table j as select m.ts_utc,m.model,s.settled,
extract(year from m.ts_utc) yr, extract(month from m.ts_utc) mo, extract(hour from m.ts_utc) hr
from model m join settled s using(ts_utc)""")

def stat(w):
    r=con.execute(f"select count(*),avg(model-settled),avg(abs(model-settled)),avg(model),avg(settled),corr(model,settled) from j {w}").fetchone()
    return r

print("LEVEL check — NIGHT hours h22-h03 UTC (coal-marginal, no solar, no peak). If coal SRMC wrong, bias tracks year.")
for yr in [2023,2024,2025,2026]:
    r=stat(f"where yr={yr} and (hr>=22 or hr<=3)")
    print(f"  {yr} night: n={r[0]:5d} bias={r[1]:+7.2f} MAE={r[2]:6.2f} mdl={r[3]:6.2f} set={r[4]:6.2f}")

print("\nMIDDAY solar hours h10-h12 UTC (over-pricing = too little solar / coal floor too high). Track PV buildout.")
for yr in [2023,2024,2025,2026]:
    r=stat(f"where yr={yr} and hr in (10,11,12)")
    print(f"  {yr} midday: n={r[0]:5d} bias={r[1]:+7.2f} MAE={r[2]:6.2f} mdl={r[3]:6.2f} set={r[4]:6.2f}")

print("\nEVENING peak hours h16-h19 UTC (under-pricing = missing peak scarcity).")
for yr in [2023,2024,2025,2026]:
    r=stat(f"where yr={yr} and hr in (16,17,18,19)")
    print(f"  {yr} evening: n={r[0]:5d} bias={r[1]:+7.2f} MAE={r[2]:6.2f} mdl={r[3]:6.2f} set={r[4]:6.2f}")

# regime: does under-pricing concentrate on high-settled days? bucket by settled hourly level
print("\nRESIDUAL by settled-price bucket (all hours). Under-pricing concentrated at high settled = scarcity shape.")
for lo,hi in [(-1000,0),(0,50),(50,100),(100,150),(150,250),(250,10000)]:
    r=stat(f"where settled>={lo} and settled<{hi}")
    if r[0]>0:
        print(f"  settled[{lo},{hi}): n={r[0]:6d} bias={r[1]:+8.2f} MAE={r[2]:6.2f} mdl={r[3]:6.2f} set={r[4]:6.2f}")

# how much of the corr loss is evening? corr excluding evening peak
r=stat("where hr not in (15,16,17,18,19)")
print(f"\nCorr EXCLUDING evening (h15-19): n={r[0]} corr={r[5]:.3f} (full-day corr ~0.71)")
r=stat("where hr in (16,17,18)")
print(f"Corr evening-only (h16-18): n={r[0]} corr={r[5]:.3f}")
