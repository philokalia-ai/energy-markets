#!/usr/bin/env python3
"""st-blocks impact scorer (re-clear of our baseline book with the company's orders).

usage: ~/armada/em-team/venv-ops431/bin/python -I score_imp.py IMP.csv [IMP2.csv ...] [--json OUT] [--draws 10000] [--seed 4646]

Per (zone, archetype, size, format), over the days present:
  Δp zone        mean over days of the zone's mean price change vs our baseline forecast (€/MWh, 24 h)
  Δp vs bench    the same minus the benchmark format's Δp on the same day/size: what the FORMAT moves, net of the
                 carve-out (thermal/hydro replace the same MW of baseline supply; storage is added)
  max|Δp|        mean over days of the largest hourly |Δp| in the zone
  neighbours     zones with mean |Δp| > 1 €/MWh on ≥ 1/3 of the days
  profit sim     €/MW-day at the simulated prices with the clear's own acceptance (true costs, as in the price-taker)
  Δ profit       vs the benchmark format, day-block bootstrap 90% (same method as score_pt.py)
  profit@fcst    price-taker profit at our (unmoved) forecast: profit sim − profit@fcst = the price-impact cost
  accepted       share of days with ≥ 1 block family accepted; PRB = share of days with a paradoxically rejected
                 family (in the money at the simulated prices, eligible, rejected); MAR ratio = mean accepted ratio
Benchmarks: thermal hourly_mc; storage hourly_sched (the unpriced schedule) and hourly_oc; hydro hourly_oc.
"""
import argparse, json
import numpy as np
import pandas as pd

BENCH = {"CCGT": "hourly_mc", "COAL": "hourly_mc", "HYDRO": "hourly_oc", "PSP": "hourly_sched", "BESS": "hourly_sched"}


def boot(x, draws, seed):
    x = np.asarray(x, float)
    if len(x) == 0:
        return np.nan, np.nan
    idx = np.random.default_rng(seed).integers(0, len(x), size=(draws, len(x)))
    m = x[idx].mean(1)
    return float(np.percentile(m, 5)), float(np.percentile(m, 95))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="+"); ap.add_argument("--json")
    ap.add_argument("--draws", type=int, default=10000); ap.add_argument("--seed", type=int, default=4646)
    a = ap.parse_args()
    d = pd.concat([pd.read_csv(f) for f in a.csv], ignore_index=True)
    d = d[d.status.isin(["optimal", "time_limit"])]
    d["mr"] = pd.to_numeric(d.mar_ratio, errors="coerce")
    rows = []
    for (z, ar, s), g in d.groupby(["zone", "arch", "size"]):
        bf = BENCH[ar]
        b = g[g.format == bf].set_index("day")
        cap = float(g.cap_mw.iloc[0])
        for f, h in g.groupby("format"):
            h = h.set_index("day")
            days = sorted(set(h.index) & set(b.index))
            if not days:
                continue
            dpf = h.loc[days, "dp_mean"] - b.loc[days, "dp_mean"]
            dpr = (h.loc[days, "profit_sim"] - b.loc[days, "profit_sim"]) / cap
            lo, hi = boot(dpr.to_numpy(), a.draws, a.seed) if f != bf else (0.0, 0.0)
            nb = {}
            for v in h.loc[days, "neigh"]:
                if isinstance(v, str) and v != "-":
                    for t in v.split(";"):
                        nb[t.split(":")[0]] = nb.get(t.split(":")[0], 0) + 1
            nbs = ",".join(sorted(k for k, c in nb.items() if c >= len(days) / 3)) or "-"
            blk = not f.startswith("hourly")
            rows.append(dict(zone=z, arch=ar, size=s, format=f, bench=bf, days=len(days),
                             dp=h.loc[days, "dp_mean"].mean(), dpf=dpf.mean(), dpmax=h.loc[days, "dp_maxabs"].mean(),
                             neigh=nbs, psim=(h.loc[days, "profit_sim"] / cap).mean(),
                             pfc=(h.loc[days, "profit_base"] / cap).mean(), dprof=dpr.mean(), lo=lo, hi=hi,
                             acc=(h.loc[days, "n_fam_acc"] > 0).mean() if blk else np.nan,
                             prb=(h.loc[days, "prb"] > 0).mean() if blk else np.nan,
                             mar=h.loc[days, "mr"].mean() if f == "mar" else np.nan,
                             unf=h.loc[days, "unfilled_h"].mean(), short=h.loc[days, "carve_short"].max()))
    t = pd.DataFrame(rows)
    print(f"st-blocks impact score: rows {len(d)}, days {d.day.nunique()}, draws {a.draws}, seed {a.seed}")
    print(f"carve shortfall max over all rows: {t.short.max():.1f} MW")
    f1 = lambda v, n=2: "—" if pd.isna(v) else f"{v:.{n}f}"
    for (z, ar), g in t.groupby(["zone", "arch"]):
        print(f"\n#### {z} {ar} (benchmark {g.bench.iloc[0]})")
        print("| size | format | days | Δp zone | Δp vs bench | max abs Δp | neighbours | profit sim €/MW-d | profit@fcst | Δ profit vs bench [90%] | accepted | PRB days | MAR ratio | unfilled h |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in g.sort_values(["size", "format"], ascending=[False, True]).itertuples():
            print(f"| {r.size:.0f}x | {r.format} | {r.days} | {r.dp:+.2f} | {r.dpf:+.2f} | {r.dpmax:.1f} | {r.neigh} | "
                  f"{r.psim:.1f} | {r.pfc:.1f} | {r.dprof:+.1f} [{r.lo:+.1f},{r.hi:+.1f}] | {f1(r.acc)} | {f1(r.prb)} | "
                  f"{f1(r.mar)} | {r.unf:.1f} |")
    if a.json:
        t.to_json(a.json, orient="records", indent=1)


if __name__ == "__main__":
    main()
