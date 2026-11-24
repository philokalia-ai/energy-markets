"""Paired day-block bootstrap for the combined Timestral + physics check (exp 2), as cv46's combined-*/boot.md.
usage: venv-tsfm/bin/python comb_boot.py BASE_COMB_ROOT CAND_COMB_ROOT BASE_PHYS CAND_PHYS OUT.md [--start --end]
Uses score_2y.py's own loaders and actuals (em-tsfm 14370a8, docs/experiments/tsfm-2y-backtest), so the cells are
score_2y's: SDAC hourly actual, D-1 naive, finite actual/naive/forecast. Common cells of the two arms per slice;
market days resampled with replacement, 10,000 draws, numpy default_rng(4646), 90 % = 5th/95th percentiles of the
cell-weighted ΔMAE (score_cv46.boot logic). Slices: all cells and score_2y's regions; combined and physics-only."""
import argparse
import os
import sys

import numpy as np
import pandas as pd

TSD = os.path.expanduser("~/armada/em-tsfm/docs/experiments/tsfm-2y-backtest")
sys.path.insert(0, TSD)
import score_2y as S  # noqa: E402
import duckdb  # noqa: E402


def boot(days, diff, draws=10000, seed=4646):
    codes, uniq = pd.factorize(days)
    Sm = np.bincount(codes, weights=diff, minlength=len(uniq)); N = np.bincount(codes, minlength=len(uniq)).astype(float)
    rng = np.random.default_rng(seed); out = np.empty(draws)
    for i in range(0, draws, 1000):
        idx = rng.integers(0, len(uniq), size=(min(1000, draws - i), len(uniq))); out[i:i + len(idx)] = Sm[idx].sum(1) / N[idx].sum(1)
    return float(np.percentile(out, 5)), float(np.percentile(out, 95))


def paired(b, c, label):
    m = b.merge(c[["zone", "t", "f"]], on=["zone", "t"], suffixes=("_b", "_c"))
    rows = []
    for name, g in [("all cells", m)] + [(r, m[m.zone.map(S.ZONE_REGION) == r]) for r in S.REGIONS]:
        if g.empty:
            continue
        eb, ec, en = (g.f_b - g.actual).abs(), (g.f_c - g.actual).abs(), (g.naive - g.actual).abs()
        lo, hi = boot(g.day.to_numpy(), (ec - eb).to_numpy())
        rows.append(f"| {label} | {name} | {len(g):,} | {g.day.nunique()} | {eb.mean() / en.mean():.4f} → {ec.mean() / en.mean():.4f} | "
                    f"{eb.mean():.3f} → {ec.mean():.3f} | {ec.mean() - eb.mean():+.3f} [{lo:+.3f}, {hi:+.3f}] | "
                    f"{(g.f_b - g.actual).mean():+.2f} → {(g.f_c - g.actual).mean():+.2f} |")
    return rows


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("base_comb"); ap.add_argument("cand_comb"); ap.add_argument("base_phys"); ap.add_argument("cand_phys")
    ap.add_argument("out"); ap.add_argument("--start", default="2026-09-01"); ap.add_argument("--end", default="2026-11-14")
    ap.add_argument("--extract", default=os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb"))
    a = ap.parse_args()
    con = duckdb.connect(a.extract, read_only=True)
    fr = {"cb": S.load_tsfm(a.base_comb, "postsim"), "cc": S.load_tsfm(a.cand_comb, "postsim"),
          "pb": S.load_phys(a.base_phys), "pc": S.load_phys(a.cand_phys)}
    fr = {k: f[(f.day >= a.start) & (f.day <= a.end)] for k, f in fr.items()}
    fr = S.attach_actuals(con, fr)
    L = ["# Combined Timestral + physics, ShapeConduct(0.0) − baseline (cv46 record PR): paired day-block bootstrap", "",
         f"Window {a.start}..{a.end}; cells = score_2y.py's (SDAC hourly, D-1 naive); 10,000 draws, seed 4646.", "",
         "| forecast | slice | cells | days | rMAE base → cand | MAE base → cand | ΔMAE [90 %] | bias base → cand |",
         "|---|---|---|---|---|---|---|---|"]
    L += paired(fr["cb"], fr["cc"], "combined")
    L += paired(fr["pb"], fr["pc"], "physics only")
    txt = "\n".join(L)
    open(a.out, "w").write(txt + "\n")
    print(txt)
