#!/usr/bin/env python3
"""Phase B day selection: per zone, medium-corr band days from the cv17 coupled
baseline (eu17_base, 2023-07..2025-06), split into an evenly-strided
calibration set and a held-out remainder. Prints the residual-sign gate stats.

  python3 select_days.py DE_LU 44
  python3 select_days.py FR 60
"""
import duckdb, os, json, sys

EM = os.path.expanduser("~/armada/energy-markets")
zone = sys.argv[1] if len(sys.argv) > 1 else "DE_LU"
k = int(sys.argv[2]) if len(sys.argv) > 2 else 60
HERE = os.path.dirname(os.path.abspath(__file__))

c = duckdb.connect(); c.execute("SET TimeZone='UTC'")
c.execute(f"ATTACH '{EM}/data/results.duckdb' AS r (READ_ONLY)")
c.execute(f"ATTACH '{EM}/data/extracts/euphemia-live.duckdb' AS x (READ_ONLY)")
rows = c.execute(f"""
WITH sim AS (SELECT date_trunc('hour',date_time_utc) h, AVG(price_eur_mwh) p
             FROM r.simulations.energy_prices
             WHERE clearing_mode='eu17_base' AND bidding_zone='{zone}' GROUP BY 1),
act AS (SELECT date_trunc('hour',date_time_utc) h, AVG(price_currency_mwh) p
        FROM x.entsoe.energy_prices WHERE contract_type='Day-ahead' AND map_code='{zone}' GROUP BY 1)
SELECT CAST(sim.h AS DATE) dt, corr(sim.p,act.p) cr, AVG(act.p-sim.p) resid
FROM sim JOIN act ON act.h=sim.h GROUP BY 1 HAVING COUNT(*)>=20 ORDER BY 1""").fetchall()

band = [(d, cr, res) for d, cr, res in rows if 0.6 <= cr <= 0.8]
n = len(band)
if n < k:
    print(f"WARNING: band has only {n} days < requested {k}; taking all")
    k = n
idx = sorted(set(round(i * (n - 1) / max(k - 1, 1)) for i in range(k)))
cal = [band[i][0] for i in idx]
cal_set = set(cal)
heldout = [d for d, _, _ in band if d not in cal_set]

import statistics
res_cal = [r for d, _, r in band if d in cal_set]
res_ho = [r for d, _, r in band if d not in cal_set]
print(f"{zone}: band {n} days; calibration {len(cal)}, heldout {len(heldout)}")
print(f"  calibration resid mean {statistics.mean(res_cal):+.1f} median {statistics.median(res_cal):+.1f} "
      f"({sum(1 for r in res_cal if r > 2)}/{len(res_cal)} pos)")
if res_ho:
    print(f"  heldout     resid mean {statistics.mean(res_ho):+.1f} median {statistics.median(res_ho):+.1f}")

json.dump([d.isoformat() for d in cal], open(f"{HERE}/days_{zone}.json", "w"), indent=0)
json.dump([d.isoformat() for d in heldout], open(f"{HERE}/heldout_{zone}.json", "w"), indent=0)
print(f"wrote days_{zone}.json / heldout_{zone}.json")
