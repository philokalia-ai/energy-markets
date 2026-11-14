# Score arms against settled (live-JSON SDAC actuals, UTC hours, rounded 1e-8).
# usage: python score.py BASE_DIR TREAT_DIR [DAY ...]   (default: the 8 calibration days)
import sys, glob, os, pandas as pd, numpy as np
R = "/home/pgeorgakopoulos/armada/em-team/results/level"
base, treat = sys.argv[1], sys.argv[2]
days = sys.argv[3:] or ["2026-09-16", "2026-09-20", "2026-09-27", "2026-10-06", "2026-10-19", "2026-11-02", "2026-11-04", "2026-11-13"]
def load(d, arm):
    f = f"{d}/{arm}.csv"
    if not os.path.isfile(f): return None
    P = pd.read_csv(f); P["t"] = pd.to_datetime(P.period.astype(str), format="%Y%m%d-%H%M")
    return P.groupby(["zone", pd.Grouper(key="t", freq="h")]).price.mean().reset_index()
S = pd.read_csv(f"{R}/settled.csv", parse_dates=["t"]); S["act"] = S.act.round(8)
rows, missing = [], []
for day in days:
    b, t = load(base, day), load(treat, day)
    if b is None or t is None: missing.append(day); continue
    m = b.merge(t, on=["zone", "t"], suffixes=("_b", "_t")).merge(S, on=["zone", "t"])
    m["day"] = day; rows.append(m)
M = pd.concat(rows, ignore_index=True)
print(f"days scored: {sorted(M.day.unique())}  missing: {missing}  cells: {len(M)} ({M.zone.nunique()} zones)")
def st(g, c):
    e = g[c] - g.act
    return pd.Series({"mae": e.abs().mean(), "bias": e.mean(), "corr": g[c].corr(g.act)})
def block(g):
    b, t = st(g, "price_b"), st(g, "price_t")
    neg = g.act <= 0
    return pd.Series({"n": len(g), "act": g.act.mean(), "mae_b": b.mae, "mae_t": t.mae, "dmae": t.mae - b.mae,
                      "bias_b": b.bias, "bias_t": t.bias, "corr_b": b["corr"], "corr_t": t["corr"],
                      "moved": int(((g.price_t - g.price_b).abs() > 0.5).sum()),
                      "le0_n": int(neg.sum()), "hit_b": int((neg & (g.price_b <= 0)).sum()), "hit_t": int((neg & (g.price_t <= 0)).sum()),
                      "fa_b": int((~neg & (g.price_b <= 0)).sum()), "fa_t": int((~neg & (g.price_t <= 0)).sum()),
                      "cap_b": int((g.price_b >= 2999).sum()), "cap_t": int((g.price_t >= 2999).sum())})
pd.set_option("display.width", 250); pd.set_option("display.max_rows", 300)
isit = M.zone.str.startswith("IT")
tot = pd.DataFrame({"all-39": block(M), "ex-IT (32)": block(M[~isit]), "IT (7)": block(M[isit])}).T
print(tot.round(2).to_string())
print("\nper day (ex-IT):"); print(M[~isit].groupby("day").apply(block, include_groups=False)[["n", "act", "mae_b", "mae_t", "dmae", "bias_b", "bias_t", "corr_b", "corr_t", "moved"]].round(2).to_string())
print("\nper day (all-39):"); print(M.groupby("day").apply(block, include_groups=False)[["n", "mae_b", "mae_t", "dmae", "bias_b", "bias_t", "corr_b", "corr_t", "moved", "cap_b", "cap_t"]].round(2).to_string())
print("\nper zone:"); Z = M.groupby("zone").apply(block, include_groups=False)
print(Z[["n", "act", "mae_b", "mae_t", "dmae", "bias_b", "bias_t", "corr_b", "corr_t", "moved", "hit_b", "hit_t", "fa_b", "fa_t"]].round(2).sort_values("dmae").to_string())
M.to_csv(f"{treat}/scored_cells.csv", index=False)
