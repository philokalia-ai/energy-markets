#!/usr/bin/env python3
"""Phase 0 — unit-level dispatch evidence (GR).

Fit-equivalence bounds the total exercised markup but cannot name the firm.
Dispatch can: capacity that was IN THE MONEY at the settled price but did not
produce is the physical signature of withholding / above-cost bidding.

Per thermal unit u and hour h:
    shortfall(u,h) = max(0, p95_30d(u,day) - output(u,h))   if settled(h) > 1.15*SRMC(u,day)
p95_30d = 95th pct of the unit's output over the trailing 30 days (an
outage/derating-robust availability proxy — same idea as fleet truthing).
SRMC: gas = TTF/0.55 + 0.367*EUA + 2 ; lignite = 25 + 1.25*EUA (src/Generators.jl
constants; last close strictly before the market day, no lookahead).

Aggregated per firm, compared across three day sets:
  band60   — the 60 medium-fit experiment days (residual +13)
  heldout  — the other 94 band days (residual +11)
  control  — 60 good-fit days (baseline corr > 0.85), matched count
plus the day-level correlation between PPC shortfall share and the residual.

Fully offline: euphemia-live.duckdb + results.duckdb (read-only)."""
import duckdb, os, json
import numpy as np

EM = os.path.expanduser("~/armada/energy-markets")
HERE = os.path.join(EM, "docs/experiments/gr-strategic-bidding")
c = duckdb.connect(); c.execute("SET TimeZone='UTC'")
c.execute(f"ATTACH '{EM}/data/extracts/euphemia-live.duckdb' AS x (READ_ONLY)")
c.execute(f"ATTACH '{EM}/data/results.duckdb' AS r (READ_ONLY)")

band60 = json.load(open(f"{HERE}/days.json"))
heldout = json.load(open(f"{HERE}/heldout_days.json"))

