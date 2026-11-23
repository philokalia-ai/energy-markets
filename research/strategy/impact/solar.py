"""Solar cannibalisation (st-impact, owner addendum): a NEW PV portfolio of S MWp in ES, GR, IT-SOUTH, DE_LU bidding at
its marginal cost (0 €/MWh: offered whenever the price is >= 0, curtailed below), against our residual-demand curves.
Shape: the zone's D-1 day-ahead solar forecast (st-blocks inputs, runs/st-blocks/inputs/<day>.json, published before
the gate) divided by the zone's max hourly D-1 solar forecast over the 365 days before D (`solar_peak365`, ex-ante
capacity proxy) -> capacity factor cf_t; generation offered g_t = S * cf_t.
Co-located battery: S/2 MW, 2 h (S MWh), η 0.88, competitive dispatch (legs at opportunity cost, absorption.py) on the
curve AFTER the PV injection (P_t(g_t + u)); it charges from the grid or the plant alike.
Outputs per (day, zone, S): capture price (Σ P q / Σ q), baseload price with the PV, capture rate (capture / baseload
of the base case without PV), curtailed MWh, revenue per MWp-day; with battery: PV capture, battery revenue, combined.
usage: python -I solar.py  -> runs/st-impact/strat/solar.csv
"""
import json
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402
import strat as ST  # noqa: E402

ZONES = ["ES", "GR", "IT-SOUTH", "DE_LU"]
SIZES = [100, 250, 500, 1000, 2000, 4000]
ETA = 0.88
INP = MV.ROOT / "runs/st-blocks/inputs"


def job(args):
    day, zone, real = args
    rd = ST.load_rd(day, zone)
    f = INP / f"{day}.json"
    if rd is None or len(rd) < 24 or not f.exists():
        return []
    inp = json.loads(f.read_text())
    if zone not in inp.get("solar_fc", {}) or not inp.get("solar_peak365", {}).get(zone):
        return []
    cf = np.clip(np.array(inp["solar_fc"][zone], float) / inp["solar_peak365"][zone], 0, 1)
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    pb = pb[pb.zone == zone].set_index("hour_utc").price
    pbase = np.array([float(pb[h]) for h in range(24)])
    rr = real.get((zone, day), {})
    preal = np.array([float(rr.get(h, np.nan)) for h in range(24)])
    qs = [[a for a, _ in rd[h]] for h in range(24)]
    ps = [[b for _, b in rd[h]] for h in range(24)]
    out = []
    for S in SIZES:
        g = S * cf
        P, q = np.zeros(24), np.zeros(24)
        for h in range(24):
            c = R.ResidualDemand.from_injection_curve(qs[h], ps[h], ST.price_grid(rd[h], [pbase[h], 0.0]))
            pg = c.p
            P[h], q[h] = R.clear_offer(c, g[h] * (pg >= 0.0))
        cap = float(P @ q / q.sum()) if q.sum() > 0 else np.nan
        row = dict(day=day, zone=zone, S=S, cf_mean=float(cf.mean()), gen_mwh=float(q.sum()), curt_mwh=float((g - q).sum()),
                   capture=cap, base_avg=float(pbase.mean()), base_solar_wavg=float(pbase @ cf / cf.sum()) if cf.sum() > 0 else np.nan,
                   avg_with=float(P.mean()), rev_per_mwp_day=float(P @ q) / S,
                   capture_real_pt=float(np.nansum(preal * q) / q.sum()) if q.sum() > 0 else np.nan,
                   capture_real_imp=float(np.nansum((P + preal - pbase) * q) / q.sum()) if q.sum() > 0 else np.nan)
        # co-located battery on the post-PV curve (PV treated as a fixed injection q_t for the battery stage)
        B = S / 2.0
        cs = [R.ResidualDemand.from_injection_curve(np.array(qs[h]) - q[h], ps[h], ST.price_grid(rd[h], [pbase[h], 0.0]))
              for h in range(24)]
        u, _, _ = R.energy_dp(cs, 0.0, 2.0 * B, B, B, ETA, 0.0, de=B / 8.0, objective="welfare")
        Pb = np.array([c.P(x) for c, x in zip(cs, u)])
        row.update(capture_with_bat=float(Pb @ q / q.sum()) if q.sum() > 0 else np.nan,
                   bat_rev=float(Pb @ u), pv_rev_with_bat=float(Pb @ q),
                   combined_per_mwp_day=float(Pb @ q + Pb @ u) / S)
        out.append(row)
    return out


if __name__ == "__main__":
    real = ST.realised_table()
    days = (MV.ROOT / "days_cal.txt").read_text().split() + (MV.ROOT / "days_eval.txt").read_text().split()
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(job, [(d, z, real) for d in days for z in ZONES]) for r in rs]
    pd.DataFrame(rows).to_csv(MV.ROOT / "runs/st-impact/strat/solar.csv", index=False)
    print(len(rows))
