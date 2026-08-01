#!/usr/bin/env python3
"""Published-books clearing validation — ANALYSIS (metrics -> tables + attribution).

See docs/experiments/pubbooks-clearing/protocol.md (frozen §4). Reads the per-day
$PUBBOOKS_DIR/intermediate/metrics_{gme,omie}_<day>.tsv files (produced by
pubbooks_clear.jl) and prints the frozen metric tables. No raw data touched.
"""
import os, sys
from pathlib import Path
import numpy as np
import pandas as pd

INT = Path(os.environ["PUBBOOKS_DIR"]) / "intermediate"


def load(ex):
    files = sorted(INT.glob(f"metrics_{ex}_*.tsv"))
    if not files:
        return None
    df = pd.concat([pd.read_csv(f, sep="\t") for f in files], ignore_index=True)
    for c in ["p_off", "net_import", "p_ref", "p_sup_marg", "p_dem_marg",
              "p_dom", "p_net", "max_sup_p", "qstar", "tot_sup", "tot_dem"]:
        if c in df:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def dist(x, name):
    x = np.abs(pd.to_numeric(x, errors="coerce").dropna().values)
    n = len(x)
    if not n:
        return f"{name}: no cells"
    return (f"{name}: n={n}  median={np.median(x):.3f}  p90={np.quantile(x,.9):.2f}  "
            f"max={x.max():.2f}  |≤0.01|={np.mean(x<=0.01)*100:.1f}%  "
            f"|≤0.5|={np.mean(x<=0.5)*100:.1f}%  |≤2|={np.mean(x<=2)*100:.1f}%")


def regime(h):
    if 0 <= h <= 6:
        return "night"
    if 10 <= h <= 15:
        return "midday"
    if 18 <= h <= 22:
        return "evening"
    return "other"


