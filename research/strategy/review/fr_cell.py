"""Reference cell for the review: FR CCGT exclusive vs hourly_ac (and vs hourly_mc), base cost cell (su 1, nl 1), pen 0,
hourly bids on hourly realised prices, k_su per format calibrated on CAL (score_pt.py rule), EVAL mean €/MW-d and the
day-block 90% CI (10,000 draws, seed 4646, numpy default_rng, 5th/95th percentiles — score_pt.py's boot()).
usage: python -I fr_cell.py CAL.csv EVAL.csv"""
import sys
import numpy as np, pandas as pd
cal, ev = pd.read_csv(sys.argv[1]), pd.read_csv(sys.argv[2])
base = lambda d: d[(d.pen == 0) & (d.res_bid == 60) & (d.res_eval == 60) & (d.su_scale == 1) & (d.nl_scale == 1) &
                   (d.zone == "FR") & (d.arch == "CCGT")]
c = base(cal); g = c.groupby(["format", "k_su"]).profit.mean().reset_index()
k = g.loc[g.groupby("format").profit.idxmax()].set_index("format").k_su.to_dict()
e = base(ev); e = e[[np.isclose(r.k_su, k.get(r.format, 1.0)) for r in e.itertuples()]].set_index(["format", "day"]).profit / 400.0


def boot(x, draws=10000, seed=4646):
    rng = np.random.default_rng(seed); idx = rng.integers(0, len(x), size=(draws, len(x))); m = x[idx].mean(1)
    return np.percentile(m, 5), np.percentile(m, 95)


print("k_su (cal):", {f: k[f] for f in ("hourly_ac", "exclusive")}, "| eval days:", e.loc["exclusive"].shape[0])
for b in ("hourly_ac", "hourly_mc"):
    d = (e.loc["exclusive"] - e.loc[b]).to_numpy()
    lo, hi = boot(d)
    print(f"FR CCGT exclusive − {b}: {d.mean():+.2f} [{lo:+.2f}, {hi:+.2f}] €/MW-d   (exclusive {e.loc['exclusive'].mean():.2f}, {b} {e.loc[b].mean():.2f})")
