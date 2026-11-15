#!/usr/bin/env python3
"""cv43 DC / BYOP ledger on the sampled days.

Usage: [BYOP_ARMS=a,b,...] scn_byop.py RESULTS_DB EXTRACT_DB [ETA=0.59] [CV=43]

Pairs every eu43_* DC/BYOP arm with eu43_base on (zone, hour) and reports, per
arm (s = BYOP share of the 574 MW DC load brought as a new GR CCGT):
  - GR load-weighted price Δ vs base (weights = ENTSO-E D-1 load forecast,
    the model's own unmodified demand series), EU-wide LW Δ
  - extra cost to EXISTING consumers (Σ load_fc × Δp), GR / outside / EU
  - the DC's own bill (574 MW × GR scenario price)
  - BYOP plant dispatch estimate: offered s×574 MW at its SRMC (TTF/η +
    0.202/η·EUA + 2, closes strictly before D — the fleet rule); counted as
    dispatched when the GR price > SRMC + 0.01, half when within ±0.01
    (marginal), else 0
and s* = the smallest share at which the GR LW Δ ≤ 0 ("lower than today"),
linearly interpolated between the measured shares (None if never).
Coverage (paired days / hours) is printed with every number.
"""
import sys, duckdb

res_db, ext_db = sys.argv[1], sys.argv[2]
ETA = float(sys.argv[3]) if len(sys.argv) > 3 else 0.59
CV = int(sys.argv[4]) if len(sys.argv) > 4 else 43
ARMS = [("eu43_dc574", 0.0), ("eu43_byop_s25", 0.25), ("eu43_byop_s50", 0.50),
        ("eu43_byop_s75", 0.75), ("eu43_byop_s100", 1.00),
        ("eu43_byop_s150", 1.50), ("eu43_byop_s200", 2.00)]

import os
if os.environ.get("BYOP_ARMS"):
    keep = set(os.environ["BYOP_ARMS"].split(","))
    ARMS = [(a, s) for a, s in ARMS if a in keep]
con = duckdb.connect(res_db, read_only=True)
con.execute(f"ATTACH '{ext_db}' AS ext (READ_ONLY)")
con.execute("SET TimeZone='UTC'")
con.execute(f"""CREATE TEMP TABLE P AS
  SELECT clearing_mode arm, bidding_zone zone, date_trunc('hour', date_time_utc) h, AVG(price_eur_mwh) p
  FROM simulations.energy_prices WHERE code_version = {CV} AND clearing_mode LIKE 'eu43_%'
  GROUP BY 1, 2, 3""")
con.execute("""CREATE TEMP TABLE LW AS
  SELECT area_map_code zone, date_trunc('hour', date_time_utc) h, AVG(total_load_mw) w
  FROM ext.entsoe.day_ahead_total_load_forecast
  WHERE date_time_utc >= (SELECT min(h) FROM P) AND date_time_utc <= (SELECT max(h) FROM P)
  GROUP BY 1, 2""")
con.execute("""CREATE TEMP TABLE F AS
  SELECT d::DATE d,
    (SELECT close FROM ext.yfinance.ttf_f t WHERE t.date < d ORDER BY t.date DESC LIMIT 1) ttf,
    (SELECT close FROM ext.yfinance.eua_co2 e WHERE e.date < d ORDER BY e.date DESC LIMIT 1) eua
  FROM (SELECT DISTINCT CAST(h AS DATE) d FROM P) x""")

# complete (zone-count 39, >= 24 h) days per arm
con.execute("""CREATE TEMP TABLE CD AS SELECT arm, CAST(h AS DATE) d FROM P GROUP BY 1, 2
  HAVING COUNT(DISTINCT zone) >= 39 AND COUNT(DISTINCT h) >= 24""")
present = {a for (a,) in con.execute("SELECT DISTINCT arm FROM CD").fetchall()}
arms = [(a, s) for a, s in ARMS if a in present]
print("coverage (complete days per arm):",
      {a: n for a, n in con.execute("SELECT arm, COUNT(*) FROM CD GROUP BY 1 ORDER BY 1").fetchall()})
if "eu43_base" not in present or not arms:
    print("no base or no DC/BYOP arm complete — nothing to analyse"); sys.exit(0)
