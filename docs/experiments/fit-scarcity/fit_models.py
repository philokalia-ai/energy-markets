#!/usr/bin/env python3
"""Fit the markup-model ladder on the fit-scarcity dataset.

Models:
  A0  hand constants (baseline, not fit)      y = 1 + ks*max(0, th - m)^2 + kp * d^p
  A   same form, constants refit (NLS)
  B   HistGradientBoosting on the rich feature set (local-feature ceiling)
  D   B + dynamic/lagged features (prev-day same-hour markup, within-day lag)

Outputs: results_ladder.tsv, results_hourly_bias.tsv, results_transfer.tsv,
fitted_constants.tsv  (all tab-separated).
"""
import numpy as np
import pandas as pd
from scipy.optimize import least_squares
from sklearn.ensemble import HistGradientBoostingRegressor

df = pd.read_csv("dataset.tsv.gz", sep="\t", parse_dates=["ts", "day"])
# DE_LU has no hydro-storage reporting: impute a constant (trees ignore
# constant columns; keeps the shared feature list usable across zones).
df["fill_frac"] = df.groupby("zone")["fill_frac"].transform(
    lambda s: s.fillna(s.median() if s.notna().any() else 1.0))

TRAIN = (df["day"] >= "2023-07-01") & (df["day"] <= "2025-06-30")
TEST = (df["day"] >= "2025-07-01") & (df["day"] <= "2026-06-30")
APR26 = (df["day"] >= "2026-04-01") & (df["day"] <= "2026-04-30")

HAND = {  # from src/merit_order/zone_profiles.jl
    "GR": (3.0, 1.4, 1.2, 4.0),     # SEE_PROFILE (kappa_s, theta, kappa_p, p)
    "BG": (3.0, 1.4, 1.2, 4.0),     # SEE_PROFILE
    "ES": (3.0, 1.4, 1.2, 4.0),     # IBERIA = SEE_PROFILE
    "DE_LU": (1.5, 1.25, 0.6, 4.0), # CONTINENTAL_PROFILE
}

def form(params, m, d):
    ks, th, kp, p = params
    return 1.0 + ks * np.maximum(0.0, th - m) ** 2 + kp * d ** p

def metrics(zone_df, yhat_markup):
    pred_price = yhat_markup * zone_df["srmc_gas"].values
    act = zone_df["price"].values
    err = pred_price - act
    return dict(mae=np.mean(np.abs(err)),
                bias=np.mean(err),
                corr=np.corrcoef(pred_price, act)[0, 1],
                rmse=np.sqrt(np.mean(err ** 2)))

def hourly_bias(zone_df, yhat_markup):
    pred_price = yhat_markup * zone_df["srmc_gas"].values
    e = pd.DataFrame({"hour": zone_df["hour"].values,
                      "err": pred_price - zone_df["price"].values})
    return e.groupby("hour")["err"].mean()

def refit(zone_df):
    m, d, y = (zone_df[c].values for c in ["margin", "d_hat", "y"])
    def resid(p): return form(p, m, d) - y
    best = None
    for x0 in [(3.0, 1.4, 1.2, 4.0), (1.0, 1.2, 0.5, 2.0), (0.5, 1.8, 1.0, 6.0)]:
        r = least_squares(resid, x0, bounds=([0, 0.8, 0, 0.5], [50, 3.0, 10, 12]),
                          loss="linear")
        if best is None or r.cost < best.cost:
            best = r
    return best.x

FEATS = ["margin", "d_hat", "hour", "dow", "res_share", "imp_share",
         "fill_frac", "ttf", "net_demand", "net_imports"]

def add_lags(d):
    d = d.sort_values("ts").copy()
    d["y_prevday"] = d.groupby("hour")["y"].shift(1)  # same hour, previous day
    d["y_lag1"] = d["y"].shift(1)                      # previous hour (same-day)
    contig = (d["ts"].diff() == pd.Timedelta("1h"))
    d.loc[~contig, "y_lag1"] = np.nan
    d["dd_lag1"] = d["d_hat"].diff()
    d.loc[~contig, "dd_lag1"] = np.nan
    return d

def gbt(train, test, feats):
    tr = train.dropna(subset=feats + ["y"])
    te = test.dropna(subset=feats + ["y"])
    mdl = HistGradientBoostingRegressor(max_iter=500, learning_rate=0.05,
                                        max_depth=None, min_samples_leaf=50,
                                        random_state=0)
    mdl.fit(tr[feats], tr["y"])
    return mdl, te, mdl.predict(te[feats])

ladder, hb_rows, const_rows, transfer = [], [], [], []

