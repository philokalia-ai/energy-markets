"""Absorption tables (evaluation days): €/MW-day, capture spread, zone-spread compression, marginal MW value and the
size at which it halves; competitive vs naive. Day-block bootstrap for the per-MW value and the half-value size."""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R  # noqa: E402
T = MV.ROOT / "runs/st-impact/tables"
FN = sys.argv[1] if len(sys.argv) > 1 else "absorption.csv"
d = pd.read_csv(MV.ROOT / "runs/st-impact/strat" / FN)
d = d[d.day >= "2026-07-01"]
SZ = [100, 250, 500, 1000, 2000, 4000]


def s_half(prof_by_S):
    """prof_by_S: mean daily profit per S. Marginal €/MW-day between grid sizes; first S (interpolated on the
    segment midpoints) where it falls to half the average value of the first 100 MW."""
    v0 = prof_by_S[100] / 100.0
    mids, marg = [], []
    for a, b in zip(SZ[:-1], SZ[1:]):
        mids.append((a + b) / 2); marg.append((prof_by_S[b] - prof_by_S[a]) / (b - a))
    for i, m in enumerate(marg):
        if m <= 0.5 * v0:
            if i == 0:
                return mids[0]
            x0, x1, y0, y1 = mids[i - 1], mids[i], marg[i - 1], m
            return x0 + (x1 - x0) * (y0 - 0.5 * v0) / (y0 - y1)
    return np.inf


lines = ["| zone | arm | €/MW-day at 100 / 1000 / 4000 MW | marginal €/MW-day 2000→4000 | S where the marginal MW is worth half (90% CI) | capture spread €/MWh 100 → 4000 | zone top2−bottom2 spread: base → with 1 GW → with 4 GW |",
         "|---|---|---|---|---|---|---|"]
rng = np.random.default_rng(3)
for z in [z for z in ["GR", "IT-SOUTH", "ES", "NO2", "FR", "DE_LU"] if z in set(d.zone)]:
    for arm in ["competitive", "naive"]:
        g = d[(d.zone == z) & (d.arm == arm)]
        P = g.pivot(index="day", columns="S", values="profit")
        m = P.mean()
        sh = s_half(m)
        bs = []
        for _ in range(2000):
            idx = rng.integers(0, len(P), len(P))
            bs.append(s_half(P.iloc[idx].mean()))
        bs = np.array(bs)
        lo, hi = np.quantile(bs, [0.05, 0.95])
        cap = g.groupby("S").capture_spread.mean()
        zs = g.groupby("S").zone_spread.mean(); zs0 = g.zone_spread_base.mean()
        fmtS = lambda x: ">4000" if not np.isfinite(x) else f"{x:,.0f}"  # noqa: E731
        lines.append(f"| {z} | {arm} | {m[100]/100:.0f} / {m[1000]/1000:.0f} / {m[4000]/4000:.0f} | "
                     f"{(m[4000]-m[2000])/2000:.0f} | {fmtS(sh)} [{fmtS(lo)}, {fmtS(hi)}] | {cap[100]:.0f} → {cap[4000]:.0f} | "
                     f"{zs0:.0f} → {zs[1000]:.0f} → {zs[4000]:.0f} |")
txt = "\n".join(lines)
(T / FN.replace(".csv", ".md")).write_text(txt + "\n")
print(txt)
