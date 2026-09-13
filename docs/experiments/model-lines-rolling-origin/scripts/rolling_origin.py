# Rolling-origin evaluation of the model lines (the OOS test they never had).
#
# Folds are consecutive calendar blocks; each is predicted by models fitted only
# on the data BEFORE it, so no fold sees its own future. Four configurations on
# the same cells:
#
#   physics        the cv39 record price alone
#   hybrid(cv39)   physics + a residual GBM retrained per fold on cv39 data
#   hybrid(cv37)   physics + the FROZEN cv37-trained artifact, i.e. what
#                  production would publish if the book directory were flipped
#                  without retraining
#   stats(cv39)    the pure-statistics GBM retrained per fold
#
# Reported against the canonical SDAC target, energy-weighted where load exists.
import os
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "4")
import sys, json
import numpy as np, pandas as pd, joblib
from sklearn.ensemble import HistGradientBoostingRegressor

ROOT = "/home/pgeorgakopoulos/armada/energy-markets"
TRAIN = os.path.join(ROOT, "data", "model_lines_train")
PHYS = ["hour", "month", "D", "res_sh", "imp_sh", "bst_sh", "margin", "gas", "co2"]
STATS = ["lag24", "lag48", "lag168", "roll7", "hour", "dow", "month", "gas", "co2", "D", "res_sh"]
CV = 39
N_FOLDS = int(os.environ.get("N_FOLDS", "4"))
MIN_TRAIN = int(os.environ.get("MIN_TRAIN", "800"))

df = pd.read_parquet(os.path.join(TRAIN, f"probe2y{CV}_dataset.parquet"))
df["t"] = pd.to_datetime(df.k, format="%Y-%m-%dT%H", utc=True)
df = df.sort_values(["zone", "t"]).reset_index(drop=True)
df["dow"] = df.t.dt.dayofweek
# stats lags are built per zone on the settled series, strictly backward
g = df.groupby("zone").settled
for lag in (24, 48, 168):
    df[f"lag{lag}"] = g.shift(lag)
df["roll7"] = (df.groupby("zone").settled.shift(24)
                 .groupby(df.zone).rolling(168, min_periods=168).mean()
                 .reset_index(0, drop=True))

frozen = joblib.load(os.path.join(TRAIN, "models.joblib"))
frozen_h = frozen["hybrid"]
print(f"frozen artifact: book_cv={frozen.get('book_cv', 37)} zones={len(frozen_h)}", flush=True)

days = np.array(sorted(df.day.unique()))
# folds over the LAST year, so every fold has a substantial training history
fold_days = days[len(days) // 2:]
bounds = np.array_split(fold_days, N_FOLDS)
rows = []
for i, blk in enumerate(bounds, 1):
    lo, hi = blk[0], blk[-1]
    tr = df[df.day < lo]
    te = df[(df.day >= lo) & (df.day <= hi)].copy()
    if not len(te):
        continue
    te["p_phys"] = te[f"sim{CV}"]
    te["p_h39"] = np.nan
    te["p_h37"] = np.nan
    te["p_st"] = np.nan
    te_stats_ok = te[STATS].notna().all(axis=1)
    for z, d_tr in tr.groupby("zone"):
        m_te = te.zone == z
        if not m_te.any():
            continue
        d_tr_h = d_tr.dropna(subset=["resid"])
        if len(d_tr_h) >= MIN_TRAIN:
            mh = HistGradientBoostingRegressor(max_depth=4, max_iter=150, learning_rate=0.06,
                                               l2_regularization=1.0, random_state=0)
            mh.fit(d_tr_h[PHYS], d_tr_h.resid)
            te.loc[m_te, "p_h39"] = te.loc[m_te, f"sim{CV}"] + mh.predict(te.loc[m_te, PHYS])
        fz = frozen_h.get(z)
        if fz is not None:
            te.loc[m_te, "p_h37"] = te.loc[m_te, f"sim{CV}"] + fz.predict(te.loc[m_te, PHYS])
        d_tr_s = d_tr.dropna(subset=["lag168", "settled"])
        if len(d_tr_s) >= MIN_TRAIN:
            ms = HistGradientBoostingRegressor(max_depth=5, max_iter=250, learning_rate=0.06,
                                               l2_regularization=1.0, random_state=0)
            ms.fit(d_tr_s[STATS], d_tr_s.settled)
            ok = m_te & te_stats_ok
            te.loc[ok, "p_st"] = ms.predict(te.loc[ok, STATS])
    te["fold"] = i
    rows.append(te)
    print(f"fold {i}: train < {lo} ({tr.day.nunique()} d) -> test {lo}..{hi} "
          f"({te.day.nunique()} d, {len(te)} cells)", flush=True)

ev = pd.concat(rows, ignore_index=True)


def score(g, col):
    d = g.dropna(subset=[col])
    if not len(d):
        return dict(n=0)
    e = d[col] - d.settled
    return dict(n=len(d), MAE=e.abs().mean(), bias=e.mean(), corr=d[col].corr(d.settled))


print("\n## rolling-origin, pooled over folds (canonical SDAC target)")
for name, col in (("physics (cv39)", "p_phys"), ("hybrid retrained (cv39)", "p_h39"),
                  ("hybrid frozen (cv37)", "p_h37"), ("stats retrained (cv39)", "p_st")):
    s = score(ev, col)
    print(f"  {name:26s} n={s['n']:>7,} MAE {s.get('MAE', float('nan')):6.2f} "
          f"bias {s.get('bias', float('nan')):+6.2f} corr {s.get('corr', float('nan')):.3f}")

print("\n## per fold (MAE)")
for i, g in ev.groupby("fold"):
    print(f"  fold {i} ({g.day.min()}..{g.day.max()}): " + "  ".join(
        f"{n} {score(g, c).get('MAE', float('nan')):.2f}"
        for n, c in (("phys", "p_phys"), ("h39", "p_h39"), ("h37", "p_h37"), ("stats", "p_st"))))

print("\n## per zone, hybrid retrained vs physics vs frozen (MAE), worst/best 12 by delta")
per = []
for z, g in ev.groupby("zone"):
    a, b, c = score(g, "p_phys"), score(g, "p_h39"), score(g, "p_h37")
    if not (a.get("n") and b.get("n")):
        continue
    per.append((z, a["MAE"], b["MAE"], c.get("MAE", float("nan")),
                b["MAE"] - a["MAE"], b["MAE"] - c.get("MAE", float("nan"))))
per = pd.DataFrame(per, columns=["zone", "phys", "h39", "h37", "h39_minus_phys", "h39_minus_h37"])
per = per.sort_values("h39_minus_phys")
print(pd.concat([per.head(12), per.tail(6)]).round(2).to_string(index=False))
print(f"\nzones where the retrained hybrid beats physics: "
      f"{(per.h39_minus_phys < 0).sum()}/{len(per)}; "
      f"beats the frozen cv37 artifact: {(per.h39_minus_h37 < 0).sum()}/{len(per)}")
ev[["zone", "k", "fold", "settled", "p_phys", "p_h39", "p_h37", "p_st"]].to_parquet(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "rolling_origin_preds.parquet"), index=False)
