"""Compare TSFM P(price <= 0) with agent `collapse`'s pre-gate logistic on common cells.

Target y = settled hourly-mean price <= 0 (from the panel; cross-checked against collapse's y).
Usage: COLLAPSE_SET=D1|D2 python compare_collapse.py fc_t209_uni_L1 ...  (default D1)
"""
import os, sys
import numpy as np, pandas as pd

OUT = (os.environ.get('TSFM_OUT') or sys.exit("Set TSFM_OUT to the required local file or directory"))
RES = (os.environ.get('EM_RESULTS_DIR') or sys.exit("Set EM_RESULTS_DIR to the required local file or directory"))
# Pinned comparators (agent `collapse`, canonical 1e-8-rounded labels, 57,111 cells / 743 events):
#   D1 (default, like-for-like with the *_L1 TSFM runs): collapse-probability-primary, settled_history_lag=1
#   D2 (conservative, like-for-like with the untagged D-2 runs): collapse-probability-v2
# The superseded collapse-probability/ (741 events, unrounded labels) must not be used.
COMPARATORS = {"D1": f"{RES}/collapse-probability-primary/pregate_0630-predictions.csv.gz",
               "D2": f"{RES}/collapse-probability-v2/pregate_0630-predictions.csv.gz"}
WHICH = os.environ.get("COLLAPSE_SET", "D1")
COL = COMPARATORS[WHICH]
N_CELLS, N_EVENTS = 57111, 743


def auc(s, y):
    y = np.asarray(y, bool); r = pd.Series(np.asarray(s, float)).rank().values
    return (r[y].sum() - y.sum() * (y.sum() + 1) / 2) / (y.sum() * (~y).sum())


def scores(p, y):
    p = np.clip(np.asarray(p, float), 1e-6, 1 - 1e-6)
    return dict(Brier=np.mean((p - y) ** 2), AUC=auc(p, y),
                logloss=-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)),
                mean_p=p.mean(), base_rate=np.mean(y))


def main(names):
    c = pd.read_csv(COL, parse_dates=["t"])
    c = c.pivot_table(index=["zone", "t", "market_date", "y"], columns="model", values="probability").reset_index()
    df = c
    for n in names:
        f = pd.read_parquet(f"{OUT}/{n}.parquet")[["zone", "t", "p_le0"]].rename(columns={"p_le0": n.replace("fc_", "")})
        df = df.merge(f, on=["zone", "t"], how="inner")
    panel = pd.read_parquet(f"{OUT}/panel.parquet")[["zone", "t", "price"]]
    df = df.merge(panel, on=["zone", "t"], how="left")
    dis = int(((df.price <= 0).astype(int) != df.y).sum())
    print(f"comparator {WHICH}: {COL}\ncommon cells {len(df)}, y==1 {int(df.y.sum())}, label disagreements {dis}")
    assert len(df) == N_CELLS and int(df.y.sum()) == N_EVENTS, "unexpected comparator cells/events"
    assert dis == 0 and df.price.notna().all(), "comparator labels must equal panel price<=0"
    models = ["climatology", "logistic"] + [n.replace("fc_", "") for n in names]
    rows = []
    for scope, sub in (("all39", df), ("exIT", df[~df.zone.str.startswith("IT-")])):
        for m in models:
            rows.append(dict(scope=scope, model=m, n=len(sub), **scores(sub[m], sub.y.values)))
    # simple equal-weight blend of logistic and each TSFM (no fitting)
    for n in names:
        k = n.replace("fc_", "")
        df[f"blend_{k}"] = (df.logistic + df[k]) / 2
        for scope, sub in (("all39", df), ("exIT", df[~df.zone.str.startswith("IT-")])):
            rows.append(dict(scope=scope, model=f"blend_{k}", n=len(sub), **scores(sub[f"blend_{k}"], sub.y.values)))
    tab = pd.DataFrame(rows)
    pd.set_option("display.width", 200)
    print(tab.round(5).to_string(index=False))
    tab.to_csv(f"{OUT}/collapse_compare_{WHICH}.csv", index=False)
    # reliability of each model (deciles of predicted p, events only where p >= 0.01)
    bins = [0, 0.01, 0.05, 0.1, 0.2, 0.4, 0.6, 0.8, 1.0001]
    for m in models[1:]:
        g = df.groupby(pd.cut(df[m], bins, right=False), observed=True).agg(n=("y", "size"), p=(m, "mean"), freq=("y", "mean"))
        print(f"\nreliability {m}\n{g.round(3).to_string()}")
    # per zone events and Brier
    pz = df.groupby("zone").apply(lambda g: pd.Series({"events": g.y.sum(), **{m: np.mean((g[m] - g.y) ** 2) for m in models}}),
                                  include_groups=False)
    print("\nper-zone Brier (zones with events):")
    print(pz[pz.events > 0].round(4).to_string())


if __name__ == "__main__":
    main(sys.argv[1:])
