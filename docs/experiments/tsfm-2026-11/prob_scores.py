"""Probabilistic scores for the Timestral/Chronos quantile forecasts (#431 PR F, part 1).

Scores what is saved; nothing is re-forecast.

* Backtest (`$TSFM_OUT/fc_*.parquet`): the full 21-quantile grid (q01, q05, q10, ..., q95, q99).
  - per-quantile pinball loss on all 21 levels;
  - central-interval coverage and width at 50 % (q25-q75), 80 % (q10-q90), 90 % (q05-q95) and
    98 % (q01-q99). Endpoints are inclusive;
  - a CRPS approximation from the 21-level grid. It is labelled backtest-only: live saves just
    q10/q50/q90, from which no CRPS is computed.
* P(price <= 0) reliability, binned and by alarm threshold, for each probability source:
  - raw TSFM;
  - the hourly 50/50 blend with collapse's D-1 logistic;
  - the day-level max-hour TSFM, and its 50/50 blend with collapse's day logistic.
  The blends only change the probability; the quantiles are always raw TSFM.
* Split-conformal recalibration (CQR) of the central intervals, offline only. It is one fixed
  specification, declared before scoring:
  - per zone, additive;
  - calibration on the zone's cells in the trailing 28 CALENDAR days D-28..D-1, strictly before
    the evaluation day D. D-1's prices are public at the D-1 06:30 issue (published on D-2).
    Cohort exclusions leave gaps, so a window holds fewer than 28 market days: D is evaluated
    only if it is >= 28 days after the zone's own first day and the window has >= 14 distinct
    calibration days (the realised counts are reported);
  - two band policies (`adjust_band`): `signed` CQR, where an inverted band is the empty set,
    scored as a zero-width interval and counted; and `widen` (offsets clipped at 0), the only
    one publishable as an ordered q_lo <= q_hi pair.
  Reports coverage, width, endpoint pinball, interval score and the inversion frequency.
* Live (`--live-api DIR`, zone JSONs as served by api.philokalia.ai/api/v1/zones/<Z>): scores
  tsfm/tsfm_q10/tsfm_q90, the hourly p_le0 and the day p_any_le0 (reliability bins, alarm
  thresholds, counts, arm/mode labels) where the overlay and the settled actuals exist.

Cells: the README's common set (54,231 = 39 zones x 58 days) and its on-time subset (47,679,
lead-1 `sim` published by D-1 10:00 UTC), reproduced through evaluate.load and asserted.

Usage: python prob_scores.py [--live-api DIR] [--out DIR]
"""
import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))


LEVELS = np.array([0.01, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50,
                   0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 0.99])
QCOLS = [f"q{int(round(100 * l)):02d}" for l in LEVELS]
INTERVALS = {50: ("q25", "q75"), 80: ("q10", "q90"), 90: ("q05", "q95"), 98: ("q01", "q99")}
CONFORMAL_LEVELS = (50, 80, 90)
CAL_DAYS = 28
MIN_CAL_DAYS = 14                 # distinct calibration market days required inside the window
BAND_POLICIES = ("signed", "widen")
REL_BINS = [0, 0.01, 0.05, 0.1, 0.2, 0.4, 0.6, 0.8, 1.0000001]
ALARMS = (0.1, 0.3, 0.5)          # 0.3 = the site's "<=0 risk" badge threshold

# Arms: (file, label, information set). Raw TSFM only; the blends are P(<=0) sources below.
ARMS = [("fc_t209_uni_L1", "Timestral-209M, prices only", "(a) 06:30"),
        ("fc_c2_uni_L1", "Chronos-2, prices only", "(a) 06:30"),
        ("fc_t209_sim_L1", "Timestral-209M + live sim", "(a') post-sim ~10:15 UTC")]
N_COMMON, N_ONTIME = 54231, 47679


# ----------------------------------------------------------------------------- scores (pure)
def pinball(y, q, tau):
    """Quantile (pinball) loss: tau*(y-q) if y >= q else (1-tau)*(q-y)."""
    d = np.asarray(y, float) - np.asarray(q, float)
    return np.maximum(tau * d, (tau - 1.0) * d)


