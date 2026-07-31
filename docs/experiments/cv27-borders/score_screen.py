#!/usr/bin/env python3
"""Phase 2 per-border screening scorer. For each candidate border arm vs the
cv26 baseline (p7/cv26_<day>.tsv), on the 8-day panel, hourly MAE/corr per zone
vs entsoe.energy_prices Day-ahead. Frozen gates:
  (i)   neither endpoint zone worsens MAE > +1.0
  (ii)  no OTHER zone worsens MAE > +2.0 or corr < -0.04
  (iii) footprint aggregate MAE not worse than +0.05
ACCEPT iff all three pass."""
import duckdb, math, os, sys, collections

SP = os.path.dirname(os.path.abspath(__file__))          # border_program
ROOT = os.path.dirname(SP)                                # scratchpad
P7 = os.path.join(ROOT, "p7")
CELLS = os.path.join(SP, "cells")
EXTRACT = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
DAYS = ["2025-01-01","2025-01-15","2025-05-01","2025-05-15",
        "2025-07-01","2025-07-15","2026-01-01","2026-01-15"]
BORDERS = {
 "b01_DELU_NL":("DE_LU","NL"), "b02_DELU_FR":("DE_LU","FR"),
 "b03_ITCS_ITS":("IT-CSOUTH","IT-SOUTH"), "b04_DELU_PL":("DE_LU","PL"),
 "b05_CH_FR":("CH","FR"), "b06_CZ_DELU":("CZ","DE_LU"), "b07_CZ_PL":("CZ","PL"),
 "b08_SE1_SE2":("SE1","SE2"), "b09_ITCN_ITN":("IT-CNORTH","IT-NORTH"),
 "b10_DELU_DK2":("DE_LU","DK2"), "b11_DK1_SE3":("DK1","SE3"),
 "b12_ITCA_ITSI":("IT-Calabria","IT-Sicily"),
}

def load(pathfn):
    d = {}
    for day in DAYS:
        p = pathfn(day)
        if not os.path.exists(p) or os.path.getsize(p) == 0:
            return None            # incomplete arm
        for line in open(p):
            a, dy, z, ts, v = line.rstrip("\n").split("\t")
            d.setdefault(dy, {}).setdefault(z, {})[ts] = float(v)
    return d

def hourly(sim):
    out = {}
    for ts, v in sim.items(): out.setdefault(ts[:11]+"00", []).append(v)
    return {h: sum(v)/len(v) for h, v in out.items()}

con = duckdb.connect(EXTRACT, read_only=True)
act = {}
for day in DAYS:
    for z, ts, p in con.execute("""SELECT map_code, strftime(date_trunc('hour',date_time_utc),'%Y%m%d-%H00'),
        avg(price_currency_mwh) FROM entsoe.energy_prices WHERE contract_type='Day-ahead'
        AND date_time_utc >= ?::date AND date_time_utc < ?::date+1 GROUP BY 1,2""",[day,day]).fetchall():
        act.setdefault(day, {}).setdefault(z, {})[ts] = p

CV26 = load(lambda d: f"{P7}/cv26_{d}.tsv")
assert CV26 is not None, "cv26 baseline incomplete in p7/"

def cells_for(base, arm):
    """common (day,zone,hour) cells across base, arm, actuals"""
    cs = []
    for d in DAYS:
        zs = set(base[d]) & set(arm[d]) & set(act.get(d, {}))
        for z in zs:
            hb, ha = hourly(base[d][z]), hourly(arm[d][z])
            hs = set(hb) & set(ha) & set(act[d][z])
            for h in hs: cs.append((d, z, h))
    return cs

def per_zone(data, cells):
    HH = {}
    for (d,z,h) in cells: pass
    Z = collections.defaultdict(list)
    hcache = {}
    for (d,z,h) in cells:
        key=(d,z)
        if key not in hcache: hcache[key]=hourly(data[d][z])
        Z[z].append((hcache[key][h], act[d][z][h]))
    out = {}
    for z, pr in Z.items():
        n=len(pr); mae=sum(abs(s-x) for s,x in pr)/n
        ms=sum(s for s,_ in pr)/n; mx=sum(x for _,x in pr)/n
        cov=sum((s-ms)*(x-mx) for s,x in pr)
        den=math.sqrt(sum((s-ms)**2 for s,_ in pr)*sum((x-mx)**2 for _,x in pr))
        out[z]=(n,mae,cov/den if den>0 else float('nan'))
    return out

def agg(data, cells):
    pr=[(hourly(data[d][z])[h], act[d][z][h]) for (d,z,h) in cells]
    n=len(pr); return sum(abs(s-x) for s,x in pr)/n

sel = sys.argv[1:] if len(sys.argv)>1 else list(BORDERS)
print(f"panel days={len(DAYS)}")
summary=[]
for arm in sel:
    ep = BORDERS[arm]
    A = load(lambda d, a=arm: f"{CELLS}/{a}_{d}.tsv")
    if A is None:
        print(f"\n== {arm} {ep}: INCOMPLETE (skip)"); continue
    cells = cells_for(CV26, A)
    pzb = per_zone(CV26, cells); pza = per_zone(A, cells)
    ag_b = agg(CV26, cells); ag_a = agg(A, cells)
    # gates
    g1 = all(pza[z][1]-pzb[z][1] <= 1.0 for z in ep if z in pza)
    others = [(z, pza[z][1]-pzb[z][1], pza[z][2]-pzb[z][2]) for z in pza if z not in ep]
    g2_breaches = [(z,dm,dc) for z,dm,dc in others if dm > 2.0 or dc < -0.04]
    g2 = len(g2_breaches)==0
    g3 = (ag_a - ag_b) <= 0.05
    verdict = "ACCEPT" if (g1 and g2 and g3) else "REJECT"
    print(f"\n== {arm} {ep[0]}~{ep[1]}  cells={len(cells)}  agg MAE {ag_b:.2f}->{ag_a:.2f} ({ag_a-ag_b:+.2f})  -> {verdict}")
    for z in ep:
        if z in pza:
            print(f"   endpoint {z:12s} MAE {pzb[z][1]:6.2f}->{pza[z][1]:6.2f} ({pza[z][1]-pzb[z][1]:+.2f})  corr {pzb[z][2]:+.3f}->{pza[z][2]:+.3f} ({pza[z][2]-pzb[z][2]:+.3f})")
    print(f"   gate(i endpoints<=+1.0)={g1}  gate(ii others)={g2}  gate(iii agg<=+0.05)={g3}")
    if g2_breaches:
        for z,dm,dc in sorted(g2_breaches,key=lambda x:-abs(x[1]))[:6]:
            print(f"      BREACH {z:12s} dMAE={dm:+7.2f} dcorr={dc:+.3f}")
    # top movers (info)
    mov=sorted(pza,key=lambda z:-abs(pza[z][1]-pzb[z][1]))[:5]
    print("   movers: "+", ".join(f"{z} {pzb[z][1]:.1f}->{pza[z][1]:.1f}" for z in mov))
    summary.append((arm, ep, verdict, ag_a-ag_b))
print("\n===== SUMMARY =====")
for arm, ep, v, da in summary:
    print(f"  {arm:16s} {ep[0]+'~'+ep[1]:22s} {v:7s} aggΔ={da:+.2f}")
print("ACCEPTED:", ",".join(a for a,_,v,_ in summary if v=="ACCEPT"))