# control: 60 good-fit days spread over the same window
ctrl = [r0[0].isoformat() for r0 in c.execute("""
WITH sim AS (SELECT date_trunc('hour',date_time_utc) h, AVG(price_eur_mwh) p
             FROM r.simulations.energy_prices WHERE bidding_zone='GR' AND clearing_mode='gr_scn_base' GROUP BY 1),
act AS (SELECT date_trunc('hour',date_time_utc) h, AVG(price_currency_mwh) p
        FROM x.entsoe.energy_prices WHERE map_code='GR' AND contract_type='Day-ahead' GROUP BY 1),
dd AS (SELECT CAST(sim.h AS DATE) dt, corr(sim.p,act.p) cr FROM sim JOIN act ON act.h=sim.h
       GROUP BY 1 HAVING COUNT(*)>=24)
SELECT dt FROM dd WHERE cr > 0.85 ORDER BY dt""").fetchall()]
step = max(1, len(ctrl)//60)
control = ctrl[::step][:60]
print(f"day sets: band60={len(band60)} heldout={len(heldout)} control={len(control)} (from {len(ctrl)} good-fit)")

alldays = sorted(set(band60) | set(heldout) | set(control))
dl = "','".join(alldays)

# --- fuel prices: last close strictly before each market day ---------------
c.execute(f"""CREATE TEMP TABLE fuel AS
WITH days(dt) AS (SELECT CAST(unnest(['{dl}']) AS DATE)),
ttf AS (SELECT CAST("date" AS DATE) d, close FROM x.yfinance.ttf_f),
eua AS (SELECT CAST("date" AS DATE) d, close FROM x.yfinance.eua_co2)
SELECT dt,
  (SELECT close FROM ttf WHERE d < dt ORDER BY d DESC LIMIT 1) AS ttf,
  (SELECT close FROM eua WHERE d < dt ORDER BY d DESC LIMIT 1) AS eua
FROM days""")

# --- unit universe: GR thermal (gas + lignite) with firm ---------------------
c.execute("""CREATE TEMP TABLE units AS
SELECT DISTINCT ON (p.generation_unit_code)
       p.generation_unit_code uc, f.firm,
       p.generation_unit_type ptype
FROM x.entsoe.production_and_generation_units p
JOIN x.simulations.unit_firms f ON f.zone='GR' AND f.unit_code=p.generation_unit_code
WHERE p.area_map_code='GR'
  AND p.generation_unit_type IN ('Fossil Gas','Fossil Brown coal/Lignite')
ORDER BY p.generation_unit_code, p.valid_from DESC""")
print(c.execute("SELECT firm, ptype, COUNT(*) FROM units GROUP BY 1,2 ORDER BY 1,2").df().to_string(index=False))

# --- hourly output + trailing-30d p95 availability proxy --------------------
c.execute(f"""CREATE TEMP TABLE gen AS
SELECT g.generation_unit_code uc, date_trunc('hour', g.date_time_utc) h,
       AVG(g.actual_generation_output_mw) mw
FROM x.entsoe.actual_generation_output_per_generation_unit g
JOIN units u ON u.uc = g.generation_unit_code
WHERE CAST(g.date_time_utc AS DATE) >= (SELECT MIN(CAST(dt AS DATE)) - INTERVAL 31 DAY FROM fuel)
GROUP BY 1,2""")
# trailing-30d p95 availability proxy per (unit, market day)
c.execute(f"""CREATE TEMP TABLE avail AS
SELECT u.uc, f.dt,
       (SELECT quantile_cont(g.mw, 0.95) FROM gen g
        WHERE g.uc=u.uc AND g.h >= f.dt - INTERVAL 30 DAY AND g.h < f.dt) AS p95
FROM units u CROSS JOIN fuel f""")

# --- settled prices ----------------------------------------------------------
c.execute("""CREATE TEMP TABLE act AS
SELECT date_trunc('hour',date_time_utc) h, AVG(price_currency_mwh) p
FROM x.entsoe.energy_prices WHERE map_code='GR' AND contract_type='Day-ahead' GROUP BY 1""")

# --- in-the-money shortfall per unit-hour -----------------------------------
c.execute("""CREATE TEMP TABLE sf AS
SELECT u.firm, u.uc, CAST(act.h AS DATE) dt, act.h,
       CASE WHEN u.ptype='Fossil Gas' THEN f.ttf/0.55 + 0.367*f.eua + 2.0
            ELSE 25.0 + 1.25*f.eua END srmc,
       act.p settled, av.p95, COALESCE(g.mw, 0) mw,
       GREATEST(0, av.p95 - COALESCE(g.mw,0)) shortfall
FROM units u
JOIN fuel f ON TRUE
JOIN avail av ON av.uc=u.uc AND av.dt=f.dt
JOIN act ON CAST(act.h AS DATE)=f.dt
LEFT JOIN gen g ON g.uc=u.uc AND g.h=act.h
WHERE av.p95 IS NOT NULL AND av.p95 > 10
  AND act.p > 1.15 * (CASE WHEN u.ptype='Fossil Gas' THEN f.ttf/0.55 + 0.367*f.eua + 2.0
                           ELSE 25.0 + 1.25*f.eua END)""")

def setof(days): return "','".join(days)
print("\n=== in-the-money shortfall, MWh/day per firm (mean over days in set) ===")
for name, days in (("band60", band60), ("heldout", heldout), ("control", control)):
    df = c.execute(f"""
      SELECT firm, ROUND(SUM(shortfall)/COUNT(DISTINCT dt),0) AS mwh_day,
             ROUND(SUM(shortfall)/NULLIF(SUM(p95),0)*100,1) AS pct_of_avail,
             COUNT(DISTINCT dt) nd
      FROM sf WHERE dt IN ('{setof(days)}') GROUP BY 1 ORDER BY 2 DESC""").df()
    print(f"\n[{name}]")
    print(df.to_string(index=False))

# --- day-level: PPC shortfall vs residual -----------------------------------
print("\n=== day-level correlation: firm shortfall vs residual (band60+heldout) ===")
res = c.execute(f"""
WITH sim AS (SELECT date_trunc('hour',date_time_utc) h, AVG(price_eur_mwh) p
             FROM r.simulations.energy_prices WHERE bidding_zone='GR' AND clearing_mode='gr_scn_base' GROUP BY 1),
resid AS (SELECT CAST(sim.h AS DATE) dt, AVG(act.p - sim.p) rr
          FROM sim JOIN act ON act.h=sim.h GROUP BY 1),
fs AS (SELECT dt, firm, SUM(shortfall) s FROM sf GROUP BY 1,2)
SELECT fs.firm, ROUND(corr(fs.s, resid.rr),3) corr_with_residual, COUNT(*) nd
FROM fs JOIN resid ON resid.dt=fs.dt
WHERE fs.dt IN ('{setof(band60 + heldout)}')
GROUP BY 1 ORDER BY 2 DESC""").df()
print(res.to_string(index=False))