def grid_weights(levels):
    """Weights of the quantile-score integral CRPS = 2 * int_0^1 QS_tau dtau on a discrete grid.

    Each level gets the width of its Voronoi cell on [0, 1]; the outer cells extend to 0 and 1,
    i.e. the tails beyond the outer levels are scored with the outer quantiles."""
    l = np.asarray(levels, float)
    edges = np.concatenate([[0.0], (l[1:] + l[:-1]) / 2, [1.0]])
    return np.diff(edges)


def crps_from_grid(y, Q, levels):
    """Approximate CRPS from a quantile grid Q[..., k] (an approximation, not exact CRPS)."""
    w = grid_weights(levels)
    qs = np.stack([pinball(y, Q[..., k], levels[k]) for k in range(len(levels))], axis=-1)
    return 2.0 * (qs * w).sum(axis=-1)


def check_grid(df, cols):
    """Missing-grid and ordering guards. Returns (df with sorted quantiles, n_crossed rows).

    Rows with any missing level are an error (score what is saved, never impute). Crossed
    quantiles are counted and sorted (monotone rearrangement); the count is reported."""
    Q = df[cols].to_numpy(float)
    if np.isnan(Q).any():
        raise ValueError(f"{int(np.isnan(Q).any(axis=1).sum())} rows with a missing quantile level")
    crossed = int((np.diff(Q, axis=1) < -1e-9).any(axis=1).sum())
    if crossed:
        df = df.copy()
        df[cols] = np.sort(Q, axis=1)
    return df, crossed


def covered(y, lo, hi):
    """Inclusive interval coverage indicator."""
    return (np.asarray(y) >= np.asarray(lo)) & (np.asarray(y) <= np.asarray(hi))


def interval_score(y, lo, hi, alpha):
    """Gneiting-Raftery interval score of a central (1-alpha) interval (lower is better)."""
    y, lo, hi = (np.asarray(v, float) for v in (y, lo, hi))
    return (hi - lo) + 2 / alpha * (lo - y) * (y < lo) + 2 / alpha * (y - hi) * (y > hi)


def reliability(p, y, bins=REL_BINS):
    """Binned reliability table plus the Murphy decomposition BS ~ REL - RES + UNC on those bins."""
    p, y = np.asarray(p, float), np.asarray(y, float)
    b = pd.cut(p, bins, right=False)
    g = pd.DataFrame({"p": p, "y": y, "bin": b}).groupby("bin", observed=True).agg(
        n=("y", "size"), mean_p=("p", "mean"), freq=("y", "mean"), events=("y", "sum"))
    ybar = y.mean()
    rel = (g.n * (g.mean_p - g.freq) ** 2).sum() / len(y)
    res = (g.n * (g.freq - ybar) ** 2).sum() / len(y)
    summ = dict(n=len(y), events=int(y.sum()), base_rate=ybar, mean_p=p.mean(),
                Brier=np.mean((p - y) ** 2), REL=rel, RES=res, UNC=ybar * (1 - ybar))
    return g.reset_index(), summ


def alarm_table(p, y, thresholds=ALARMS):
    p, y = np.asarray(p, float), np.asarray(y, bool)
    rows = []
    for c in thresholds:
        a = p >= c
        rows.append(dict(threshold=c, alarms=int(a.sum()), events=int(y.sum()),
                         hits=int((a & y).sum()),
                         precision=(a & y).sum() / a.sum() if a.sum() else np.nan,
                         hit_rate=(a & y).sum() / y.sum() if y.sum() else np.nan,
                         mean_p_alarmed=p[a].mean() if a.sum() else np.nan))
    return pd.DataFrame(rows)


