#!/usr/bin/env python3
"""Model D (structural variant): intraday relaxation ODE, D-1 legal.

    P_hat[h] = P_hat[h-1] + alpha * (F[h] - P_hat[h-1]),   P_hat[0] = F[0]

where F[h] = (1 + ks*max(0,th-margin)^2 + kp*d_hat^p) * SRMC is the static
form. This is the forward-Euler discretization of dP/dt = alpha*(F(t) - P):
price relaxes toward its static driver with inertia 1/alpha. Because the
recursion uses PREDICTED lags only, it needs nothing unavailable at D-1 —
unlike the observed-lag GBT variants in fit_models.py. Fitting alpha jointly
with the form constants answers "does intraday inertia matter at all?"
in the most interpretable way possible.
"""
import numpy as np
import pandas as pd
from scipy.optimize import least_squares

df = pd.read_csv("dataset.tsv.gz", sep="\t", parse_dates=["ts", "day"])

def simulate(params, days):
    """Roll the relaxation forward within each day; returns pred price array."""
    ks, th, kp, p, alpha = params
    out = []
    for _, g in days:
        F = (1.0 + ks * np.maximum(0.0, th - g["margin"].values) ** 2 +
             kp * g["d_hat"].values ** p) * g["srmc_gas"].values
        P = np.empty_like(F)
        P[0] = F[0]
        for h in range(1, len(F)):
            P[h] = P[h - 1] + alpha * (F[h] - P[h - 1])
        out.append(P)
    return np.concatenate(out)

rows = []
for zone in ["GR", "BG", "ES", "DE_LU"]:
    z = df[df["zone"] == zone].sort_values("ts")
    tr = z[(z["day"] >= "2023-07-01") & (z["day"] <= "2025-06-30")]
    te = z[(z["day"] >= "2025-07-01") & (z["day"] <= "2026-06-30")]
    tr_days = list(tr.groupby("day"))
    te_days = list(te.groupby("day"))
    act_tr = tr["price"].values

    def resid(params):
        return simulate(params, tr_days) - act_tr

    r = least_squares(resid, (3.0, 1.4, 1.2, 4.0, 0.7),
                      bounds=([0, 0.8, 0, 0.5, 0.05], [50, 3.0, 10, 12, 1.0]))
    pred = simulate(r.x, te_days)
    act = te["price"].values
    mae = np.mean(np.abs(pred - act))
    corr = np.corrcoef(pred, act)[0, 1]
    # static-form comparison fit in PRICE space with the same loss (so alpha
    # is the only difference)
    r0 = least_squares(lambda q: simulate((*q, 1.0), tr_days) - act_tr,
                       (3.0, 1.4, 1.2, 4.0),
                       bounds=([0, 0.8, 0, 0.5], [50, 3.0, 10, 12]))
    pred0 = simulate((*r0.x, 1.0), te_days)
    mae0 = np.mean(np.abs(pred0 - act))
    rows.append(dict(zone=zone, alpha=r.x[4], kappa_s=r.x[0], theta=r.x[1],
                     kappa_p=r.x[2], p=r.x[3], test_mae_relax=mae,
                     test_corr_relax=corr, test_mae_static_price_fit=mae0))
    print(rows[-1])

pd.DataFrame(rows).to_csv("results_dynamic_relax.tsv", sep="\t", index=False,
                          float_format="%.3f")