names = ["eu43_base"] + [a for a, _ in arms]
con.execute(f"""CREATE TEMP TABLE COMMON AS SELECT d FROM CD WHERE arm IN ({','.join("'"+n+"'" for n in names)})
  GROUP BY d HAVING COUNT(DISTINCT arm) = {len(names)}""")
ncommon = con.execute("SELECT COUNT(*) FROM COMMON").fetchone()[0]
print(f"common complete days across {names}: {ncommon}")

def table(daysql, label):
    print(f"\n== {label}")
    print(f"{'arm':16} {'s':>5} {'days':>5} {'GR h':>6} {'GR LWΔ':>8} {'EU LWΔ':>8} "
          f"{'GR €m':>8} {'out €m':>8} {'EU €m':>8} {'DC TWh':>7} {'DC €m':>7} {'plant TWh':>9} {'plant CF':>8}")
    rows = []
    for arm, s in arms:
        r = con.execute(f"""
          WITH j AS (
            SELECT b.zone, b.h, b.p pb, x.p ps, LW.w FROM P b
            JOIN P x ON x.zone = b.zone AND x.h = b.h AND x.arm = '{arm}'
            JOIN LW ON LW.zone = b.zone AND LW.h = b.h
            WHERE b.arm = 'eu43_base' AND CAST(b.h AS DATE) IN ({daysql.format(arm=arm)})),
          gr AS (SELECT j.*, F.ttf / {ETA} + 0.202 / {ETA} * F.eua + 2.0 srmc FROM j JOIN F ON F.d = CAST(j.h AS DATE) WHERE zone = 'GR')
          SELECT
            (SELECT count(DISTINCT CAST(h AS DATE)) FROM j) ndays,
            (SELECT count(*) FROM gr) nh,
            (SELECT sum(w * (ps - pb)) / sum(w) FROM j WHERE zone = 'GR') gr_lw,
            (SELECT sum(w * (ps - pb)) / sum(w) FROM j) eu_lw,
            (SELECT sum(w * (ps - pb)) / 1e6 FROM j WHERE zone = 'GR') gr_cost,
            (SELECT sum(w * (ps - pb)) / 1e6 FROM j WHERE zone <> 'GR') out_cost,
            (SELECT sum(w * (ps - pb)) / 1e6 FROM j) eu_cost,
            (SELECT count(*) * 574.0 / 1e6 FROM gr) dc_twh,
            (SELECT sum(574.0 * ps) / 1e6 FROM gr) dc_cost,
            (SELECT sum({s} * 574.0 * CASE WHEN ps > srmc + 0.01 THEN 1 WHEN ps >= srmc - 0.01 THEN 0.5 ELSE 0 END) / 1e6 FROM gr) plant_twh
        """).fetchone()
        nd, nh, grl, eul, grc, outc, euc, dct, dcc, pt = r
        if not nh:
            print(f"{arm:16} {s*100:4.0f}%   (no paired hours)"); continue
        cf = (pt / (s * 574.0 * nh / 1e6)) if s > 0 else float('nan')
        rows.append((s, grl))
        print(f"{arm:16} {s*100:4.0f}% {nd:5d} {nh:6d} {grl:8.2f} {eul:8.3f} {grc:8.1f} {outc:8.1f} {euc:8.1f} "
              f"{dct:7.3f} {dcc:7.1f} {pt:9.3f} {cf:8.2f}")
    return rows

table("SELECT d FROM CD WHERE arm = '{arm}' INTERSECT SELECT d FROM CD WHERE arm = 'eu43_base'",
      "each arm on its own complete days paired with base")
rows = table("SELECT d FROM COMMON", f"all arms on the {ncommon} COMMON complete days (use these for s*)")

s_star = None
rows.sort()
for (s0, g0), (s1, g1) in zip(rows, rows[1:]):
    if g0 <= 0:
        s_star = s0; break
    if g1 <= 0:
        s_star = s0 + (s1 - s0) * g0 / (g0 - g1); break
if s_star is None and rows and rows[0][1] <= 0:
    s_star = rows[0][0]
print(f"\ns* (GR LW price with DC+plant <= no-DC baseline), on common days, from shares "
      f"{[int(r[0]*100) for r in rows]} %: "
      f"{'not reached within the measured shares' if s_star is None else f'{s_star*100:.0f} %'} "
      f"(LINEAR INTERPOLATION between measured shares)")
print("€ sums cover the listed days only (every 4th day sampled); ×4 ≈ full-window equivalent.")