def conformal_offsets(cal, lo, hi, level, days=CAL_DAYS, group="zone", day_col="date",
                      min_cal_days=MIN_CAL_DAYS):
    """Split-conformal (CQR) offsets per (group, evaluation day), strictly chronological.

    For evaluation day D the calibration set is every cell of the same group with day in the
    trailing calendar window [D-days, D-1]. Eligibility is per group: D must be at least `days`
    after THAT group's first day, and the window must hold >= `min_cal_days` distinct market
    days with cells (cohort exclusions such as late-sim days leave gaps). Score
    s = max(lo - y, y - hi); offset = the ceil((n+1)*level)-th smallest score. Columns: group,
    eval_day, offset, n_cal, n_cal_days, cal_first, cal_last (for the no-overlap audit)."""
    alpha_cov = level / 100.0
    d = cal[[group, day_col, "actual", lo, hi]].copy()
    d["day"] = pd.to_datetime(d[day_col])
    d["s"] = np.maximum(d[lo] - d.actual, d.actual - d[hi])
    out = []
    for z, g in d.groupby(group):
        first = g.day.min()                  # per-group history, never the table's earliest day
        for D in sorted(g.day.unique()):
            if D - pd.Timedelta(days=days) < first:
                continue
            w = g[(g.day >= D - pd.Timedelta(days=days)) & (g.day < D)]
            n = len(w)
            if w.day.nunique() < min_cal_days:
                continue
            k = int(np.ceil((n + 1) * alpha_cov))
            s = np.sort(w.s.to_numpy())
            off = s[min(k, n) - 1] if k <= n else s[-1]
            out.append({group: z, "eval_day": D, "offset": off, "n_cal": n, "n_cal_days": w.day.nunique(),
                        "cal_first": w.day.min(), "cal_last": w.day.max()})
    return pd.DataFrame(out)


def adjust_band(lo, hi, offset, policy):
    """Apply a CQR offset under an explicit band policy. Returns (lo', hi', inverted mask).

    signed  the CQR set [lo - off, hi + off]; a negative offset larger than the half-width gives
            lo' > hi', i.e. the EMPTY prediction set. It is never shown as a band with negative
            width: it is scored as the degenerate interval at the band's midpoint (width 0,
            covered only if y equals it) and counted in `inverted`.
    widen   offsets clipped at 0 (widen-only): the band is never narrowed, never inverted. This is
            the only policy compatible with publishing it as an ordered q_lo <= q_hi pair."""
    lo, hi, off = (np.asarray(v, float) for v in (lo, hi, offset))
    if policy == "widen":
        off = np.maximum(off, 0.0)
    elif policy != "signed":
        raise ValueError(policy)
    alo, ahi = lo - off, hi + off
    inv = alo > ahi
    mid = (alo + ahi) / 2
    return np.where(inv, mid, alo), np.where(inv, mid, ahi), inv


# ----------------------------------------------------------------------------- data
def load_backtest():
    out = os.environ.get("TSFM_OUT") or sys.exit("Set TSFM_OUT to the saved forecast directory")
    import evaluate as ev
    names = [a[0] for a in ARMS]
    base_df, keys = ev.load(names)
    methods = ["sim", "naive_D1", "naive_D2", "naive_D7"] + keys
    base = base_df.dropna(subset=["actual"] + methods)[["zone", "date", "t", "actual", "sim_late"]]
    n_common, n_on = len(base), int((~base.sim_late).sum())
    assert (n_common, n_on) == (N_COMMON, N_ONTIME), f"cell set changed: {n_common}/{n_on}"
    arms = {}
    for fn, _, _ in ARMS:
        f = pd.read_parquet(f"{out}/{fn}.parquet")
        assert f.lead_days.eq(1).all() and np.allclose(f["median"], f["q50"])
        f, crossed = check_grid(f, QCOLS)
        m = base.merge(f[["zone", "t", "median", "p_le0"] + QCOLS], on=["zone", "t"], how="left")
        assert len(m) == len(base) and m[QCOLS].notna().all().all()
        arms[fn] = (m, crossed)
    return base, arms


def load_logits(base):
    res = os.environ.get("TEAM_RESULTS") or sys.exit("Set TEAM_RESULTS to the saved results directory")
    logit_hour = Path(res) / "collapse-probability-primary/pregate_0630-predictions.csv.gz"
    logit_day = Path(res) / "collapse-diagnostics-primary/pregate_0630-day-predictions.csv.gz"
    h = pd.read_csv(logit_hour, parse_dates=["t"])
    h = h[h.model == "logistic"][["zone", "t", "y", "probability"]].rename(columns={"probability": "p_logit"})
    d = pd.read_csv(logit_day)
    d = d[d.model == "logistic"][["zone", "market_date", "y", "probability"]].rename(
        columns={"probability": "p_any_logit", "y": "y_day", "market_date": "date"})
    return h, d


def zone_files(api_dir):
    """Zone JSONs of an API snapshot (skips e.g. snapshot-manifest.json: no zone/days keys)."""
    out = []
    for f in sorted(Path(api_dir).glob("*.json")):
        js = json.loads(f.read_text())
        if isinstance(js, dict) and "zone" in js and "days" in js:
            out.append(f)
    return out


