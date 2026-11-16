"""Compact PR table: each arm vs base on the paired (day, zone, UTC hour) cells.
usage: summary.py BASE ARM1 ARM2 ...   (labels = dirs under results/blocks)"""
from pathlib import Path
import sys, os, glob, json, re, pandas as pd, numpy as np
R = (os.environ.get('BLOCKS_RESULTS_DIR') or sys.exit("Set BLOCKS_RESULTS_DIR to the required local file or directory"))
def load(label):
    out = []
    for f in sorted(glob.glob(f"{R}/{label}/2026-*-??.csv")):
        df = pd.read_csv(f); df["t"] = pd.to_datetime(df.period.astype(str), format="%Y%m%d-%H%M")
        df["day"] = os.path.basename(f)[:10]; out.append(df[["zone", "t", "day", "price"]])
    return pd.concat(out) if out else None
rows = []
for f in glob.glob(str(Path((os.environ.get('EM_LIVE_DIR') or sys.exit("Set EM_LIVE_DIR to the required local file or directory"))) / '*.json')):
    z = os.path.basename(f)[:-5]
    for d in json.load(open(f))["days"]:
        for h, a in zip(d.get("hours", []), d.get("actual", []) or []):
            if a is not None: rows.append((z, h, a))
act = pd.DataFrame(rows, columns=["zone", "t", "act"])
act["t"] = pd.to_datetime(act.t, utc=True).dt.tz_localize(None)
act = act.drop_duplicates(["zone", "t"]); act["act"] = act.act.round(8)
def st(g, c):
    e = g[c] - g.act
    return dict(mae=e.abs().mean(), bias=e.mean(), corr=np.corrcoef(g[c], g.act)[0, 1],
                hit=int(((g[c] <= 0) & (g.act <= 0)).sum()), fa=int(((g[c] <= 0) & (g.act > 0)).sum()))
def timing(label):
    f = f"{R}/{label}/timing.tsv"
    if not os.path.exists(f): return ""
    t = pd.read_csv(f, sep="\t", header=None, names=["day", "status", "solve", "wall", "msg"]).drop_duplicates("day", keep="last")
    return f"wall {t.wall.mean()/60:.0f} min/day, {int((t.status!='optimal').sum())} non-optimal day(s)"
def blocks_log(label):
    acc, pab, cap = [], [], 0
    for f in glob.glob(f"{R}/{label}.?.log"):
        for line in open(f, errors="ignore"):
            m = re.search(r"blocks (\d+)/(\d+) accepted \((\d+) PAB-rejected\)", line)
            if m: acc.append((int(m[1]), int(m[2]), int(m[3])))
            if "still paradoxically" in line: cap += 1
    if not acc: return ""
    a = np.array(acc)
    return f"blocks accepted {a[:,0].sum()/a[:,1].sum():.0%} of {a[:,1].mean():.0f}/master call, PAB-rejected {a[:,2].max()} max, {cap} call(s) hit the PAB round cap"
base = sys.argv[1]; B = load(base)
print(f"| arm | days | cells | MAE all (Δ) | MAE ex-IT (Δ) | bias | corr | ≤0 hit / FA | cap/floor cells |")
print("|---|---|---|---|---|---|---|---|---|")
for arm in sys.argv[2:]:
    T = load(arm)
    if T is None: print(f"| {arm} | 0 | — |"); continue
    m = B.merge(T, on=["zone", "t", "day"], suffixes=("_b", "_t")).merge(act, on=["zone", "t"])
    for c in ("price_b", "price_t"): m[c] = m[c].round(8)
    cap = ((m[["price_b", "price_t"]] >= 2999).any(axis=1) | (m[["price_b", "price_t"]] <= -499).any(axis=1))
    ex = m[~m.zone.str.startswith("IT-")]
    a, b_ = st(m, "price_b"), st(m, "price_t"); ea, eb = st(ex, "price_b"), st(ex, "price_t")
    print(f"| {arm} | {m.day.nunique()} | {len(m)} | {a['mae']:.2f}→{b_['mae']:.2f} ({b_['mae']-a['mae']:+.2f}) | "
          f"{ea['mae']:.2f}→{eb['mae']:.2f} ({eb['mae']-ea['mae']:+.2f}) | {a['bias']:+.1f}→{b_['bias']:+.1f} | "
          f"{a['corr']:.3f}→{b_['corr']:.3f} | {a['hit']}/{a['fa']} → {b_['hit']}/{b_['fa']} | {int(cap.sum())} |")
    print(f"<!-- {arm}: days {sorted(m.day.unique())}; {timing(arm)}; base {timing(base)}; {blocks_log(arm)} -->")
