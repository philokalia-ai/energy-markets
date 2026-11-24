"""Storage absorption by zone (st-impact, owner addendum 22:35Z): how much 2 h storage a zone absorbs before spreads
collapse, with every battery MW bidding cost-reflectively.

Asset: new battery S MW / 2S MWh, round-trip η 0.88 (DESIGN.md STOR), empty at the start and end of the day; nothing
carved (new capacity), so its curve is the uncarved residual demand D0 (charging = negative q).
  competitive   legs priced at opportunity cost and cleared by the market: the schedule maximising Σ ∫_0^{u_t} P_t
                (welfare) — at the prices it causes it is price-taker optimal, i.e. no MW is held back to hold prices
  naive         the price-taker schedule optimal at our forecast prices (no impact), submitted as a fixed schedule
Metrics per (day, zone, S, arm): profit on our curves (€/day, €/MW-day), capture spread (discharge- minus
charge-weighted price), zone spread (mean of the top-2 minus bottom-2 hourly prices) with vs without the battery,
throughput; and the same schedule on realised prices (price-taker) and realised + impact.
usage: python -I absorption.py  -> runs/st-impact/strat/absorption.csv
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

ETA = 0.88
SIZES = [100, 250, 500, 1000, 2000, 4000]
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]


def spread2(p):
    s = np.sort(p)
    return float(s[-2:].mean() - s[:2].mean())


def curves_for(day, zone):
    rd = ST.load_rd(day, zone)
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    pb = pb[pb.zone == zone].set_index("hour_utc").price
    if rd is None or len(rd) < 24:
        return None, None
    pbase = np.array([float(pb[h]) for h in range(24)])
    cs = [R.ResidualDemand.from_injection_curve([a for a, _ in rd[h]], [b for _, b in rd[h]],
                                                ST.price_grid(rd[h], [pbase[h]])) for h in range(24)]
    return cs, pbase


def job(args):
    day, zone, real, dur = args
    cs, pbase = curves_for(day, zone)
    rr = real.get((zone, day), {})
    if cs is None or len(rr) < 24:
        return []
    preal = np.array([float(rr[h]) for h in range(24)])
    e = preal - pbase
    out = []
    for S in SIZES:
        de = S / 8.0
        u_c, _, _ = R.energy_dp(cs, 0.0, dur * S, S, S, ETA, 0.0, de=de, objective="welfare")
        u_n, _, _ = R.energy_dp(cs, 0.0, dur * S, S, S, ETA, 0.0, de=de, impact=False, pt_prices=pbase)
        for arm, u in (("competitive", u_c), ("naive", u_n)):
            P = np.array([c.P(x) for c, x in zip(cs, u)])
            d, c = np.maximum(u, 0), np.maximum(-u, 0)
            cap = (P @ d / d.sum() - P @ c / c.sum()) if d.sum() > 1e-6 and c.sum() > 1e-6 else 0.0
            out.append(dict(day=day, zone=zone, S=S, dur_h=dur, arm=arm, profit=float(P @ u), per_mw_day=float(P @ u) / S,
                            capture_spread=float(cap), zone_spread_base=spread2(pbase), zone_spread=spread2(P),
                            throughput_mwh=float(d.sum()), pt_real=float(preal @ u), imp_real=float((P + e) @ u),
                            dp_mean_abs=float(np.mean(np.abs(P - pbase)))))
    return out


if __name__ == "__main__":
    # usage: python -I absorption.py [DUR_H [ZONES]]  (default 2 h, all 6 zones -> absorption.csv; else absorption_<D>h.csv)
    dur = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
    zones = sys.argv[2].split(",") if len(sys.argv) > 2 else ZONES
    real = ST.realised_table()
    days = (MV.ROOT / "days_cal.txt").read_text().split() + (MV.ROOT / "days_eval.txt").read_text().split()
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(job, [(d, z, real, dur) for d in days for z in zones]) for r in rs]
    name = "absorption.csv" if dur == 2.0 and len(sys.argv) <= 1 else f"absorption_{dur:g}h.csv"
    pd.DataFrame(rows).to_csv(MV.ROOT / "runs/st-impact/strat" / name, index=False)
    print(len(rows))
