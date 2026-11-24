"""Missing zone-days per arm (zone with no energy_prices rows on a market day; 39-zone footprint), and the same for
cv46 bf96-PR-74d9fc3 on the same days. usage: venv-ops431/bin/python -I zone_days.py >> post_records.md"""
import os, glob, duckdb
L = os.path.expanduser('~/armada/em-team/strategy/runs/st-impact/r2/long')
B = os.path.expanduser('~/armada/em-team/cv46-physics/runs/cp-runs/bf96-PR-74d9fc3/db')
FP = {"AT","BE","BG","CH","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4",
      "NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH",
      "IT-Calabria","IT-Sicily","IT-Sardinia"}
def missing(db):
    c = duckdb.connect(db, read_only=True)
    z = {r[0] for r in c.execute("select distinct bidding_zone from simulations.energy_prices").fetchall()}
    c.close(); return FP - z
res = {}
for src, root in (("base", f"{L}/base/db"), ("cand", f"{L}/cand/db"), ("cv46 bf96-PR", B)):
    days = sorted(os.path.basename(p)[:-7] for p in glob.glob(f"{L}/base/db/*.duckdb"))
    res[src] = {d: missing(f"{root}/{d}.duckdb") for d in days if os.path.exists(f"{root}/{d}.duckdb")}
print("\n## Missing zone-days (a zone whose book failed has no rows that day)\n")
for src, m in res.items():
    md = {d: z for d, z in m.items() if z}; n = sum(len(z) for z in md.values())
    byz = {}
    for z in md.values():
        for x in z: byz[x] = byz.get(x, 0) + 1
    print(f"- {src}: {len(m)} days, {n} missing zone-days on {len(md)} days; by zone {dict(sorted(byz.items()))}")
same = all(res["base"][d] == res["cand"].get(d) for d in res["base"])
print(f"- base and cand miss the same zone-days on every day: {same}")
print(f"- base and cv46 bf96-PR miss the same zone-days on every common day: "
      f"{all(res['base'][d] == res['cv46 bf96-PR'][d] for d in res['base'] if d in res['cv46 bf96-PR'])}")
print("- days: " + "; ".join(f"{d} {','.join(sorted(z))}" for d, z in res["base"].items() if z))
