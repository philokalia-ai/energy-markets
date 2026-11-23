"""Write full-reclear check jobs for strategic optima. usage: python -I rc_jobs.py day zone S arm[,arm..]
Each job = runs/st-impact/rc/<day>_<zone>_<S>_<arm>.csv (offer rows from the step curve's increments; carve rows
= the company's own book orders) + .pred.csv (the optimiser's predicted zone price and company volume per hour)."""
import sys
from pathlib import Path
import duckdb, numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, strat as ST, rdopt as R  # noqa: E402

RC = MV.ROOT / "runs/st-impact/rc"
RC.mkdir(parents=True, exist_ok=True)
day, zone, S = sys.argv[1], sys.argv[2], int(sys.argv[3])
arms = sys.argv[4].split(",")
con = duckdb.connect(str(Path.home() / "armada/em-data/euphemia-live-20261115.duckdb"), read_only=True)
fuel = MV.registry_fuel(con)
real = ST.realised_table()
CAL = (MV.ROOT / "days_cal.txt").read_text().split()
errs = ST.calib_errors(CAL, [zone], real) if day >= "2026-07-01" else None
tg = MV.load_tagged(day, [zone], fuel)
pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
keep = {}
rows = pd.DataFrame(ST.run_zone_day(day, zone, tg, pb, {zone: real[(zone, day)]}, errors=errs, sizes=[S],
                                    keep=keep, only_arms=set(arms)))
names = []
for a in arms:
    out, pred = [], []
    for h in range(24):
        if (S, h, a) not in keep:
            continue
        pg, x = keep[(S, h, a)]
        x = np.maximum.accumulate(x)
        inc = np.diff(np.concatenate([[0.0], x]))
        for p, d in zip(pg, inc):
            if d > 1e-6:
                out.append((day, zone, h, "offer", round(float(p), 4), float(d)))
        for p, q in keep[(S, h, "carve")]:
            out.append((day, zone, h, "carve", float(p), float(q)))
        r = rows[(rows.hour == h) & (rows.arm == a)].iloc[0]
        pred.append((h, r.sim_price, r.sim_q, r.p_base))
    name = f"{day}_{zone}_{S}_{a}"
    pd.DataFrame(out, columns=["day", "zone", "hour", "kind", "price", "mw"]).to_csv(RC / f"{name}.csv", index=False)
    pd.DataFrame(pred, columns=["hour", "pred_price", "pred_q", "p_base"]).to_csv(RC / f"{name}.pred.csv", index=False)
    names.append(name)
print(",".join(names))
