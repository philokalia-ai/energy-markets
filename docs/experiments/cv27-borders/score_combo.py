#!/usr/bin/env python3
"""Phase 3/4 combination scorer. Union arm (combo_A/combo_B) vs cv26 baseline over
the full Set-A (or Set-B) days. Gates: inherited envelope (+3.0 MAE / -0.05 corr
any zone), ZERO new cap hours (sim>=2999), aggregate beats cv26 (dMAE<0 AND
dcorr>-0.005)."""
import duckdb, math, os, sys, collections

SP = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SP); P7 = os.path.join(ROOT, "p7"); CELLS = os.path.join(SP, "cells")
EXTRACT = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
which = sys.argv[1] if len(sys.argv) > 1 else "A"
if which == "A":
    DAYS = ["2025-01-01","2025-01-08","2025-01-15","2025-01-22","2026-01-01","2026-01-08","2026-01-15","2026-01-22",
            "2024-07-01","2024-07-08","2024-07-15","2024-07-22","2025-07-01","2025-07-08","2025-07-15","2025-07-22",
            "2025-05-01","2025-05-08","2025-05-15","2025-05-22","2026-05-01","2026-05-08","2026-05-15","2026-05-22"]
    CV26 = lambda d: f"{P7}/cv26_{d}.tsv"
else:
    DAYS = ["2025-01-04","2025-01-11","2025-01-18","2025-01-25","2026-01-04","2026-01-11","2026-01-18","2026-01-25",
            "2024-07-04","2024-07-11","2024-07-18","2024-07-25","2025-07-04","2025-07-11","2025-07-19","2025-07-25",
            "2025-05-04","2025-05-11","2025-05-18","2025-05-25","2026-05-04","2026-05-11","2026-05-18","2026-05-25"]
    CV26 = lambda d: f"{P7}/B_cv26_{d}.tsv"
ARM = lambda d: f"{CELLS}/combo_{which}_{d}.tsv"

def load(fn):
    d = {}
    for day in DAYS:
        p = fn(day)
        assert os.path.exists(p) and os.path.getsize(p) > 0, f"MISSING {p}"
        for line in open(p):
            a, dy, z, ts, v = line.rstrip("\n").split("\t"); d.setdefault(dy, {}).setdefault(z, {})[ts] = float(v)
    return d
def hourly(sim):
    o = {}
    for ts, v in sim.items(): o.setdefault(ts[:11]+"00", []).append(v)
    return {h: sum(v)/len(v) for h, v in o.items()}

B = load(CV26); A = load(ARM)
con = duckdb.connect(EXTRACT, read_only=True); act = {}
for day in DAYS:
    for z, ts, p in con.execute("""SELECT map_code, strftime(date_trunc('hour',date_time_utc),'%Y%m%d-%H00'),
        avg(price_currency_mwh) FROM entsoe.energy_prices WHERE contract_type='Day-ahead'
        AND date_time_utc>=?::date AND date_time_utc<?::date+1 GROUP BY 1,2""",[day,day]).fetchall():
        act.setdefault(day, {}).setdefault(z, {})[ts] = p

cells = []
Hc = {}
for d in DAYS:
    zs = set(B[d]) & set(A[d]) & set(act.get(d, {}))
    for z in zs:
        hb = hourly(B[d][z]); ha = hourly(A[d][z]); Hc[('B',d,z)] = hb; Hc[('A',d,z)] = ha
        for h in set(hb) & set(ha) & set(act[d][z]): cells.append((d, z, h))
print(f"SET {which}  cells={len(cells)}  days={len(DAYS)}")

def score(tag, zs=None):
    pr = [(Hc[(tag,d,z)][h], act[d][z][h]) for (d,z,h) in cells if zs is None or z in zs]
    n=len(pr); mae=sum(abs(s-x) for s,x in pr)/n
    ms=sum(s for s,_ in pr)/n; mx=sum(x for _,x in pr)/n
    cov=sum((s-ms)*(x-mx) for s,x in pr); den=math.sqrt(sum((s-ms)**2 for s,_ in pr)*sum((x-mx)**2 for _,x in pr))
    return n, mae, (cov/den if den>0 else float('nan'))
ZS = sorted({z for _,z,_ in cells})
nb,mb,rb = score('B'); na,ma,ra = score('A')
print(f"cv26  MAE {mb:.2f} corr {rb:.3f}")
print(f"combo MAE {ma:.2f} corr {ra:.3f}   dMAE={ma-mb:+.2f} dcorr={ra-rb:+.3f}")
agg_pass = (ma-mb) < 0 and (ra-rb) > -0.005
pzb = {z: score('B',{z}) for z in ZS}; pza = {z: score('A',{z}) for z in ZS}
env = [(z, pza[z][1]-pzb[z][1], pza[z][2]-pzb[z][2]) for z in ZS if pza[z][1]-pzb[z][1] > 3.0 or pza[z][2]-pzb[z][2] < -0.05]
capb = collections.Counter(z for (d,z,h) in cells if Hc[('B',d,z)][h] >= 2999)
capa = collections.Counter(z for (d,z,h) in cells if Hc[('A',d,z)][h] >= 2999)
newcaps = {z: (capb.get(z,0), c) for z,c in capa.items() if c > capb.get(z,0)}
print(f"\nENVELOPE breaches (+3.0 MAE / -0.05 corr): {len(env)}")
for z,dm,dc in sorted(env,key=lambda x:-abs(x[1])): print(f"   {z:12s} dMAE={dm:+7.2f} dcorr={dc:+.3f}")
print(f"CAPS cv26 total={sum(capb.values())}  combo total={sum(capa.values())}  NEW={newcaps if newcaps else 'none'}")
print(f"\nGATES: aggregate(dMAE<0 & dcorr>-0.005)={agg_pass}  envelope(0 breaches)={len(env)==0}  caps(0 new)={len(newcaps)==0}")
print("PHASE3 "+("PASS" if (agg_pass and len(env)==0 and len(newcaps)==0) else "FAIL"))
print("\nTop movers (|dMAE|):")
for z in sorted(ZS, key=lambda z:-abs(pza[z][1]-pzb[z][1]))[:14]:
    print(f"  {z:12s} MAE {pzb[z][1]:6.2f}->{pza[z][1]:6.2f}  corr {pzb[z][2]:+.3f}->{pza[z][2]:+.3f}")
