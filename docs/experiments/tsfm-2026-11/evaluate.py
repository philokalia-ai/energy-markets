"""Score TSFM forecasts vs settled, the live lead-1 weather-track `sim`, and naive baselines.

Cells: 2026-09-14..2026-11-13 Athens market days, hours of the live lead-1 weather rows that have
a settled actual (the common set: every method must have a value). Reported on all 39 zones and
excluding the 7 IT-* zones. Collapse classification on the point forecast (median for TSFMs):
hit-rate = P(pred <= thr | actual <= thr), false-alarm ratio = P(actual > thr | pred <= thr).
Probabilistic: Brier score of P(price <= 0) and P(<= 5), AUC.

Usage: python evaluate.py fc_t209_uni fc_c2_uni ...   (files in $TSFM_OUT, without .parquet)
"""
import os, sys
import numpy as np, pandas as pd

OUT = os.environ.get("TSFM_OUT", "/home/pgeorgakopoulos/armada/em-team/results/tsfm")
START, END = os.environ.get("EVAL_START", "2026-09-14"), os.environ.get("EVAL_END", "2026-11-13")
CAL_DAYS = ["2026-09-16", "2026-09-20", "2026-09-27", "2026-10-06", "2026-10-19", "2026-11-04",
            "2026-11-09", "2026-11-13"]


def auc(score, y):
    y = np.asarray(y, bool); s = np.asarray(score, float)
    if y.sum() == 0 or (~y).sum() == 0:
        return np.nan
    r = pd.Series(s).rank().values
    return (r[y].sum() - y.sum() * (y.sum() + 1) / 2) / (y.sum() * (~y).sum())


def metrics(df, col, act="actual"):
    e = df[col] - df[act]
    out = dict(n=len(df), MAE=e.abs().mean(), bias=e.mean(), corr=df[col].corr(df[act]))
    # mean of per-zone correlations (removes the cross-zone level component of pooled corr)
    out["zcorr"] = df.groupby("zone").apply(lambda g: g[col].corr(g[act]), include_groups=False).mean()
    for thr in (0, 5):
        a, p = df[act] <= thr, df[col] <= thr
        out[f"n_act<={thr}"] = int(a.sum())
        out[f"hit<={thr}"] = (a & p).sum() / max(a.sum(), 1)
        out[f"FAR<={thr}"] = (p & ~a).sum() / p.sum() if p.sum() else np.nan
    return out


def load(names):
    panel = pd.read_parquet(f"{OUT}/panel.parquet")[["zone", "t", "price"]]
    live = pd.read_parquet(f"{OUT}/live_lead1.parquet")
    live = live[(live.input_mode == "weather") & (live.date >= START) & (live.date <= END)]
    df = live[["zone", "date", "t", "sim", "gbm", "stats", "code_version"]].merge(panel, on=["zone", "t"], how="left")
    df = df.rename(columns={"price": "actual"})
    pz = panel.set_index(["zone", "t"]).price
    for lag, nm in ((24, "naive_D1"), (48, "naive_D2"), (168, "naive_D7")):
        idx = pd.MultiIndex.from_arrays([df.zone, df.t - pd.Timedelta(hours=lag)])
        df[nm] = pz.reindex(idx).values
    prob = {}
    for n in names:
        f = pd.read_parquet(f"{OUT}/{n}.parquet")
        key = n.replace("fc_", "")
        f = f.rename(columns={"median": key, "p_le0": f"{key}_p0", "p_le5": f"{key}_p5",
                              "q10": f"{key}_q10", "q90": f"{key}_q90"})
        df = df.merge(f[["zone", "t", key, f"{key}_p0", f"{key}_p5", f"{key}_q10", f"{key}_q90"]],
                      on=["zone", "t"], how="left")
        prob[key] = key
    return df, list(prob)


def main(names):
    df, keys = load(names)
    methods = ["sim", "naive_D1", "naive_D2", "naive_D7"] + keys
    base = df.dropna(subset=["actual"] + methods)
    print(f"cells: live lead-1 weather {len(df)}, with actual {df.actual.notna().sum()}, "
          f"common set {len(base)} ({base.zone.nunique()} zones, {base.date.nunique()} days)")
    res = []
    for scope, sub in (("all39", base), ("exIT", base[~base.zone.str.startswith("IT-")])):
        for m in methods:
            r = dict(scope=scope, method=m, **metrics(sub, m))
            if m in keys:
                for thr in (0, 5):
                    y = sub.actual <= thr; p = sub[f"{m}_p{thr}"]
                    r[f"Brier<={thr}"] = ((p - y) ** 2).mean()
                    r[f"AUC<={thr}"] = auc(p, y)
                r["cov80"] = ((sub.actual >= sub[f"{m}_q10"]) & (sub.actual <= sub[f"{m}_q90"])).mean()
            res.append(r)
    tab = pd.DataFrame(res)
    clim = {s: (lambda y: y.mean() * (1 - y.mean()))(sub.actual <= 0) for s, sub in
            (("all39", base), ("exIT", base[~base.zone.str.startswith("IT-")]))}
    print("Brier climatology (<=0):", {k: round(v, 5) for k, v in clim.items()})
    pd.set_option("display.width", 250, "display.max_columns", 40)
    print(tab.round(3).to_string(index=False))
    tag = os.environ.get("EVAL_TAG", "main")
    tab.to_csv(f"{OUT}/eval_{tag}_summary.csv", index=False)
    # secondary: the live site's own ML overlays (gbm = physics + GBM residual corrector,
    # stats = pure-stats GBM), each on the subset of cells where it was published
    sec = []
    for comp in ("gbm", "stats"):
        sub = base.dropna(subset=[comp])
        for m in [comp] + methods:
            sec.append(dict(subset=comp, zones=sub.zone.nunique(), method=m, **metrics(sub, m)))
    sec = pd.DataFrame(sec)
    sec.to_csv(f"{OUT}/eval_{tag}_vs_site_ml.csv", index=False)
    print("\nvs live site ML overlays (own coverage):")
    print(sec[["subset", "zones", "method", "n", "MAE", "bias", "corr", "zcorr", "hit<=0", "FAR<=0"]].round(3).to_string(index=False))
    # per zone MAE / bias / corr
    pz = []
    for z, g in base.groupby("zone"):
        for m in methods:
            e = g[m] - g.actual
            pz.append(dict(zone=z, method=m, n=len(g), MAE=e.abs().mean(), bias=e.mean(), corr=g[m].corr(g.actual)))
    pz = pd.DataFrame(pz)
    pz.to_csv(f"{OUT}/eval_{tag}_perzone.csv", index=False)
    print(pz.pivot(index="zone", columns="method", values="MAE").round(1).to_string())
    # per calibration day footprint MAE
    cd = base[base.date.isin(CAL_DAYS)]
    print("\ncalibration days, footprint MAE (all39):")
    print(cd.groupby("date")[methods].apply(lambda g: (g.sub(cd.loc[g.index, "actual"], axis=0)).abs().mean()).round(1).to_string())
    # per month
    base = base.assign(month=base.date.str[:7])
    print("\nper month MAE (all39):")
    print(base.groupby("month")[methods].apply(lambda g: (g.sub(base.loc[g.index, "actual"], axis=0)).abs().mean()).round(1).to_string())


if __name__ == "__main__":
    main(sys.argv[1:])
