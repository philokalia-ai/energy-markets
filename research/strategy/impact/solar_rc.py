"""Reclear check of the PV cannibalisation curve: PV offered at 0 €/MWh (S = 4000 MWp, 2026-09-13), 4 zones.
jobs: python -I solar_rc.py jobs ; check: python -I solar_rc.py check"""
import json, sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R, strat as ST, solar as SO  # noqa: E402
RC = MV.ROOT / "runs/st-impact/rc"
day, S = "2026-09-13", 4000
names = [f"{day}_{z}_{S}_pv" for z in SO.ZONES]
if sys.argv[1] == "jobs":
    inp = json.loads((SO.INP / f"{day}.json").read_text())
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    for z, n in zip(SO.ZONES, names):
        rd = ST.load_rd(day, z)
        cf = np.clip(np.array(inp["solar_fc"][z], float) / inp["solar_peak365"][z], 0, 1)
        pz = pb[pb.zone == z].set_index("hour_utc").price
        rows, pred = [], []
        for h in range(24):
            g = S * cf[h]
            c = R.ResidualDemand.from_injection_curve([a for a, _ in rd[h]], [b for _, b in rd[h]], ST.price_grid(rd[h], [float(pz[h]), 0.0]))
            p, q = R.clear_offer(c, g * (c.p >= 0.0))
            if g > 1e-6:
                rows.append((day, z, h, "offer", 0.0, float(g)))
            pred.append((h, p, q, float(pz[h])))
        pd.DataFrame(rows, columns=["day", "zone", "hour", "kind", "price", "mw"]).to_csv(RC / f"{n}.csv", index=False)
        pd.DataFrame(pred, columns=["hour", "pred_price", "pred_q", "p_base"]).to_csv(RC / f"{n}.pred.csv", index=False)
    print(",".join(names))
else:
    import subprocess
    print(subprocess.run([sys.executable, "-I", str(Path(__file__).parent / "rc_compare.py"), *names], capture_output=True, text=True).stdout)
