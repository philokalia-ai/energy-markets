"""Reclear jobs for battery schedules. usage: python -I storage_rc_jobs.py day zone S -> job names"""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R, strat as ST, storage as SG  # noqa: E402
RC = MV.ROOT / "runs/st-impact/rc"
day, zone, S = sys.argv[1], sys.argv[2], int(sys.argv[3])
real = ST.realised_table()
rd = ST.load_rd(day, zone)
pb = pd.read_csv(MV.BASE / f"{day}.prices.csv"); pb = pb[pb.zone == zone].set_index("hour_utc").price
curves = [R.ResidualDemand.from_injection_curve([a for a, _ in rd[h]], [b for _, b in rd[h]],
                                                ST.price_grid(rd[h], [float(pb[h])])) for h in range(24)]
pbase = np.array([float(pb[h]) for h in range(24)])
names = []
for arm, kw in (("pricetaker", dict(impact=False, pt_prices=pbase)), ("strategic", {})):
    u, _, _ = R.energy_dp(curves, 0.0, 2.0 * S, S, S, SG.ETA, 0.0, de=S / 8.0, **kw)
    n = f"{day}_{zone}_{S}_bat_{arm}"
    pd.DataFrame([(day, zone, h, "inj", float(np.sign(x)), abs(float(x))) for h, x in enumerate(u)],
                 columns=["day", "zone", "hour", "kind", "price", "mw"]).to_csv(RC / f"{n}.csv", index=False)
    pd.DataFrame([(h, float(c.P(x)), float(x), pbase[h]) for h, (c, x) in enumerate(zip(curves, u))],
                 columns=["hour", "pred_price", "pred_q", "p_base"]).to_csv(RC / f"{n}.pred.csv", index=False)
    names.append(n)
print(",".join(names))
