"""Robust-curve tables: profit per MW-day by zone x arm (pen 0 / 10), Δ robust − point and robust − unpriced with day-block
90% CI; evaluation days (scenario paths = all 12 calibration days) and calibration days (earlier calibration paths only)."""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R  # noqa: E402
T = MV.ROOT / "runs/st-impact/tables"
d = pd.read_csv(MV.ROOT / "runs/st-impact/strat/robust.csv")
d["set"] = np.where(d.day >= "2026-07-01", "eval", "cal")
f = lambda t: f"{t[0]:+.1f} [{t[1]:+.1f}, {t[2]:+.1f}]"  # noqa: E731
L = ["| asset | zone | set | pen €/MWh | days | unpriced €/MW-d | point legs | robust curve | robust − point | robust − unpriced | point − unpriced | deviation MWh/d point → robust |",
     "|" + "---|" * 12]
for (a, z, st, pen), g in d.groupby(["asset", "zone", "set", "pen"]):
    if st == "cal":
        g = g[g.n_paths > 0]
    p = g.pivot(index="day", columns="arm", values="profit")
    dv = g.pivot(index="day", columns="arm", values="dev_mwh")
    if p.empty:
        continue
    L.append(f"| {a} | {z} | {st} | {pen:.0f} | {len(p)} | {p.unpriced.mean():.1f} | {p.point.mean():.1f} | {p.robust.mean():.1f} | "
             f"{f(R.block_bootstrap_ci((p.robust - p.point).values))} | {f(R.block_bootstrap_ci((p.robust - p.unpriced).values))} | "
             f"{f(R.block_bootstrap_ci((p.point - p.unpriced).values))} | {dv.point.mean():.2f} → {dv.robust.mean():.2f} |")
txt = "\n".join(L)
(T / "robust.md").write_text(txt + "\n")
print(txt)