def load_live(api_dir):
    """Hourly + day rows of the published overlay with a settled actual (lead-1 market days).

    The overlay fields are per (zone, market day), repeated on every lead/input_mode row of that
    day in the API, so each (zone, hour) is kept once; a day whose rows disagree is an error."""
    rows, days = [], []
    for f in zone_files(api_dir):
        js = json.loads(f.read_text())
        z = js["zone"]
        for r in js["days"]:
            tq = r.get("tsfm") or []
            if not any(v is not None for v in tq):
                continue
            for i, h in enumerate(r["hours"]):
                rows.append(dict(zone=z, date=r["date"], t=h, actual=r["actual"][i], median=tq[i],
                                 q10=r["tsfm_q10"][i], q90=r["tsfm_q90"][i], p_le0=r["p_le0"][i],
                                 issue=r.get("tsfm_issue_utc"), arm=r.get("tsfm_arm"),
                                 mode=r.get("tsfm_input_mode")))
            days.append(dict(zone=z, date=r["date"], p_any_le0=r.get("p_any_le0"),
                             issue=r.get("tsfm_issue_utc"), arm=r.get("tsfm_arm"), mode=r.get("tsfm_input_mode")))
    cols = ["zone", "date", "t", "actual", "median", "q10", "q90", "p_le0", "issue", "arm", "mode"]
    h = pd.DataFrame(rows, columns=cols)
    d = pd.DataFrame(days, columns=["zone", "date", "p_any_le0", "issue", "arm", "mode"])
    # one vintage per (zone, hour) / (zone, day): any field differing between repeated rows,
    # values or provenance (issue, arm, mode), is an error, never a silent pick
    for frame, key, what in ((h, ["zone", "t"], "hour"), (d, ["zone", "date"], "day")):
        if len(frame) and frame.astype(str).drop_duplicates().duplicated(key).any():
            raise ValueError(f"live overlay disagrees across repeated rows of the same (zone, {what})")
    h = h.astype({"actual": float}).drop_duplicates(["zone", "t"]).reset_index(drop=True) if len(h) else h
    d = d.drop_duplicates(["zone", "date"]).reset_index(drop=True) if len(d) else d
    return h, d


def score_live(h, d):
    """Score the saved live overlay. Returns (summary, reliability bins, alarm table).

    Hourly: pinball of q10/median/q90, inclusive 80 % coverage and width, and the published
    hourly probability `p_le0` (the 50/50 blend, or the TSFM-only fallback when the logistic
    failed) against actual <= 0. Day: the published `p_any_le0` against "any hour of the Athens
    market day <= 0", only on days whose every overlay hour has a settled actual (incomplete days
    are counted, not scored). Every block is labelled with its source, arm(s), mode(s) and counts."""
    summ = {"overlay_hours": int(len(h)), "overlay_days": int(len(d))}
    bins, alarms = [], []
    hs = h.dropna(subset=["actual", "median", "q10", "q90"]) if len(h) else h
    summ["cells"] = int(len(hs))
    if len(hs):
        y = hs.actual.to_numpy(float)
        summ["quantiles"] = dict(
            source="live tsfm_q10 / tsfm (median) / tsfm_q90", n=int(len(hs)), days=int(hs.date.nunique()),
            zones=int(hs.zone.nunique()), arms=sorted(hs.arm.dropna().unique().tolist()),
            modes=sorted(hs["mode"].dropna().unique().tolist()),
            pinball_q10=float(pinball(y, hs.q10, .1).mean()), pinball_q50=float(pinball(y, hs["median"], .5).mean()),
            pinball_q90=float(pinball(y, hs.q90, .9).mean()), cov80=float(covered(y, hs.q10, hs.q90).mean()),
            width80=float((hs.q90 - hs.q10).mean()))
    hp = h.dropna(subset=["actual", "p_le0"]) if len(h) else h
    blocks = []
    if len(hp):
        blocks.append(("hour", "live p_le0 (published hourly probability)", hp, hp.p_le0, hp.actual <= 0))
    if len(d) and len(h):
        g = h.groupby(["zone", "date"]).agg(hours=("t", "size"), settled=("actual", "count"),
                                            y_day=("actual", lambda s: int((s <= 0).any())))
        dd = d.merge(g.reset_index(), on=["zone", "date"], how="left")
        complete = dd.hours.notna() & (dd.hours == dd.settled) & dd.p_any_le0.notna()
        summ["day_incomplete_or_missing"] = int((~complete).sum())
        dd = dd[complete]
        if len(dd):
            blocks.append(("day", "live p_any_le0 (published day probability)", dd, dd.p_any_le0, dd.y_day.astype(bool)))
    for level, src, frame, p, y in blocks:
        t, s = reliability(np.asarray(p, float), np.asarray(y, float))
        summ[f"{level}_probability"] = dict(source=src, arms=sorted(frame.arm.dropna().unique().tolist()),
                                           modes=sorted(frame["mode"].dropna().unique().tolist()),
                                           **{k: (float(v) if not isinstance(v, int) else v) for k, v in s.items()})
        bins.append(t.assign(level=level, source=src))
        alarms.append(alarm_table(np.asarray(p, float), np.asarray(y, bool)).assign(level=level, source=src))
    return (summ, pd.concat(bins, ignore_index=True) if bins else pd.DataFrame(),
            pd.concat(alarms, ignore_index=True) if alarms else pd.DataFrame())


