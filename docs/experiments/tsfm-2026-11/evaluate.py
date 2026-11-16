"""Score TSFM forecasts vs settled, the live lead-1 weather-track `sim`, and naive baselines.

Cells: 2026-09-14..2026-11-13 Athens market days, hours of the live lead-1 weather rows that have
a settled actual (the common set: every method must have a value). Reported on all 39 zones and
excluding the 7 IT-* zones. Collapse classification on the point forecast (median for TSFMs):
hit-rate = P(pred <= thr | actual <= thr), false-alarm ratio = P(actual > thr | pred <= thr).
Probabilistic: Brier score of P(price <= 0) and P(<= 5), AUC.

Usage: python evaluate.py fc_t209_uni fc_c2_uni ...   (files in $TSFM_OUT, without .parquet)

Target (#431): labels and naives follow EUPHEMIA_DA_TARGET (`target_panel`). Unset/highest_seq =
the frozen panel's prices, unchanged. sdac = EVAL_TARGET_PANEL or EVAL_EXTRACT (read-only extract).
"""
import os, sys
from pathlib import Path
import numpy as np, pandas as pd
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bin"))
import da_target  # noqa: E402

ATH = ZoneInfo("Europe/Athens")

OUT = (os.environ.get('TSFM_OUT') or sys.exit("Set TSFM_OUT to the required local file or directory"))
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


def target_panel(panel):
    """Evaluation labels (zone, t, price) under EUPHEMIA_DA_TARGET (#431).

    highest_seq (default): the frozen panel itself, i.e. the settled prices the models were fed
    (highest sequence: EXAA in AT/DE_LU). sdac: an explicit target artifact, never the panel:
    EVAL_TARGET_PANEL (a parquet with zone, t, price), else computed from the read-only extract
    EVAL_EXTRACT with bin/da_target.py over the panel's hours. Neither given -> error (no silent
    fallback to the EXAA labels). Only labels and naives change; forecasts (built from the frozen
    panel by run_tsfm.py) and the model input context are untouched."""
    pol = da_target.policy()
    if pol == "highest_seq":
        return panel
    art = os.environ.get("EVAL_TARGET_PANEL")
    if art:
        tgt = pd.read_parquet(art)[["zone", "t", "price"]]
    elif os.environ.get("EVAL_EXTRACT"):
        import duckdb
        con = duckdb.connect(os.environ["EVAL_EXTRACT"], read_only=True)
        try:
            a = da_target.hourly_actuals(con, panel.t.min(), panel.t.max() + pd.Timedelta(hours=1),
                                         target=pol)
        finally:
            con.close()
        tgt = a.rename(columns={"z": "zone", "act": "price"}).assign(price=lambda x: x.price.round(8))
    else:
        raise ValueError(f"EUPHEMIA_DA_TARGET={pol}: set EVAL_TARGET_PANEL or EVAL_EXTRACT "
                         "(the frozen panel holds highest-sequence prices)")
    tgt = tgt.assign(t=pd.to_datetime(tgt.t))
    assert not tgt.duplicated(["zone", "t"]).any(), "target artifact: duplicate (zone, t)"
    return tgt


def load(names):
    # labels and naives follow the selected target; the frozen panel is the default target
    panel = target_panel(pd.read_parquet(f"{OUT}/panel.parquet")[["zone", "t", "price"]])
    live = pd.read_parquet(f"{OUT}/live_lead1.parquet")
    live = live[(live.input_mode == "weather") & (live.date >= START) & (live.date <= END)]
    df = live[["zone", "date", "t", "sim", "gbm", "stats", "code_version", "made"]].merge(panel, on=["zone", "t"], how="left")
    df = df.rename(columns={"price": "actual"})
    # Live sim availability: the lead-1 sim is published at `made` (08:16-10:06 UTC D-1 in this
    # window). Variants that read sim (`sim`, `resid`) are POST-SIM products (~10:15 UTC D-1);
    # `sim_late` flags market days whose sim came after D-1 10:00 UTC (reported with and without).
    made = pd.to_datetime(df.made, utc=True).dt.tz_localize(None)
    d1_10 = pd.to_datetime(df.date) - pd.Timedelta(days=1) + pd.Timedelta(hours=10)
    df["sim_late"] = made > d1_10
    # Naive lags by Athens market day and local hour (not UTC hours: the 25-h DST day 2026-10-25
    # would otherwise pull a target-day price into "D-1"). Repeated local hour (fall-back 03:00)
    # policy: the source value is the mean of the duplicated source hours; both repeated target
    # hours map to the same source local hour.
    loc = panel.t.dt.tz_localize("UTC").dt.tz_convert(ATH)
    pl = panel.assign(ld=loc.dt.tz_localize(None).dt.normalize(), lh=loc.dt.hour).groupby(["zone", "ld", "lh"]).price.mean()
    tl = df.t.dt.tz_localize("UTC").dt.tz_convert(ATH)
    assert (tl.dt.date.astype(str) == df.date).all(), "live hours must fall in their Athens market day"
    for k, nm in ((1, "naive_D1"), (2, "naive_D2"), (7, "naive_D7")):
        idx = pd.MultiIndex.from_arrays([df.zone, tl.dt.tz_localize(None).dt.normalize() - pd.Timedelta(days=k), tl.dt.hour])
        df[nm] = pl.reindex(idx).values
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
    late = base[base.sim_late]
    print(f"sim published after D-1 10:00 UTC: {len(late)} cells on {late.date.nunique()} days "
          f"({sorted(late.date.unique())}); scopes *_ontime exclude them")
    exit_ = ~base.zone.str.startswith("IT-")
    scopes = (("all39", base), ("exIT", base[exit_]),
              ("all39_ontime", base[~base.sim_late]), ("exIT_ontime", base[exit_ & ~base.sim_late]))
    res = []
    for scope, sub in scopes:
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
