# Assemble GFS lead-1 vintage features + zone wind actuals, refit the wind
# ridge per zone (same family as v1: X = [1, pcurve.(v100), v100/3.6]),
# validate v1-on-GFS vs v2-on-GFS on the last-8-week holdout, and emit
# bin/res_models_v2.json (solar + cells + non-wind zones copied from v1).
import json, os, csv, sys
import numpy as np
from datetime import datetime, timedelta

SP = os.environ.get("GFS_OUT", os.path.expanduser("~/.cache/euphemia-gfs-refit"))
WT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
PACK_V1 = os.path.join(WT, "bin/res_models_v1.json")
OUT_PACK = os.path.join(WT, "bin/res_models_v2.json")

H0 = datetime(2024, 7, 1)
H1 = datetime(2026, 7, 1)          # exclusive
NH = int((H1 - H0).total_seconds() // 3600)
HOLDOUT0 = datetime(2026, 5, 5)    # last 8 weeks held out
INNERVAL0 = datetime(2026, 3, 10)  # lambda-selection slice (tail of train)
LAMBDAS = (0.1, 1.0, 10.0, 100.0, 1000.0)

hidx = lambda t: int((t - H0).total_seconds() // 3600)
hours = np.array([H0 + timedelta(hours=i) for i in range(NH)])

# ---- 1. GFS vintage matrix [ncells, NH] ----
cells = [tuple(c) for c in json.load(open(os.path.join(SP, "cells.json")))]
cell_of = {c: i for i, c in enumerate(cells)}
V = np.full((len(cells), NH), np.nan, dtype=np.float32)
raw = sorted(os.listdir(os.path.join(SP, "raw")))
nb = (len(cells) + 49) // 50
for fn in raw:
    if not fn.endswith(".json"):
        continue
    bi = int(fn.split("_b")[1].split(".")[0])
    locs = json.load(open(os.path.join(SP, "raw", fn)))
    batch = cells[bi * 50:(bi + 1) * 50]
    assert len(locs) == len(batch), fn
    for c, loc in zip(batch, locs):
        hh = loc["hourly"]
        ts = hh["time"]
        vals = hh["wind_speed_100m_previous_day1"]
        i0 = hidx(datetime.fromisoformat(ts[0]))
        arr = np.array([np.nan if v is None else v for v in vals], dtype=np.float32)
        V[cell_of[c], i0:i0 + len(arr)] = arr
print(f"V: {V.shape}, NaN frac {np.isnan(V).mean():.4f}", flush=True)

# ---- 2. zone wind actuals ----
ztph = {}   # (zone, ptype) -> {hidx: mw}
with open(os.path.join(SP, "wind_actuals.csv")) as f:
    for r in csv.DictReader(f):
        t = datetime.fromisoformat(r["h"])
        if not (H0 <= t < H1):
            continue
        ztph.setdefault((r["zone"], r["production_type"]), {})[hidx(t)] = float(r["mw"])

pack = json.load(open(PACK_V1))
wind_zones = sorted(z for z, v in pack["zones"].items() if "wind" in v)

Y = {}
for z in wind_zones:
    types = [pt for (zz, pt) in ztph if zz == z]
    cov = {pt: len(ztph[(z, pt)]) for pt in types}
    # only types reporting in >= 30% of hours participate; hours missing any
    # participating type are dropped (avoid fake dips from sporadic gaps)
    keep = [pt for pt in types if cov[pt] >= 0.3 * NH]
    y = np.full(NH, np.nan)
    ok = np.ones(NH, dtype=bool)
    s = np.zeros(NH)
    for pt in keep:
        m = np.full(NH, np.nan)
        d = ztph[(z, pt)]
        m[list(d.keys())] = list(d.values())
        ok &= ~np.isnan(m)
        s += np.where(np.isnan(m), 0.0, m)
    y[ok] = s[ok]
    Y[z] = y
    print(f"{z}: types={ {pt: cov[pt] for pt in types} } kept={keep} hours={ok.sum()}", flush=True)

# ---- 3. per-zone fit + validation ----
def pcurve(v_kmh):
    x = v_kmh / 3.6
    p = np.clip((x - 3) / 9, 0, 1) ** 3
    p = np.where(x >= 12, 1.0, p)
    return np.where((x < 3) | (x >= 25), 0.0, p)

def ridge(X, y, lam):
    p = X.shape[1]
    A = X.T @ X + lam * np.eye(p)
    A[0, 0] -= lam                      # don't penalize intercept
    return np.linalg.solve(A, X.T @ y)

def stats(pred, act):
    corr = float(np.corrcoef(pred, act)[0, 1]) if len(act) > 2 else float("nan")
    mae = float(np.mean(np.abs(pred - act)))
    bias = float(np.mean(pred) / np.mean(act)) if np.mean(act) > 0 else float("nan")
    return corr, mae, bias

rows = []
v2_wind = {}
gr_holdout = None
for z in wind_zones:
    zcells = [tuple(c) for c in pack["zones"][z]["cells"]]
    ci = [cell_of[c] for c in zcells]
    Vz = V[ci, :].astype(np.float64)             # [ncells, NH] km/h
    valid = ~np.isnan(Vz).any(axis=0) & ~np.isnan(Y[z])
    X = np.hstack([np.ones((valid.sum(), 1)),
                   pcurve(Vz[:, valid].T), Vz[:, valid].T / 3.6])
    y = Y[z][valid]
    h = hours[valid]
    te = h >= HOLDOUT0
    tr = ~te
    va = tr & (h >= INNERVAL0)
    tri = tr & ~va
    if te.sum() < 24 * 14 or tri.sum() < 24 * 90:
        print(f"{z}: INSUFFICIENT DATA (train {tri.sum()}, test {te.sum()})", flush=True)
        continue
    c1 = np.array(pack["zones"][z]["wind"]["coef"], dtype=np.float64)
    # 5-fold chronological CV on the train window for lambda (by MAE)
    ntr = int(tr.sum())
    Xtr, ytr = X[tr], y[tr]
    folds = np.array_split(np.arange(ntr), 5)
    best, bl = np.inf, 1.0
    for lam in LAMBDAS:
        m = 0.0
        for f in folds:
            mask = np.ones(ntr, bool)
            mask[f] = False
            bb = ridge(Xtr[mask], ytr[mask], lam)
            m += np.mean(np.abs(np.maximum(Xtr[f] @ bb, 0) - ytr[f]))
        m /= len(folds)
        if m < best:
            best, bl = m, lam
    b2fit = ridge(Xtr, ytr, bl)                  # refit on full train
    # Both v1 and v2 are linear in the same features, so a convex blend
    # alpha*v2 + (1-alpha)*v1_rescaled is still in the family. v1's shape can
    # transfer well in some zones (Nordics) even though its LEVEL is wrong on
    # GFS input; rescale v1 to the train level, then pick alpha on the inner
    # (pre-holdout) validation slice by corr — alpha=1 (pure v2) is in the menu.
    s1 = ytr.mean() / max(np.maximum(Xtr @ c1, 0).mean(), 1e-9)
    c1s = c1 * s1
    va_p = {a: np.maximum(X[va] @ (a * b2fit + (1 - a) * c1s), 0) for a in (1.0, 0.75, 0.5, 0.25)}
    va_y = y[va]
    alpha = max(va_p, key=lambda a: np.corrcoef(va_p[a], va_y)[0, 1] if va_y.std() > 0 else 0.0)
    b = alpha * b2fit + (1 - alpha) * c1s
    p2 = np.maximum(X[te] @ b, 0)
    p1 = np.maximum(X[te] @ c1, 0)
    a = y[te]
    (c2c, c2m, c2b) = stats(p2, a)
    (c1c, c1m, c1b) = stats(p1, a)
    rows.append((z, len(a), c1c, c1m, c1b, c2c, c2m, c2b, bl, alpha))
    v2_wind[z] = {"coef": [float(x) for x in b], "lambda": float(bl),
                  "alpha_v1_blend": float(alpha),
                  "mean_mw": float(np.mean(y[tr])),
                  "val_corr": round(c2c, 4), "val_mae": round(c2m, 1)}
    if z == "GR":
        gr_holdout = (h[te], p2, p1, a)
    print(f"{z}: n_te={len(a)}  v1 corr={c1c:.3f} mae={c1m:.0f} bias={c1b:.2f} | "
          f"v2 corr={c2c:.3f} mae={c2m:.0f} bias={c2b:.2f} (lam={bl}, alpha={alpha})", flush=True)

# ---- 4. summary ----
print("\nzone | n | v1corr | v1mae | v1bias | v2corr | v2mae | v2bias | lam")
better = sum(1 for r in rows if r[5] > r[2])
bias_ok = sum(1 for r in rows if abs(r[7] - 1) < 0.05)
for r in rows:
    print("%-12s %5d  %.3f %7.0f  %.2f   %.3f %7.0f  %.2f  %g a=%g" % r)
print(f"\nv2 corr > v1 corr: {better}/{len(rows)};  |v2 bias|<5%: {bias_ok}/{len(rows)}")

# ---- 5. GR chain check: v2 vs ENTSO-E D-1 wind forecast on holdout ----
if gr_holdout is not None:
    dafc = {}
    with open(os.path.join(SP, "gr_wind_dafc.csv")) as f:
        for r in csv.DictReader(f):
            t = datetime.fromisoformat(r["h"])
            dafc[t] = dafc.get(t, 0.0) + float(r["mw"])
    ht, p2, p1, a = gr_holdout
    mask = np.array([t in dafc for t in ht])
    fc = np.array([dafc[t] for t in ht[mask]])
    c_v2 = np.corrcoef(p2[mask], fc)[0, 1]
    c_v1 = np.corrcoef(p1[mask], fc)[0, 1]
    c_fc = np.corrcoef(fc, a[mask])[0, 1]
    print(f"\nGR chain (holdout, n={mask.sum()}): corr(v2, ENTSOE-DAfc)={c_v2:.3f}  "
          f"corr(v1, DAfc)={c_v1:.3f}  corr(DAfc, actual)={c_fc:.3f}")

# ---- 6. emit pack ----
if "--emit" in sys.argv:
    for z, wm in v2_wind.items():
        pack["zones"][z]["wind"] = wm
    pack["version"] = 2
    pack["features"] = ("GFS-vintage-trained: wind ridge refit on open-meteo previous-runs "
                        "wind_speed_100m_previous_day1 (gfs_seamless, the ~1-day-ahead vintage "
                        "the live ex-ante track consumes) at the same eu_wind_cells; solar "
                        "coefficients unchanged from v1 (ERA5 shortwave_radiation — GFS-safe, "
                        "level 0.96-0.97)")
    pack["trained"] = ("wind: 2024-07-01..2026-05-04 (lambda on 2026-03-10.. tail), "
                       "holdout 2026-05-05..2026-06-30; solar: as v1 (2025-09-01..2026-06-30)")
    json.dump(pack, open(OUT_PACK, "w"), sort_keys=True)
    print(f"\nwrote {OUT_PACK} ({os.path.getsize(OUT_PACK)} bytes)")
    with open(os.path.join(SP, "validation_table.csv"), "w") as f:
        w = csv.writer(f)
        w.writerow(["zone", "n_holdout", "v1_corr", "v1_mae", "v1_bias",
                    "v2_corr", "v2_mae", "v2_bias", "lambda", "alpha_v1_blend"])
        w.writerows(rows)