def live_report(api_dir, out):
    """Load + score the live overlay from a directory of zone JSONs; write live*.{json,csv}."""
    h, d = load_live(api_dir)
    summ, bins, alarms = score_live(h, d)
    summ = {"api_dir": str(api_dir), "zone_files": len(zone_files(api_dir)), **summ}
    Path(f"{out}/live.json").write_text(json.dumps(summ, indent=1, default=float))
    bins.to_csv(f"{out}/live_reliability_bins.csv", index=False)
    alarms.to_csv(f"{out}/live_alarms.csv", index=False)
    return summ, bins, alarms


# ----------------------------------------------------------------------------- report
def quantile_table(m):
    y = m.actual.to_numpy()
    return {c: pinball(y, m[c].to_numpy(), l).mean() for c, l in zip(QCOLS, LEVELS)}


def interval_rows(m, scope, arm, levels=INTERVALS):
    out = []
    for lev, (lo, hi) in levels.items():
        cov = covered(m.actual, m[lo], m[hi])
        out.append(dict(arm=arm, scope=scope, level=lev, n=len(m), coverage=cov.mean(),
                        below=(m.actual < m[lo]).mean(), above=(m.actual > m[hi]).mean(),
                        width=(m[hi] - m[lo]).mean(),
                        interval_score=interval_score(m.actual, m[lo], m[hi], 1 - lev / 100).mean()))
    return out


