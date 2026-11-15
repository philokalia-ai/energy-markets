# Two-month backtest scorer: cv42 vs cv43 (record path) + live lead-1 on the same cells.
import json, glob, os, pandas as pd, numpy as np
R = "/home/pgeorgakopoulos/armada/em-team/results/level-bt"
L = "/home/pgeorgakopoulos/armada/em-team/results/level"
def load(arm, d):
    f = f"{R}/{arm}/{d}.csv"
    if not os.path.isfile(f): return None
    P = pd.read_csv(f); P["t"] = pd.to_datetime(P.period.astype(str), format="%Y%m%d-%H%M")
    return P.groupby(["zone", pd.Grouper(key="t", freq="h")]).price.mean().reset_index()
days = open(f"{R}/days.txt").read().split()
S = pd.read_csv(f"{L}/settled.csv", parse_dates=["t"]); S["act"] = S.act.round(8)
# live lead-1 published sim (weather track = the pre-gate product; entsoe lead-1 separately)
live = []
for f in glob.glob("/home/pgeorgakopoulos/armada/em-team/live/*.json"):
    z = os.path.basename(f)[:-5]
    for day in json.load(open(f))["days"]:
        if day.get("lead_days") != 1: continue
        for h, s in zip(day.get("hours") or [], day.get("sim") or []):
            if s is None: continue
            live.append((z, pd.Timestamp(h[:13] + ":00"), day.get("input_mode"), s))
LV = pd.DataFrame(live, columns=["zone", "t", "mode", "sim"]).groupby(["zone", "t", "mode"]).sim.last().unstack("mode")
rows, done, part = [], [], []
for d in days:
    a, b = load("cv42", d), load("cv43", d)
    if a is None or b is None:
        if (a is None) != (b is None): part.append(d)
        continue
    m = a.merge(b, on=["zone", "t"], suffixes=("_42", "_43")).merge(S, on=["zone", "t"])
    m["day"] = d; rows.append(m); done.append(d)
M = pd.concat(rows, ignore_index=True)
M = M.merge(LV.reset_index(), on=["zone", "t"], how="left")
M["wk"] = M.t.dt.strftime("%G-W%V")
M.to_csv(f"{R}/scored_cells.csv", index=False)
print(f"days paired: {len(done)} {done}\nhalf-done (one arm only): {part}\ncells: {len(M)} ({M.zone.nunique()} zones); live weather lead-1 present on {M.weather.notna().sum()} cells, entsoe lead-1 on {M['entsoe'].notna().sum() if 'entsoe' in M else 0}")
def blk(g, cols=("price_42", "price_43")):
    out = {"n": len(g), "act": g.act.mean()}
    for c in cols:
        k = c.replace("price_", "")
        x = g[[c, "act"]].dropna(); e = x[c] - x.act
        out[f"mae_{k}"] = e.abs().mean(); out[f"bias_{k}"] = e.mean(); out[f"corr_{k}"] = x[c].corr(x.act)
    return pd.Series(out)
def neg(g, c):
    x = g[[c, "act"]].dropna(); n = x.act <= 0
    return f"{int((n & (x[c] <= 0)).sum())}/{int(n.sum())} hit, {int((~n & (x[c] <= 0)).sum())} FA"
pd.set_option("display.width", 250); pd.set_option("display.max_rows", 300)
isit = M.zone.str.startswith("IT")
print("\n== footprint (record path, both arms on identical cells)")
print(pd.DataFrame({"all-39": blk(M), "ex-IT": blk(M[~isit])}).T.round(2).to_string())
for c in ("price_42", "price_43"):
    print(f"  ≤0 {c}: all-39 {neg(M, c)}; ex-IT {neg(M[~isit], c)}")
print("\n== per ISO week (all-39 | ex-IT MAE)")
W = M.groupby("wk").apply(blk, include_groups=False)
W2 = M[~isit].groupby("wk").apply(blk, include_groups=False)
W["days"] = M.groupby("wk").day.nunique(); W["exIT_mae_42"] = W2.mae_42; W["exIT_mae_43"] = W2.mae_43; W["exIT_bias_42"] = W2.bias_42; W["exIT_bias_43"] = W2.bias_43
print(W[["days", "n", "act", "mae_42", "mae_43", "bias_42", "bias_43", "corr_42", "corr_43", "exIT_mae_42", "exIT_mae_43", "exIT_bias_42", "exIT_bias_43"]].round(2).to_string())
print("\n== per day (all-39 MAE; better = cv43 lower)")
D = M.groupby("day").apply(blk, include_groups=False); D2 = M[~isit].groupby("day").apply(blk, include_groups=False)
D["d"] = D.mae_43 - D.mae_42; D["d_exIT"] = D2.mae_43 - D2.mae_42
print(D[["n", "act", "mae_42", "mae_43", "d", "d_exIT", "bias_42", "bias_43"]].round(2).to_string())
print(f"days better/worse/equal (all-39): {(D.d < -0.005).sum()}/{(D.d > 0.005).sum()}/{(D.d.abs() <= 0.005).sum()}; ex-IT: {(D.d_exIT < -0.005).sum()}/{(D.d_exIT > 0.005).sum()}")
print("\n== per zone")
Z = M.groupby("zone").apply(blk, include_groups=False); Z["d"] = Z.mae_43 - Z.mae_42
print(Z[["n", "act", "mae_42", "mae_43", "d", "bias_42", "bias_43", "corr_42", "corr_43"]].round(2).sort_values("d").to_string())
print(f"zones better/worse: {(Z.d < -0.005).sum()}/{(Z.d > 0.005).sum()}")
# live comparison: only cells where live weather lead-1 exists (different input track!)
if "weather" in M:
    X = M[M.weather.notna()].rename(columns={"weather": "price_live"})
    xi = X.zone.str.startswith("IT")
    print(f"\n== LIVE lead-1 weather track (pre-gate GFS inputs, cv as published) vs record-path arms, SAME {len(X)} cells")
    print(pd.DataFrame({"all-39": blk(X, ("price_42", "price_43", "price_live")), "ex-IT": blk(X[~xi], ("price_42", "price_43", "price_live"))}).T.round(2).to_string())
    print(f"  ≤0 live: all-39 {neg(X, 'price_live')}")
