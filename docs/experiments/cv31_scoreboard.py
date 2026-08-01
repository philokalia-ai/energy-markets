import duckdb, math, collections
RES="/home/pgeorgakopoulos/armada/energy-markets/data/results.duckdb"
EXT="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
con = duckdb.connect(EXT, read_only=True)
con.execute(f"ATTACH '{RES}' AS res (READ_ONLY)")
FLOOR={"DE_LU","FR","PL","BE","CZ","CH"}
REG={**{z:"NORDIC" for z in "NO1 NO2 NO3 NO4 NO5 SE1 SE2 SE3 SE4 FI DK1 DK2".split()},
     **{z:"BALTIC" for z in "EE LV LT".split()},
     **{z:"CWE" for z in "DE_LU FR NL BE AT CH CZ PL SK HU SI".split()},
     **{z:"SEE" for z in "GR BG RO RS".split()},
     **{z:"IBERIA" for z in "ES PT".split()},
     **{z:"ITALY" for z in "IT-NORTH IT-CNORTH IT-CSOUTH IT-SOUTH IT-Calabria IT-Sicily IT-Sardinia".split()}}
q = """
WITH sim AS (
  SELECT bidding_zone z, date_trunc('hour', date_time_utc) h, avg(price_eur_mwh) p, code_version cv
  FROM res.simulations.energy_prices
  WHERE clearing_mode='multi_zone_eu' AND code_version IN (27,31)
  GROUP BY 1,2,4),
act AS (
  SELECT map_code z, date_trunc('hour', date_time_utc) h, avg(price_currency_mwh) p
  FROM entsoe.energy_prices WHERE contract_type='Day-ahead' GROUP BY 1,2)
SELECT s.cv, s.z, year(s.h) y, s.h, s.p sim, a.p act
FROM sim s JOIN act a ON s.z=a.z AND s.h=a.h
"""
rows = con.execute(q).fetchall()
# energy weights: zone-year load
lw = dict(((z,y),v) for z,y,v in con.execute(
  "SELECT area_map_code, year(date_time_utc), sum(total_load_mw) FROM entsoe.actual_total_load WHERE area_type_code LIKE 'BZN%' GROUP BY 1,2").fetchall())
D = collections.defaultdict(list)
for cv,z,y,h,s,a in rows: D[(cv,z,y)].append((s,a))
def stats(pr):
    n=len(pr); ms=sum(s for s,_ in pr)/n; ma=sum(a for _,a in pr)/n
    mae=sum(abs(s-a) for s,a in pr)/n
    cov=sum((s-ms)*(a-ma) for s,a in pr)
    den=math.sqrt(sum((s-ms)**2 for s,_ in pr)*sum((a-ma)**2 for _,a in pr))
    return n, mae, (cov/den if den>0 else float('nan'))
S={k:stats(v) for k,v in D.items()}
years=sorted({y for _,_,y in S})
zones=sorted({z for _,z,_ in S})
print("=== HEADLINE per year (pooled hourly, all 39 zones) ===")
print(f"{'year':6s}{'cv':>4s}{'n':>9s}{'MAE':>8s}{'corr':>7s}{'E-wt >=0.75 share':>19s}")
for y in years:
    for cv in (27,31):
        pool=[p for (c,z,yy),v in D.items() if c==cv and yy==y for p in v]
        n,mae,r=stats(pool)
        wtot=wok=0.0
        for z in zones:
            if (cv,z,y) not in S: continue
            w=lw.get((z,y),0.0); wtot+=w
            if S[(cv,z,y)][2]>=0.75: wok+=w
        print(f"{y:<6d}{cv:>4d}{n:>9d}{mae:>8.2f}{r:>7.3f}{100*wok/wtot if wtot else float('nan'):>18.1f}%")
print("\n=== REGIONS per year (energy-weighted mean corr; d = cv31-cv27) ===")
regs=sorted(set(REG.values()))
print(f"{'year':6s}"+ "".join(f"{r:>16s}" for r in regs))
for y in years:
    line=f"{y:<6d}"
    for rg in regs:
        agg={}
        for cv in (27,31):
            w=c=0.0
            for z in zones:
                if REG.get(z)!=rg or (cv,z,y) not in S: continue
                ww=lw.get((z,y),0.0); w+=ww; c+=ww*S[(cv,z,y)][2]
            agg[cv]=c/w if w else float('nan')
        line+=f"  {agg[27]:.3f}>{agg[31]:.3f}"
    print(line)
print("\n=== FLOOR ZONES (cv27 -> cv31) per year: corr | MAE ===")
for z in sorted(FLOOR):
    line=f"{z:6s}"
    for y in years:
        if (27,z,y) in S and (31,z,y) in S:
            line+=f"  {y}: {S[(27,z,y)][2]:.3f}->{S[(31,z,y)][2]:.3f} | {S[(27,z,y)][1]:.1f}->{S[(31,z,y)][1]:.1f}"
    print(line)
print("\n=== NON-FLOOR max |d-corr| (should be ~0) ===")
mx=sorted(((abs(S[(31,z,y)][2]-S[(27,z,y)][2]),z,y) for z in zones for y in years
          if z not in FLOOR and (27,z,y) in S and (31,z,y) in S), reverse=True)[:5]
for d,z,y in mx: print(f"  {z} {y}: |dcorr|={d:.4f}")
print("\n=== COLLAPSE (floor zones, settled<=5 hours): hit(sim<=5) / FA(sim<=5 & settled>20) ===")
for cv in (27,31):
    hit=tot=fa=fatot=0
    for (c,z,y),v in D.items():
        if c!=cv or z not in FLOOR: continue
        for s,a in v:
            if a<=5: tot+=1; hit+= (s<=5)
            if a>20: fatot+=1; fa+= (s<=5)
    print(f"  cv{cv}: hit {hit}/{tot} ({100*hit/tot:.1f}%)  FA {fa}/{fatot} ({100*fa/fatot:.2f}%)")
# full per-zone table to file
with open("cv31_per_zone_year.tsv","w") as f:
    f.write("zone\tyear\tn\tcv27_MAE\tcv31_MAE\tcv27_corr\tcv31_corr\n")
    for z in zones:
        for y in years:
            if (27,z,y) in S and (31,z,y) in S:
                a=S[(27,z,y)]; b=S[(31,z,y)]
                f.write(f"{z}\t{y}\t{b[0]}\t{a[1]:.2f}\t{b[1]:.2f}\t{a[2]:.4f}\t{b[2]:.4f}\n")
print("\nwrote cv31_per_zone_year.tsv")
