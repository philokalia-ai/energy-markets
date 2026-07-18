#!/usr/bin/env python3
"""Evaluate the coupled robustness runs for GR: gr_strat_eu_base vs
gr_strat_eu_topslice vs settled, paired per day, and juxtapose with the
single-zone numbers. Read-only on results.duckdb + extract."""
import duckdb, os
EM = os.path.expanduser("~/armada/energy-markets")
c = duckdb.connect(); c.execute("SET TimeZone='UTC'")
c.execute(f"ATTACH '{EM}/data/results.duckdb' AS r (READ_ONLY)")
c.execute(f"ATTACH '{EM}/data/extracts/euphemia-live.duckdb' AS x (READ_ONLY)")

c.execute("""CREATE TEMP TABLE px AS
SELECT clearing_mode AS cm, date_trunc('hour',date_time_utc) AS h, AVG(price_eur_mwh) AS p
FROM r.simulations.energy_prices
WHERE bidding_zone='GR' AND clearing_mode IN ('gr_strat_eu_base','gr_strat_eu_topslice')
GROUP BY 1,2""")
c.execute("""CREATE TEMP TABLE act AS
SELECT date_trunc('hour',date_time_utc) AS h, AVG(price_currency_mwh) AS p
FROM x.entsoe.energy_prices WHERE map_code='GR' AND contract_type='Day-ahead' GROUP BY 1""")

# per-day paired metrics vs settled
def per_label(label):
    return c.execute(f"""
    WITH j AS (
      SELECT CAST(p.h AS DATE) d, p.h, p.p sim, a.p act
      FROM px p JOIN act a ON a.h=p.h WHERE p.cm='{label}')
    SELECT d, corr(sim,act) corr, AVG(abs(act-sim)) mae, AVG(act-sim) resid, COUNT(*) n
    FROM j GROUP BY 1 HAVING COUNT(*)>=20""").df()

base = per_label('gr_strat_eu_base').set_index('d')
top  = per_label('gr_strat_eu_topslice').set_index('d')
days = base.index.intersection(top.index)
print(f"coupled days evaluated: {len(days)}")

import numpy as np
def agg(df, days):
    d=df.loc[days]
    return dict(corr=d['corr'].mean(), mae=d['mae'].mean(), resid=d['resid'].mean())
b=agg(base,days); t=agg(top,days)
dmae=(base.loc[days,'mae']-top.loc[days,'mae'])
better=int((dmae>1e-6).sum())

print("\n=== COUPLED (39-zone, imports respond) — GR vs settled ===")
print(f"{'':22s}{'corr':>7s}{'MAE':>8s}{'resid':>8s}")
print(f"{'baseline (coupled)':22s}{b['corr']:7.2f}{b['mae']:8.2f}{b['resid']:8.2f}")
print(f"{'topslice 25% (coupled)':22s}{t['corr']:7.2f}{t['mae']:8.2f}{t['resid']:8.2f}")
print(f"{'ΔMAE gain':22s}{'':7s}{dmae.mean():8.2f}   better {better}/{len(days)}")

print("\n=== SINGLE-ZONE (imports fixed) — from results.tsv, same 60 days ===")
print(f"{'baseline (single)':22s}{0.72:7.2f}{31.96:8.2f}{13.21:8.2f}")
print(f"{'topslice 25% (single)':22s}{0.76:7.2f}{28.81:8.2f}{6.36:8.2f}")
print(f"{'ΔMAE gain':22s}{'':7s}{3.15:8.2f}   better 50/60")

print("\nReading: if the coupled ΔMAE gain is smaller than the single-zone +3.15,")
print("import relief absorbed part of the markup (single-zone was an upper bound).")
print("If corr still improves and resid still shrinks toward 0, the finding holds under coupling.")