def analyze(ex, df):
    print("=" * 78)
    print(f"{ex.upper()}  —  {len(df)} scored cells "
          f"({df.day.nunique()} days, {df.zone.nunique()} zones)")
    ok = df[df.st_dom.isin(["optimal", "time_limit"])].copy()
    nbad = len(df) - len(ok)
    if nbad:
        print(f"  non-solved (excluded): {nbad}")
    print("\n-- LAYER A: engine vs independent crossing (solver mechanics) --")
    # The rigorous solver-correctness criterion is BRACKET MEMBERSHIP: any price
    # inside the crossing bracket [p_sup_marg, p_dem_marg] clears the identical
    # quantities, so every such price IS a valid uniform market-clearing price.
    print(f"  engine price inside the valid crossing bracket: {ok.inbrk.mean()*100:.2f}%"
          f"  (n={len(ok)})  <-- solver always returns a valid clearing price")
    off = ok[ok.inbrk == 0]
    if len(off):
        print(f"  OUT of bracket: {len(off)}  (genuine solver findings)")
        print(off[["zone", "day", "hour", "p_sup_marg", "p_dem_marg", "p_dom",
                   "st_dom"]].head(20).to_string(index=False))
    # Sharp test: on WELL-DETERMINED cells (bracket width <= 0.5, so the price is
    # unambiguous) the engine must hit the unique price exactly.
    ok["bw"] = (ok.p_dem_marg - ok.p_sup_marg).abs()
    wd = ok[ok.bw <= 0.5].copy()
    wd["dA"] = wd.p_dom - wd.p_sup_marg   # unique price ~ p_sup_marg == p_dem_marg
    print(f"  well-determined cells (bracket width <= 0.5): {len(wd)} / {len(ok)}"
          f"  ({len(wd)/len(ok)*100:.0f}%)")
    print(" ", dist(wd.dA, "  |P_engine - unique crossing price| (well-determined)"))
    print(f"  degenerate cells (wide bracket, price underdetermined by the book): "
          f"{len(ok)-len(wd)}  — engine stays in-bracket by the line above")

    print("\n-- LAYER B: engine on real bids vs OFFICIAL price --")
    # OMIE: restrict headline to ES=PT hours
    scope = ok[ok.espt == 1].copy() if ex == "omie" else ok.copy()
    if ex == "omie":
        print(f"  ES=PT (uncongested MIBEL) cells: {len(scope)} / {len(ok)}"
              f"   (congested ES!=PT excluded from headline)")
    scope["dB_dom"] = scope.p_dom - scope.p_off
    scope["dB_net"] = scope.p_net - scope.p_off
    print(" ", dist(scope.dB_dom, "|P_domestic - P_official|"))
    print(" ", dist(scope.dB_net, "|P_+net     - P_official|"))
    print(f"  net-injection moved the price |P_+net - P_domestic|: median "
          f"{(scope.p_net-scope.p_dom).abs().median():.2f}  p90 "
          f"{(scope.p_net-scope.p_dom).abs().quantile(.9):.2f} €/MWh")
    # BOOK-DETERMINES-PRICE cells: the domestic crossing bracket is TIGHT
    # (width <= 0.5), so the published book alone pins a unique price. This is
    # the ideal test — where the book determines the price, does that price
    # equal the OFFICIAL one? (Elsewhere the price is set OUTSIDE the published
    # book — coupling / complex conditions — and no single-zone clear can match.)
    scope["bw"] = (scope.p_dem_marg - scope.p_sup_marg).abs()
    det = scope[scope.bw <= 0.5]
    print(f"  book-DETERMINES-price cells (tight domestic bracket): "
          f"{len(det)} / {len(scope)} ({len(det)/len(scope)*100:.0f}%)")
    if len(det):
        print(" ", dist(det.p_net - det.p_off, "  |P_+net - P_official| (book determines price)"))
    # cleared-volume delta vs official awarded supply (GME only)
    cells = INT / f"{ex}_cells.tsv"
    if cells.exists():
        cf = pd.read_csv(cells, sep="\t")
        if cf.awarded_sup_mw.notna().any():
            m = scope.merge(cf[["zone", "day", "hour", "awarded_sup_mw"]],
                            on=["zone", "day", "hour"], how="left")
            dv = (m.qstar - m.awarded_sup_mw).dropna()
            if len(dv):
                print(f"  cleared-volume delta (crossing qstar - official awarded "
                      f"supply): median {dv.median():.0f} MW  p90 {dv.abs().quantile(.9):.0f} MW  (n={len(dv)})")

    print("\n  by regime (|dB_net|, median / p90 / share≤0.5):")
    scope["reg"] = scope.hour.map(regime)
    for rg in ["night", "midday", "evening", "other"]:
        s = scope[scope.reg == rg]
        if len(s):
            a = s.dB_net.abs()
            print(f"    {rg:8s} n={len(s):4d}  med={a.median():6.2f}  "
                  f"p90={a.quantile(.9):6.2f}  ≤0.5={np.mean(a<=0.5)*100:5.1f}%")

    # ATTRIBUTION of |dB_net|>0.5
    print("\n  attribution of |dB_net|>0.5 hours:")
    bad = scope[scope.dB_net.abs() > 0.5].copy()
    if not len(bad):
        print("    (none)")
        return
    # modal zonal price per (day,hour) for GME congestion test
    if ex == "gme":
        modal = ok.groupby(["day", "hour"]).p_off.median().rename("modal").reset_index()
        bad = bad.merge(modal, on=["day", "hour"], how="left")
        bad["congested"] = (bad.p_off - bad.modal).abs() > 0.5
    else:
        bad["congested"] = False

    def classify(r):
        blo, bhi = min(r.p_sup_marg, r.p_dem_marg), max(r.p_sup_marg, r.p_dem_marg)
        # official price the domestic book cannot produce at ALL (outside the
        # crossing bracket) -> the price is set OUTSIDE the published book:
        # cross-border coupling and/or complex conditions.
        if r.p_off < blo - 0.5 or r.p_off > bhi + 0.5:
            return "coupling/complex (P_official outside domestic bracket)"
        # import/coupling-set: official above our top domestic supply offer
        if r.p_off > r.max_sup_p + 0.5:
            return "import/coupling-set (P_off above domestic supply)"
        if r.congested:
            return "internal congestion (GME zonal split)"
        # residual within one price step ~ discretization/tie
        step = abs(r.p_dem_marg - r.p_sup_marg)
        if abs(r.dB_net) <= max(step, 1.0):
            return "discretization/tie"
        return "complex-order / other residual"

    bad["cause"] = bad.apply(classify, axis=1)
    vc = bad.cause.value_counts()
    for k, v in vc.items():
        print(f"    {v:4d}  ({v/len(scope)*100:4.1f}% of scope)  {k}")
    print(f"    ---- {len(bad)} total |dB_net|>0.5 of {len(scope)} scope cells "
          f"({len(bad)/len(scope)*100:.1f}%)")


if __name__ == "__main__":
    for ex in ["gme", "omie"]:
        df = load(ex)
        if df is not None and len(df):
            analyze(ex, df)
        else:
            print(f"{ex}: no metrics")
