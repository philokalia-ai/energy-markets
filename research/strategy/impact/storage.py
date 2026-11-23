"""Part A, storage: strategic vs price-taker shifting of a NEW battery (st-impact).

Asset (DESIGN.md §2 STOR archetype, scaled): S MW / 2·S MWh, round-trip efficiency 0.88, starts and ends the day
empty. It is new capacity (nothing carved), so its residual demand is the uncarved curve D0 (q < 0 = charging buys).
  pricetaker  the schedule optimal at our forecast prices p_base,t (price-taker), then cleared on the curves
  strategic   the schedule optimal against the curves with its own price impact (charging raises, discharging
              lowers the price)
Scores: sim (curves), pt_real (schedule fixed, realised prices), imp_real (curve shifted by the realised error).
Days/zones: every day with a curve; usage: python -I storage.py -> runs/st-impact/strat/storage.csv
"""
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402
import strat as ST  # noqa: E402

ETA = 0.88  # DESIGN.md §2 battery round-trip efficiency
SIZES = [250, 1000]
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]


def job(args):
    day, zone, real = args
    rd = ST.load_rd(day, zone)
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    pb = pb[pb.zone == zone].set_index("hour_utc").price
    rr = real.get((zone, day), {})
    hours = [h for h in range(24) if rd and h in rd and h in pb.index and h in rr]
    if len(hours) < 24:
        return []
    curves = []
    for h in hours:
        pg = ST.price_grid(rd[h], [float(pb[h]), float(rr[h])])
        curves.append(R.ResidualDemand.from_injection_curve([a for a, _ in rd[h]], [b for _, b in rd[h]], pg))
    pbase = np.array([float(pb[h]) for h in hours])
    preal = np.array([float(rr[h]) for h in hours])
    e = preal - pbase
    out = []
    for S in SIZES:
        E = 2.0 * S
        de = S / 8.0
        u_pt, _, _ = R.energy_dp(curves, 0.0, E, S, S, ETA, 0.0, de=de, impact=False, pt_prices=pbase)
        u_st, _, _ = R.energy_dp(curves, 0.0, E, S, S, ETA, 0.0, de=de)
        for arm, u in (("pricetaker", u_pt), ("strategic", u_st)):
            psim = np.array([c.P(x) for c, x in zip(curves, u)])
            out.append(dict(day=day, zone=zone, S=S, arm=arm, throughput_mwh=float(np.maximum(u, 0).sum()),
                            sim_profit=float((psim * u).sum()), pt_profit=float((preal * u).sum()),
                            imp_profit=float(((psim + e) * u).sum()), fcst_profit=float((pbase * u).sum()),
                            spread_sim=float(psim.max() - psim.min())))
    return out


if __name__ == "__main__":
    real = ST.realised_table()
    days = (MV.ROOT / "days_cal.txt").read_text().split() + (MV.ROOT / "days_eval.txt").read_text().split()
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(job, [(d, z, real) for d in days for z in ZONES]) for r in rs]
    pd.DataFrame(rows).to_csv(MV.ROOT / "runs/st-impact/strat/storage.csv", index=False)
    print(len(rows))
