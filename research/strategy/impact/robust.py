"""Robust price-quantity curves for storage and reservoir hydro (st-impact, owner addendum 22:35Z).

Question: with legs priced at opportunity cost, which curve SHAPE survives our forecast error? (st-blocks owns the
format choice; their point-forecast dual-priced legs lose ~180 €/MW-day vs an unpriced schedule.)

Assets (per MW, price-taker; DESIGN.md §2): battery 1 MW / 2 MWh, round-trip η 0.88 (√η per leg, as st-blocks);
reservoir 1 MW, daily energy 12 MWh, water value = mean forecast price of the day (st-blocks run_impact.jl rule).
Arms (bids built from information before the gate only):
  unpriced     the forecast-optimal schedule (LP on our forecast F), legs at the price limits (always accepted)
  point        the same planned legs priced at opportunity cost from the forecast LP: discharge μ_t/√η, charge μ_t·√η,
               μ_t = value of stored energy at t (dual of the SoC balance) — st-blocks' hourly_oc; hydro: Pmax every
               hour at the water value
  robust       a stepped curve per hour from a scenario LP: scenarios = F + each calibration day's error PATH of the zone
               (12 whole-day paths, intraday correlation kept) + F itself, equal weights; per scenario the SoC (energy
               budget) is feasible; per hour the net volume is non-decreasing in the scenario price (one bid curve
               serves all scenarios). Every step = the volume our optimisation dispatches if that price clears,
               i.e. the expected opportunity cost under the calibration error distribution. Price-taker (no impact).
Score: realised SDAC prices, st-blocks settlement (src/strategy/pricetaker.jl settle): delivery in time order from
SoC 0, undeliverable volume re-traded at the realised price + pen (0 and 10 €/MWh), battery end energy valued at the
mean realised price × √η; hydro keeps the best-priced sold periods up to the budget, cost = water value per MWh.
usage: python -I robust.py -> runs/st-impact/strat/robust.csv
"""
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import linprog
from scipy.sparse import lil_matrix

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import strat as ST  # noqa: E402

ETA = 0.88
RE = np.sqrt(ETA)
BAT_E = 2.0          # MWh per MW
HYD_E = 12.0         # MWh per MW per day (DESIGN.md: 300 MW, 3.6 GWh)
PEN = (0.0, 10.0)
BAT_ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]
HYD_ZONES = ["NO2", "FR", "ES", "IT-SOUTH"]
CAL = (MV.ROOT / "days_cal.txt").read_text().split()


def bat_lp(prices, E=BAT_E, P=1.0):
    """Scenario LP for the battery. prices: K x T. Returns (u K x T net injection, mu T for K=1)."""
    K, T = prices.shape
    nv = 3 * K * T                     # d, c, soc per (s, t)
    D = lambda s, t: (s * T + t) * 3   # noqa: E731
    cost = np.zeros(nv)
    for s in range(K):
        for t in range(T):
            cost[D(s, t)] = -prices[s, t] / K
            cost[D(s, t) + 1] = prices[s, t] / K
    Aeq = lil_matrix((K * T, nv))
    for s in range(K):
        for t in range(T):
            r = s * T + t
            Aeq[r, D(s, t) + 2] = 1.0
            if t > 0:
                Aeq[r, D(s, t - 1) + 2] = -1.0
            Aeq[r, D(s, t) + 1] = -RE
            Aeq[r, D(s, t)] = 1.0 / RE
    rows = []
    for t in range(T):
        order = np.argsort(prices[:, t], kind="stable")
        for a, b in zip(order[:-1], order[1:]):
            rows.append((a, b, t, prices[a, t] == prices[b, t]))
    Aub = lil_matrix((sum(2 if eq else 1 for *_, eq in rows), nv))
    k = 0
    for a, b, t, eq in rows:           # u_a <= u_b  (u = d - c)
        for sgn in ((1.0,) if not eq else (1.0, -1.0)):
            Aub[k, D(a, t)] = sgn; Aub[k, D(a, t) + 1] = -sgn
            Aub[k, D(b, t)] = -sgn; Aub[k, D(b, t) + 1] = sgn
            k += 1
    bounds = [(0, P), (0, P), (0, E)] * (K * T)
    for s in range(K):                 # plan to end the day empty (st-blocks storage_lp: SoC 0 at both ends)
        bounds[D(s, T - 1) + 2] = (0, 0)
    res = linprog(cost, A_ub=Aub.tocsr() if k else None, b_ub=np.zeros(k) if k else None,
                  A_eq=Aeq.tocsr(), b_eq=np.zeros(K * T), bounds=bounds, method="highs")
    assert res.status == 0, res.message
    x = res.x.reshape(K, T, 3)
    u = x[:, :, 0] - x[:, :, 1]
    mu = -res.eqlin.marginals[:T] * K if K == 1 else None
    return u, mu


