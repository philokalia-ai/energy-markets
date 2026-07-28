import duckdb, sys
EXTRACT='/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb'
CSV='/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/cv23_model.csv'
con=duckdb.connect(EXTRACT, read_only=True)
con.execute("SET TimeZone='UTC'")
# model: parse tz-aware h -> naive UTC hour
con.execute(f"""
create temp table model as
select bidding_zone as zone,
       (h::timestamptz at time zone 'UTC') as ts_utc,
       price_eur_mwh as model
from read_csv_auto('{CSV}', header=true)
where bidding_zone='PL'
""")
# settled hourly (avg over 15-min)
con.execute("""
create temp table settled as
select date_trunc('hour', date_time_utc) as ts_utc,
       avg(price_currency_mwh) as settled
from entsoe.energy_prices
where map_code='PL' and contract_type='Day-ahead' and currency='EUR'
group by 1
""")
con.execute("""
create temp table j as
select m.ts_utc, m.model, s.settled, (m.model - s.settled) as resid,
       extract(year from m.ts_utc) as yr,
       extract(month from m.ts_utc) as mo,
       extract(hour from m.ts_utc) as hr
from model m join settled s using(ts_utc)
""")
n=con.execute("select count(*) from j").fetchone()[0]
print("joined hours:", n)

def corr_mae(where=""):
    q=f"""select count(*), corr(model,settled), avg(model-settled), avg(abs(model-settled)),
           avg(model), avg(settled) from j {where}"""
    return con.execute(q).fetchone()

print("\n=== BY YEAR (n, corr, bias, MAE, mean_model, mean_settled) ===")
for yr in [2023,2024,2025,2026]:
    r=corr_mae(f"where yr={yr}")
    print(f"{yr}: n={r[0]:6d} corr={r[1]:.3f} bias={r[2]:+7.2f} MAE={r[3]:6.2f} mdl={r[4]:6.2f} set={r[5]:6.2f}")

print("\n=== BY SEASON x YEAR (winter=DJF, summer=JJA) ===")
for yr in [2023,2024,2025,2026]:
    for name,mos in [("winter","(12,1,2)"),("summer","(6,7,8)")]:
        r=corr_mae(f"where yr={yr} and mo in {mos}")
        if r[0]>0:
            print(f"{yr} {name}: n={r[0]:5d} corr={r[1] if r[1] else 0:.3f} bias={r[2]:+7.2f} MAE={r[3]:6.2f} mdl={r[4]:6.2f} set={r[5]:6.2f}")

print("\n=== BY HOUR OF DAY (UTC) all years ===")
for hr in range(24):
    r=corr_mae(f"where hr={hr}")
    print(f"h{hr:02d} UTC: n={r[0]:5d} corr={r[1]:.3f} bias={r[2]:+7.2f} MAE={r[3]:6.2f} mdl={r[4]:6.2f} set={r[5]:6.2f}")
