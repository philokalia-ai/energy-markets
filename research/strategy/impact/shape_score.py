"""Experiment 2 scorer (physics-only, the cv46 way). usage:
  python -I shape_score.py fit                     -> calibration days: MAE per arm (base, 0, 0.25, 0.5, 0.75) -> alpha*
  python -I shape_score.py eval ARM_CAND           -> evaluation + replication days: candidate vs base, per region, CIs
Prices: runs/st-impact/r2/shape/<arm>/<day>.prices.csv (96 quarters) -> hourly mean per UTC hour.
Actual: bin/da_target.py hourly_actuals(target="sdac"); naive = actual at t - 24 h; rMAE = MAE / MAE(naive), same cells
(score_2y.py). Regions = score_cv46.py's 7. Day-block bootstrap of the cell-weighted ΔMAE (10,000 draws, seed 4646;
score_cv46.py boot()). Shape = error after de-meaning model and actual per (day, zone)."""
import datetime as dt
import json
import os
import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "bin"))
import da_target  # noqa: E402

ROOT = Path.home() / "armada/em-team/strategy"
SH = ROOT / "runs/st-impact/r2/shape"
DB = os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb")
CE = "AT DE_LU CZ HU SK PL SI NL BE FR CH".split()
REGIONS = {"CE": CE, "SEE": ["BG", "RO", "GR", "RS"],
           "Italy": ["IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria", "IT-Sicily", "IT-Sardinia"],
           "Iberia": ["ES", "PT"], "Nordic north": ["NO3", "NO4", "SE1", "SE2", "FI"],
           "Nordic south": ["NO1", "NO2", "NO5", "SE3", "SE4", "DK1", "DK2"], "Baltics": ["EE", "LV", "LT"]}
ZREG = {z: r for r, zs in REGIONS.items() for z in zs}
ARMS_FIT = ["base", "0.0", "0.25", "0.5", "0.75"]


def actuals(days):
    con = duckdb.connect(DB, read_only=True)
    out = []
    for d in days:
        D = dt.date.fromisoformat(d)
        t0 = dt.datetime.combine(D - dt.timedelta(days=1), dt.time()); t1 = dt.datetime.combine(D + dt.timedelta(days=1), dt.time())
        ha = da_target.hourly_actuals(con, t0, t1, target="sdac")
        zc = "z" if "z" in ha.columns else "zone"
        ha = ha.rename(columns={zc: "zone", ha.columns[-1]: "act"})[["zone", "t", "act"]]
        ha["t"] = pd.to_datetime(ha.t)
        nv = ha.assign(t=ha.t + pd.Timedelta(days=1)).rename(columns={"act": "naive"})
        a = ha.merge(nv, on=["zone", "t"])
        out.append(a[a.t.dt.date == D].assign(day=d))
    con.close()
    return pd.concat(out)


def prices(arm, days):
    rows = []
    for d in days:
        f = SH / arm / f"{d}.prices.csv"
        if not f.exists():
            continue
        p = pd.read_csv(f)
        p["t"] = pd.Timestamp(d) + pd.to_timedelta(p.hour_utc, unit="h")
        rows.append(p.groupby(["zone", "t"]).price.mean().reset_index().rename(columns={"price": arm}).assign(day=d))
    return pd.concat(rows) if rows else pd.DataFrame(columns=["zone", "t", arm, "day"])


def boot(day_codes, diff, nd, draws=10000, seed=4646):
    S = np.bincount(day_codes, weights=diff, minlength=nd); N = np.bincount(day_codes, minlength=nd).astype(float)
    rng = np.random.default_rng(seed); out = np.empty(draws)
    for i in range(0, draws, 1000):
        idx = rng.integers(0, nd, size=(min(1000, draws - i), nd)); out[i:i + len(idx)] = S[idx].sum(1) / N[idx].sum(1)
    return float(np.percentile(out, 5)), float(np.percentile(out, 95))