def hyd_lp(prices, wv, E=HYD_E, P=1.0):
    """Scenario LP for the reservoir: max Σ π d + wv (E − Σ d), Σ d <= E per scenario, d monotone in price per hour."""
    K, T = prices.shape
    cost = -(prices - wv).ravel() / K
    Aub = lil_matrix((K + K * (T * (K - 1)) * 2, K * T))
    b = []
    r = 0
    for s in range(K):
        for t in range(T):
            Aub[r, s * T + t] = 1.0
        b.append(E); r += 1
    for t in range(T):
        order = np.argsort(prices[:, t], kind="stable")
        for a, c in zip(order[:-1], order[1:]):
            Aub[r, a * T + t] = 1.0; Aub[r, c * T + t] = -1.0; b.append(0.0); r += 1
            if prices[a, t] == prices[c, t]:
                Aub[r, a * T + t] = -1.0; Aub[r, c * T + t] = 1.0; b.append(0.0); r += 1
    res = linprog(cost, A_ub=Aub[:r].tocsr(), b_ub=np.array(b), bounds=[(0, P)] * (K * T), method="highs")
    assert res.status == 0, res.message
    return res.x.reshape(K, T)


def step_curve(scen_p, scen_u, P):
    """Volume of the stepped curve at price P: the volume of the highest scenario price <= P (lowest one below)."""
    o = np.argsort(scen_p, kind="stable")
    sp, su = scen_p[o], scen_u[o]
    i = np.searchsorted(sp, P, side="right") - 1
    return float(su[max(i, 0)])


def settle_bat(x, P, pen, E=BAT_E, Pmax=1.0):
    soc = 0.0
    phys = np.zeros_like(x)
    for t in range(len(x)):
        if x[t] > 0:
            d = min(x[t], Pmax, soc * RE); soc -= d / RE; phys[t] = d
        elif x[t] < 0:
            c = min(-x[t], Pmax, (E - soc) / RE); soc += c * RE; phys[t] = -c
    dev = phys - x
    return float(P @ x + P @ dev - pen * np.abs(dev).sum() + soc * P.mean() * RE), float(np.abs(dev).sum())


def settle_hyd(x, P, wv, pen, E=HYD_E):
    phys = x.copy(); left = E
    for t in np.argsort(-P, kind="stable"):
        d = min(phys[t], max(left, 0.0)); phys[t] = d; left -= d
    dev = phys - x
    return float(P @ x + P @ dev - pen * np.abs(dev).sum() - wv * phys.sum()), float(np.abs(dev).sum())


def job(args):
    day, zone, kind, real, loo = args
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    pb = pb[pb.zone == zone].set_index("hour_utc").price
    F = np.array([float(pb[h]) for h in range(24)])
    r = real.get((zone, day), {})
    if len(r) < 24:
        return []
    Pr = np.array([float(r[h]) for h in range(24)])
    paths = []
    for d in CAL:                      # calibration days strictly before D (as-of; for a calibration day: earlier ones only)
        if d >= day:
            continue
        f = MV.BASE / f"{d}.prices.csv"
        p2 = pd.read_csv(f); p2 = p2[p2.zone == zone].set_index("hour_utc").price
        rr = real.get((zone, d), {})
        if len(rr) == 24:
            paths.append(np.array([rr[h] - p2[h] for h in range(24)]))
    scen = np.vstack([F] + [F + e for e in paths])
    rows = []
    if kind == "bat":
        u1, mu = bat_lp(F[None, :])
        u1 = u1[0]
        x_unp = u1.copy()
        x_pt = np.array([(u1[t] if (u1[t] > 0 and Pr[t] >= mu[t] / RE) or (u1[t] < 0 and Pr[t] <= mu[t] * RE) else 0.0)
                         for t in range(24)])
        U, _ = bat_lp(scen)
        x_rb = np.array([step_curve(scen[:, t], U[:, t], Pr[t]) for t in range(24)])
        for arm, x in (("unpriced", x_unp), ("point", x_pt), ("robust", x_rb)):
            for pen in PEN:
                pr, dev = settle_bat(x, Pr, pen)
                rows.append(dict(day=day, zone=zone, asset="battery", arm=arm, pen=pen, profit=pr, dev_mwh=dev,
                                 sold_mwh=float(np.abs(x).sum()), n_paths=len(paths)))
    else:
        wv = float(F.mean())
        d1 = hyd_lp(F[None, :], wv)[0]
        x_unp = d1.copy()
        x_pt = (Pr >= wv).astype(float)                      # Pmax every hour at the water value
        D = hyd_lp(scen, wv)
        x_rb = np.array([step_curve(scen[:, t], D[:, t], Pr[t]) for t in range(24)])
        for arm, x in (("unpriced", x_unp), ("point", x_pt), ("robust", x_rb)):
            for pen in PEN:
                pr, dev = settle_hyd(x, Pr, wv, pen)
                rows.append(dict(day=day, zone=zone, asset="hydro", arm=arm, pen=pen, profit=pr, dev_mwh=dev,
                                 sold_mwh=float(np.abs(x).sum()), n_paths=len(paths)))
    return rows


if __name__ == "__main__":
    real = ST.realised_table()
    EV = (MV.ROOT / "days_eval.txt").read_text().split()
    jobs = [(d, z, "bat", real, False) for d in EV for z in BAT_ZONES] + \
           [(d, z, "hyd", real, False) for d in EV for z in HYD_ZONES] + \
           [(d, z, "bat", real, True) for d in CAL for z in BAT_ZONES] + \
           [(d, z, "hyd", real, True) for d in CAL for z in HYD_ZONES]
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(job, jobs) for r in rs]
    pd.DataFrame(rows).to_csv(MV.ROOT / "runs/st-impact/strat/robust.csv", index=False)
    print(len(rows))
