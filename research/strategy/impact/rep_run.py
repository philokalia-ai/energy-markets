"""Replication on the fresh day set strategy/days_rep.txt (22 days, fixed by st-orch 02:03Z before any run).
No re-tuning: the frozen code of research/strategy/impact (unchanged since 610d6d4) is called as is; the hedge's error
paths are the 12 calibration days (robust.job uses every calibration day < D); nothing is chosen on these days.
usage: python -I rep_run.py robust          -> runs/st-impact/rep/robust_rep.csv
       python -I rep_run.py absorption      -> runs/st-impact/rep/absorption_rep.csv (2 h; GR, IT-SOUTH, NO2)
       python -I rep_run.py summary         -> runs/st-impact/rep/replication.md (eval vs replication, CIs)"""
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402
import strat as ST  # noqa: E402

REP = MV.ROOT / "runs/st-impact/rep"
DAYS = (MV.ROOT / "days_rep.txt").read_text().split()
ABS_ZONES = ["GR", "IT-SOUTH", "NO2"]


def run_robust():
    import robust as RB
    real = ST.realised_table()
    jobs = [(d, z, "bat", real, False) for d in DAYS for z in RB.BAT_ZONES] + \
           [(d, z, "hyd", real, False) for d in DAYS for z in RB.HYD_ZONES]
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(RB.job, jobs) for r in rs]
    pd.DataFrame(rows).to_csv(REP / "robust_rep.csv", index=False)
    print("robust rows", len(rows))


def run_absorption():
    import absorption as AB
    real = ST.realised_table()
    jobs = [(d, z, real, 2.0) for d in DAYS for z in ABS_ZONES]
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(AB.job, jobs) for r in rs]
    pd.DataFrame(rows).to_csv(REP / "absorption_rep.csv", index=False)
    print("absorption rows", len(rows), "zone-days", len({(r["day"], r["zone"]) for r in rows}))


def f(t):
    return f"{t[0]:+.1f} [{t[1]:+.1f}, {t[2]:+.1f}]"


def robust_table():
    ev = pd.read_csv(MV.ROOT / "runs/st-impact/strat/robust.csv")
    ev = ev[ev.day >= "2026-07-01"].assign(set="eval")
    rp = pd.read_csv(REP / "robust_rep.csv").assign(set="rep")
    D = pd.concat([ev, rp])
    L = ["| asset | zone | pen | robust − point: eval (23 d) | replication (22 d) | robust − unpriced: eval | replication | point − unpriced: eval | replication |",
         "|" + "---|" * 9]
    keep = {("battery", z) for z in ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]} | \
           {("hydro", z) for z in ["NO2", "IT-SOUTH", "ES"]}
    for (a, z, pen), g in D.groupby(["asset", "zone", "pen"]):
        if (a, z) not in keep:
            continue
        cells = []
        for x, y in (("robust", "point"), ("robust", "unpriced"), ("point", "unpriced")):
            for s in ("eval", "rep"):
                p = g[g.set == s].pivot(index="day", columns="arm", values="profit")
                cells.append(f(R.block_bootstrap_ci((p[x] - p[y]).values)) + f" ({len(p)})" if s == "rep" else
                             f(R.block_bootstrap_ci((p[x] - p[y]).values)))
        L.append(f"| {a} | {z} | {pen:.0f} | " + " | ".join(cells) + " |")
    return "\n".join(L)


def absorption_table():
    sys.argv = [sys.argv[0]]
    SZ = [100, 250, 500, 1000, 2000, 4000]

    def s_half(m):
        v0 = m[100] / 100.0
        mids, marg = [], []
        for a, b in zip(SZ[:-1], SZ[1:]):
            mids.append((a + b) / 2); marg.append((m[b] - m[a]) / (b - a))
        for i, x in enumerate(marg):
            if x <= 0.5 * v0:
                if i == 0:
                    return mids[0]
                x0, x1, y0, y1 = mids[i - 1], mids[i], marg[i - 1], x
                return x0 + (x1 - x0) * (y0 - 0.5 * v0) / (y0 - y1)
        return np.inf

    def stats(d):
        P = d.pivot(index="day", columns="S", values="profit")
        rng = np.random.default_rng(3)
        bs = np.array([s_half(P.iloc[rng.integers(0, len(P), len(P))].mean()) for _ in range(2000)])
        lo, hi = np.quantile(bs, [0.05, 0.95])
        m = P.mean()
        return s_half(m), lo, hi, m[100] / 100, m[1000] / 1000, m[4000] / 4000, len(P)

    fs = lambda x: ">4000" if not np.isfinite(x) else f"{x:,.0f}"  # noqa: E731
    ev = pd.read_csv(MV.ROOT / "runs/st-impact/strat/absorption.csv")
    ev = ev[ev.day >= "2026-07-01"]
    rp = pd.read_csv(REP / "absorption_rep.csv")
    L = ["| zone | arm | half-value S, eval (23 d) | replication | €/MW-day at 100 / 1000 / 4000 MW: eval | replication |",
         "|---|---|---|---|---|---|"]
    for z in ABS_ZONES:
        for arm in ("competitive", "naive"):
            a = stats(ev[(ev.zone == z) & (ev.arm == arm)])
            g = rp[(rp.zone == z) & (rp.arm == arm)]
            b = stats(g) if len(g) else (np.nan,) * 7
            L.append(f"| {z} | {arm} | {fs(a[0])} [{fs(a[1])}, {fs(a[2])}] | "
                     + (f"{fs(b[0])} [{fs(b[1])}, {fs(b[2])}] ({b[6]} d)" if len(g) else "not run")
                     + f" | {a[3]:.0f} / {a[4]:.0f} / {a[5]:.0f} | "
                     + (f"{b[3]:.0f} / {b[4]:.0f} / {b[5]:.0f}" if len(g) else "–") + " |")
    return "\n".join(L)


if __name__ == "__main__":
    REP.mkdir(parents=True, exist_ok=True)
    what = sys.argv[1]
    if what == "robust":
        run_robust()
    elif what == "absorption":
        run_absorption()
    else:
        parts = ["### Robust curves (price-taker, realised SDAC, €/MW-day; Δ with day-block 90% CI)", robust_table()]
        if (REP / "absorption_rep.csv").exists():
            parts += ["### Storage absorption, 2 h (half-value size, MW; 90% CI)", absorption_table()]
        txt = "\n\n".join(parts)
        (REP / "replication.md").write_text(txt + "\n")
        print(txt)