for zone in ["GR", "BG", "ES", "DE_LU"]:
    zdf = df[df["zone"] == zone]
    tr = zdf[(zdf["day"] >= "2023-07-01") & (zdf["day"] <= "2025-06-30")]
    te = zdf[(zdf["day"] >= "2025-07-01") & (zdf["day"] <= "2026-06-30")]
    ap = zdf[(zdf["day"] >= "2026-04-01") & (zdf["day"] <= "2026-04-30")]

    # --- A0: hand constants
    hand = HAND[zone]
    for split, sdf in [("test", te), ("apr26", ap)]:
        r = metrics(sdf, form(hand, sdf["margin"].values, sdf["d_hat"].values))
        ladder.append(dict(zone=zone, model="A0_hand", split=split, **r))
    hb_rows.append(("A0_hand", zone,
                    hourly_bias(te, form(hand, te["margin"].values, te["d_hat"].values))))

    # --- A: refit
    fitted = refit(tr)
    const_rows.append(dict(zone=zone, kappa_s=fitted[0], theta=fitted[1],
                           kappa_p=fitted[2], p=fitted[3],
                           hand_kappa_s=hand[0], hand_theta=hand[1],
                           hand_kappa_p=hand[2], hand_p=hand[3]))
    for split, sdf in [("test", te), ("apr26", ap)]:
        r = metrics(sdf, form(fitted, sdf["margin"].values, sdf["d_hat"].values))
        ladder.append(dict(zone=zone, model="A_refit", split=split, **r))
    hb_rows.append(("A_refit", zone,
                    hourly_bias(te, form(fitted, te["margin"].values, te["d_hat"].values))))

    # --- B: GBT rich features
    mdl, te_b, pred = gbt(tr, te, FEATS)
    for split, sdf in [("test", te), ("apr26", ap)]:
        s = sdf.dropna(subset=FEATS + ["y"])
        r = metrics(s, mdl.predict(s[FEATS]))
        ladder.append(dict(zone=zone, model="B_gbt", split=split, **r))
    hb_rows.append(("B_gbt", zone, hourly_bias(te_b, pred)))

    # --- B core-features-only GBT (margin, d_hat): flexible fit of SAME inputs as A
    mdl_c, te_c, pred_c = gbt(tr, te, ["margin", "d_hat"])
    r = metrics(te_c, pred_c)
    ladder.append(dict(zone=zone, model="B_gbt_core", split="test", **r))
    hb_rows.append(("B_gbt_core", zone, hourly_bias(te_c, pred_c)))

    # --- D: dynamics (lagged markups). NOTE: y_lag1 (within-day previous hour)
    # is NOT D-1 legal for true forecasting (the DA auction clears all 24 h at
    # once); y_prevday IS legal. Report both to answer "do dynamics matter".
    zl = add_lags(zdf)
    trl = zl[(zl["day"] >= "2023-07-01") & (zl["day"] <= "2025-06-30")]
    tel = zl[(zl["day"] >= "2025-07-01") & (zl["day"] <= "2026-06-30")]
    mdl_dp, te_dp, pred_dp = gbt(trl, tel, FEATS + ["y_prevday"])
    r = metrics(te_dp, pred_dp)
    ladder.append(dict(zone=zone, model="D_gbt_prevday", split="test", **r))
    hb_rows.append(("D_gbt_prevday", zone, hourly_bias(te_dp, pred_dp)))
    mdl_dl, te_dl, pred_dl = gbt(trl, tel, FEATS + ["y_prevday", "y_lag1", "dd_lag1"])
    r = metrics(te_dl, pred_dl)
    ladder.append(dict(zone=zone, model="D_gbt_full_dyn", split="test", **r))
    hb_rows.append(("D_gbt_full_dyn", zone, hourly_bias(te_dl, pred_dl)))

# ---- transfer: fit GR (form A and GBT core) -> test other zones
gr_tr = df[(df["zone"] == "GR") & (df["day"] >= "2023-07-01") & (df["day"] <= "2025-06-30")]
gr_fit = refit(gr_tr)
mdl_gr, _, _ = gbt(gr_tr, gr_tr, ["margin", "d_hat"])
for zone in ["BG", "ES", "DE_LU"]:
    te = df[(df["zone"] == zone) & (df["day"] >= "2025-07-01") & (df["day"] <= "2026-06-30")]
    r = metrics(te, form(gr_fit, te["margin"].values, te["d_hat"].values))
    transfer.append(dict(fit_on="GR", test_on=zone, model="A_refit_GR", **r))
    s = te.dropna(subset=["margin", "d_hat", "y"])
    r = metrics(s, mdl_gr.predict(s[["margin", "d_hat"]]))
    transfer.append(dict(fit_on="GR", test_on=zone, model="B_gbt_core_GR", **r))
    # comparison rows: the zone's own refit + own hand constants (from ladder)
    own = [l for l in ladder if l["zone"] == zone and l["split"] == "test"
           and l["model"] in ("A0_hand", "A_refit", "B_gbt_core")]
    for l in own:
        transfer.append(dict(fit_on=zone, test_on=zone, model=l["model"] + "_own",
                             mae=l["mae"], bias=l["bias"], corr=l["corr"], rmse=l["rmse"]))

pd.DataFrame(ladder).to_csv("results_ladder.tsv", sep="\t", index=False, float_format="%.3f")
pd.DataFrame(const_rows).to_csv("fitted_constants.tsv", sep="\t", index=False, float_format="%.3f")
pd.DataFrame(transfer).to_csv("results_transfer.tsv", sep="\t", index=False, float_format="%.3f")
hb = pd.DataFrame({f"{m}_{z}": s for m, z, s in hb_rows})
hb.to_csv("results_hourly_bias.tsv", sep="\t", float_format="%.2f")
print(pd.DataFrame(ladder).to_string(index=False))
print()
print(pd.DataFrame(const_rows).to_string(index=False))