def scopes_of(m):
    exit_ = ~m.zone.str.startswith("IT-")
    return {"all39": m, "all39_ontime": m[~m.sim_late], "exIT_ontime": m[exit_ & ~m.sim_late]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live-api", default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    if a.out is None:
        out = os.environ.get("TSFM_OUT") or sys.exit("Set TSFM_OUT to the saved forecast directory")
        a.out = str(Path(out) / "prob431")
    os.makedirs(a.out, exist_ok=True)
    pd.set_option("display.width", 250, "display.max_columns", 40)
    base, arms = load_backtest()
    print(f"cells: common {len(base)} ({base.zone.nunique()} zones, {base.date.nunique()} days); "
          f"on-time {int((~base.sim_late).sum())} ({base[~base.sim_late].date.nunique()} days)")

    # 1. pinball per quantile, CRPS (grid approx), intervals
    pin, crps, ivl = [], [], []
    for fn, label, info in ARMS:
        m, crossed = arms[fn]
        print(f"{fn}: crossed-quantile rows sorted = {crossed}")
        for scope, sub in scopes_of(m).items():
            pin.append(dict(arm=fn, label=label, info=info, scope=scope, n=len(sub), **quantile_table(sub)))
            c = crps_from_grid(sub.actual.to_numpy(), sub[QCOLS].to_numpy(), LEVELS)
            crps.append(dict(arm=fn, label=label, info=info, scope=scope, n=len(sub),
                             CRPS_grid21=c.mean(), MAE_median=(sub["q50"] - sub.actual).abs().mean(),
                             pinball_mean21=np.mean([pinball(sub.actual, sub[q], l).mean()
                                                     for q, l in zip(QCOLS, LEVELS)]),
                             pinball_mean_q10_q50_q90=np.mean([pinball(sub.actual, sub[q], l).mean()
                                                               for q, l in (("q10", .1), ("q50", .5), ("q90", .9))])))
            ivl += interval_rows(sub, scope, fn)
    pin, crps, ivl = pd.DataFrame(pin), pd.DataFrame(crps), pd.DataFrame(ivl)
    print("\n== pinball loss per quantile (EUR/MWh)")
    print(pin[pin.scope == "all39_ontime"].set_index("arm")[QCOLS].round(2).T.to_string())
    print("\n== CRPS (21-quantile grid approximation, BACKTEST ONLY) and mean pinball")
    print(crps.round(3).to_string(index=False))
    print("\n== central intervals (inclusive endpoints)")
    print(ivl.round(3).to_string(index=False))

    # 2. P(<=0) reliability: raw TSFM, hourly blend, day max-hour, day blend
    lh, ld = load_logits(base)
    rel_rows, rel_tabs, alarm_rows = [], [], []
    for fn, label, info in ARMS:
        m, _ = arms[fn]
        hm = m.merge(lh, on=["zone", "t"], how="inner")
        assert len(hm) == len(m), "every scored cell must have collapse's hourly logistic"
        assert ((hm.actual <= 0).astype(int) == hm.y).all(), "label mismatch vs collapse"
        hm["p_blend"] = (hm.p_le0 + hm.p_logit) / 2
        day = (m.groupby(["zone", "date"]).agg(p_any_tsfm=("p_le0", "max"), y_day=("actual", lambda s: int((s <= 0).any())),
                                               hours=("actual", "size"), sim_late=("sim_late", "first")).reset_index())
        dm = day.merge(ld, on=["zone", "date"], how="inner", suffixes=("", "_c"))
        # the day label is collapse's (every settled hour of the day); report disagreements with
        # the label from the scored hours only, never drop on them (that would select on outcome)
        n_dis = int((dm.y_day != dm.y_day_c).sum())
        print(f"{fn}: day cells {len(dm)} (of {len(day)} zone-days), day-label disagreements {n_dis}")
        dm["y_day"] = dm.y_day_c
        dm["p_any_blend"] = (dm.p_any_tsfm + dm.p_any_logit) / 2
        sources = [("hour", "raw TSFM", m.p_le0, (m.actual <= 0), m.sim_late),
                   ("hour", "collapse logistic", hm.p_logit, hm.y.astype(bool), hm.sim_late),
                   ("hour", "hourly blend 50/50", hm.p_blend, hm.y.astype(bool), hm.sim_late),
                   ("day", "max-hour TSFM", dm.p_any_tsfm, dm.y_day.astype(bool), dm.sim_late),
                   ("day", "collapse day logistic", dm.p_any_logit, dm.y_day.astype(bool), dm.sim_late),
                   ("day", "day blend 50/50", dm.p_any_blend, dm.y_day.astype(bool), dm.sim_late)]
        if fn != "fc_t209_uni_L1":   # the logistic rows are identical across arms; print them once
            sources = [s for s in sources if "logistic" not in s[1] or "blend" in s[1]]
        for lvl, src, p, y, late in sources:
            for scope, mask in (("all", np.ones(len(p), bool)), ("ontime", ~np.asarray(late, bool))):
                t, s = reliability(np.asarray(p)[mask], np.asarray(y)[mask])
                rel_rows.append(dict(arm=fn, level=lvl, source=src, scope=scope, **s))
                rel_tabs.append(t.assign(arm=fn, level=lvl, source=src, scope=scope))
                alarm_rows.append(alarm_table(np.asarray(p)[mask], np.asarray(y)[mask]).assign(
                    arm=fn, level=lvl, source=src, scope=scope))
    rel, relt, alarms = pd.DataFrame(rel_rows), pd.concat(rel_tabs), pd.concat(alarm_rows)
    print("\n== P(<=0) Brier + Murphy decomposition (bins %s)" % REL_BINS[:-1])
    print(rel.round(5).to_string(index=False))
    print("\n== reliability bins (on-time scope)")
    print(relt[relt.scope == "ontime"].round(4).to_string(index=False))
    print("\n== alarms by threshold (on-time scope)")
    print(alarms[alarms.scope == "ontime"].round(3).to_string(index=False))

    # 3. split-conformal (CQR), per zone, rolling 28 days strictly before D
    conf, offs_all = [], []
    for fn, label, info in ARMS:
        m, _ = arms[fn]
        on = m[~m.sim_late].copy()
        on["day"] = pd.to_datetime(on.date)
        for lev in CONFORMAL_LEVELS:
            lo, hi = INTERVALS[lev]
            offs = conformal_offsets(on, lo, hi, lev)
            assert (offs.cal_last < offs.eval_day).all(), "calibration overlaps evaluation"
            offs_all.append(offs.assign(arm=fn, level=lev))
            ev_ = on.merge(offs, left_on=["zone", "day"], right_on=["zone", "eval_day"], how="inner")
            raw_before = ev_[[lo, hi]].copy()
            tl, th = (1 - lev / 100) / 2, 1 - (1 - lev / 100) / 2
            for policy in BAND_POLICIES:
              alo, ahi, inv = adjust_band(ev_[lo], ev_[hi], ev_.offset, policy)
              assert ev_[[lo, hi]].equals(raw_before) and (ahi >= alo).all()
              for scope, sel in (("all39_ontime", np.ones(len(ev_), bool)), ("exIT_ontime", ~ev_.zone.str.startswith("IT-").to_numpy())):
                e = ev_[sel]; al, ah, iv = alo[sel], ahi[sel], inv[sel]
                zc_b = e.assign(c=covered(e.actual, e[lo], e[hi])).groupby("zone").c.mean()
                zc_a = e.assign(c=covered(e.actual, al, ah)).groupby("zone").c.mean()
                conf.append(dict(
                    arm=fn, level=lev, policy=policy, scope=scope, n=len(e), days=e.date.nunique(),
                    first_eval=e.date.min(), cal_n_median=int(e.n_cal.median()),
                    cal_days_min=int(e.n_cal_days.min()), cal_days_median=float(e.n_cal_days.median()),
                    cal_days_max=int(e.n_cal_days.max()), cal_n_min=int(e.n_cal.min()), cal_n_max=int(e.n_cal.max()),
                    n_inverted=int(iv.sum()), share_inverted=float(iv.mean()),
                    neg_offset_share=float((e.offset < 0).mean()),
                    cov_before=covered(e.actual, e[lo], e[hi]).mean(), cov_after=covered(e.actual, al, ah).mean(),
                    width_before=(e[hi] - e[lo]).mean(), width_after=(ah - al).mean(),
                    pinball_lo_before=pinball(e.actual, e[lo], tl).mean(), pinball_lo_after=pinball(e.actual, al, tl).mean(),
                    pinball_hi_before=pinball(e.actual, e[hi], th).mean(), pinball_hi_after=pinball(e.actual, ah, th).mean(),
                    IS_before=interval_score(e.actual, e[lo], e[hi], 1 - lev / 100).mean(),
                    IS_after=interval_score(e.actual, al, ah, 1 - lev / 100).mean(),
                    zone_cov_before_min=zc_b.min(), zone_cov_before_max=zc_b.max(),
                    zone_cov_after_min=zc_a.min(), zone_cov_after_max=zc_a.max()))
    conf = pd.DataFrame(conf)
    print("\n== split-conformal (per zone, additive, trailing 28 calendar days strictly before D, "
          f">= {MIN_CAL_DAYS} distinct calibration days; band policies {BAND_POLICIES})")
    print(conf.round(3).to_string(index=False))

    # 4. live
    if a.live_api:
        live_summary, lbins, lalarms = live_report(a.live_api, a.out)
        print("\n== live overlay:", json.dumps(live_summary, indent=1, default=float))
        if len(lbins):
            print(lbins.round(4).to_string(index=False)); print(lalarms.round(3).to_string(index=False))

    for nm, t in (("pinball", pin), ("crps", crps), ("intervals", ivl), ("reliability_summary", rel),
                  ("reliability_bins", relt), ("alarms", alarms), ("conformal", conf),
                  ("conformal_offsets", pd.concat(offs_all))):
        t.to_csv(f"{a.out}/{nm}.csv", index=False)
    print(f"\nwrote {a.out}/")


if __name__ == "__main__":
    main()