def metrics(d, x, ref):
    d = d[np.isfinite(d.act) & np.isfinite(d.naive) & np.isfinite(d[x]) & np.isfinite(d[ref])]
    ex, er, en = (d[x] - d.act).abs(), (d[ref] - d.act).abs(), (d.naive - d.act).abs()
    codes, uniq = pd.factorize(d.day)
    lo, hi = boot(codes, (ex - er).to_numpy(), len(uniq))
    g = [d.day, d.zone]; dm = lambda s: s - s.groupby(g).transform("mean")  # noqa: E731
    sa = dm(d.act)
    return dict(cells=len(d), days=int(d.day.nunique()), mae_ref=er.mean(), mae=ex.mean(), dmae=ex.mean() - er.mean(),
                lo=lo, hi=hi, rmae_ref=er.mean() / en.mean(), rmae=ex.mean() / en.mean(),
                bias_ref=(d[ref] - d.act).mean(), bias=(d[x] - d.act).mean(),
                shape_ref=(dm(d[ref]) - sa).abs().mean(), shape=(dm(d[x]) - sa).abs().mean(),
                level_ref=(lambda lv: (lv[ref] - lv.act).abs().mean())(d.groupby(g)[[ref, "act"]].mean()),
                level=(lambda lv: (lv[x] - lv.act).abs().mean())(d.groupby(g)[[x, "act"]].mean()))


def table(d, x, ref, title):
    L = [f"#### {title}", "| unit | days | cells | rMAE base → cand | MAE base → cand | ΔMAE [90 %] | bias base → cand | shape base → cand | level base → cand |",
         "|---|---|---|---|---|---|---|---|---|"]
    units = [("pooled", d)] + [(r, d[d.zone.map(ZREG) == r]) for r in REGIONS]
    res = {}
    for name, g in units:
        if g.empty:
            continue
        m = metrics(g, x, ref); res[name] = m
        L.append(f"| {name} | {m['days']} | {m['cells']} | {m['rmae_ref']:.4f} → {m['rmae']:.4f} | {m['mae_ref']:.2f} → {m['mae']:.2f} | "
                 f"{m['dmae']:+.3f} [{m['lo']:+.3f}, {m['hi']:+.3f}] | {m['bias_ref']:+.2f} → {m['bias']:+.2f} | "
                 f"{m['shape_ref']:.2f} → {m['shape']:.2f} | {m['level_ref']:.2f} → {m['level']:.2f} |")
    worse = [r for r, m in res.items() if r != "pooled" and m["lo"] > 0]
    bar = res["pooled"]["hi"] < 0 and not worse
    L.append(f"\nBar (pooled interval below 0, no region significantly worse): **{'PASS' if bar else 'FAIL'}**"
             + (f" — significantly worse: {', '.join(worse)}" if worse else ""))
    return "\n".join(L), res, bar


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "fit":
        days = (ROOT / "days_cal.txt").read_text().split()
        A = actuals(days)
        d = A
        for arm in ARMS_FIT:
            d = d.merge(prices(arm, days)[["zone", "t", arm]], on=["zone", "t"], how="inner")
        L = ["| arm | days | cells | MAE | rMAE | ΔMAE vs base [90 %] | shape |", "|---|---|---|---|---|---|---|"]
        best = None
        for arm in ARMS_FIT:
            m = metrics(d, arm, "base")
            L.append(f"| {arm} | {m['days']} | {m['cells']} | {m['mae']:.3f} | {m['rmae']:.4f} | {m['dmae']:+.3f} [{m['lo']:+.3f}, {m['hi']:+.3f}] | {m['shape']:.2f} |")
            if arm != "base" and (best is None or m["mae"] < best[1]):
                best = (arm, m["mae"])
        mb = metrics(d, "base", "base")["mae"]
        pick = best[0] if best[1] < mb else "base"
        L.append(f"\nalpha* = **{pick}** (lowest calibration MAE; 'base' = alpha 1, the status quo)")
        txt = "\n".join(L); (ROOT / "runs/st-impact/r2/fit.md").write_text(txt + "\n"); print(txt)
    else:
        cand = sys.argv[2]
        out = []
        allres = {}
        for label, f in (("evaluation (23 days)", "days_eval.txt"), ("replication (22 days)", "days_rep.txt"),
                         ("evaluation + replication", None)):
            days = (ROOT / f).read_text().split() if f else (ROOT / "days_eval.txt").read_text().split() + (ROOT / "days_rep.txt").read_text().split()
            d = actuals(days).merge(prices("base", days)[["zone", "t", "base"]], on=["zone", "t"]).merge(
                prices(cand, days)[["zone", "t", cand]], on=["zone", "t"])
            t, res, bar = table(d, cand, "base", f"{label}: ShapeConduct({cand}) vs TranchesConduct")
            out.append(t); allres[label] = {k: v for k, v in res.items()}
        txt = "\n\n".join(out)
        (ROOT / f"runs/st-impact/r2/eval_{cand}.md").write_text(txt + "\n")
        (ROOT / f"runs/st-impact/r2/eval_{cand}.json").write_text(json.dumps(allres, default=float))
        print(txt)
