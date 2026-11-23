"""Part A: strategic bidding of a thermal portfolio of size S in zone Z against our forecast (st-impact).

Portfolio (decided 2026-11-23, STATUS): the S MW of the zone's own FOSSIL units (gas, coal, lignite, oil) whose SRMC
is nearest the day's median baseline price ("mid-merit"), whole units, the last one partially (scaled). The company
owns those units' book orders (must-run + tranches) in every hour; they are carved from the baseline (K_t(p)), and
the company re-bids the same MW. Cost = the unit's SRMC (gmc = srmc_base price / 0.95, see market_view.py) on all its
MW; no start-up/min-load (the slice is treated as hourly divisible — stated in the report).

Arms (all as monotone offer curves x_t(p) per hour, cleared against the company residual demand D_c,t = D0,t + K_t):
  book      the book's own orders (reproduces the baseline price by construction)
  truthful  every MW at SRMC
  markup    flat markup m over SRMC, m chosen per (zone, size) on CALIBRATION days (not per hour; robust arm)
  cournot   forecast-optimal step offer per hour (DP, one scenario) == Cournot withholding against the forecast
  hedged    expected-profit-optimal step offer over the forecast curve shifted by calibration-day errors of the
            zone x hour band (eval days only: as-of = calibration days < D)
Scores per arm and hour:
  sim       cleared against the forecast curve: price, volume, profit
  pt_real   price-taker at the realised price: volume x_t(p_real) (the harness rule: in the money), profit
  imp_real  cleared against the forecast curve shifted to pass through the realised price at q = 0 (realised price +
            the company's own simulated impact)
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402

FOSSIL = {"gas", "coal", "lignite", "oil"}
SIZES = [100, 250, 500, 1000, 2000, 4000]
RD_DIR = MV.ROOT / "runs/st-impact/rd"
# hour bands (UTC; CET = UTC+1 in winter, +2 in summer)
BANDS = {"night": range(0, 6), "morning": range(6, 10), "solar": range(10, 16), "evening": range(16, 21),
         "late": range(21, 24)}
BAND_OF = {h: b for b, hs in BANDS.items() for h in hs}


def load_rd(day, zone):
    f = RD_DIR / f"{day}_{zone}.csv"
    if not f.exists():
        return None
    d = pd.read_csv(f)
    return {h: list(zip(g.q.values, g.price.values)) for h, g in d.groupby("hour_utc")}


def select_portfolio(tg_zone: pd.DataFrame, p_med: float, S: float):
    """Units (fossil, with an SRMC) nearest p_med; returns {unit: scale} and total MW (max hourly capacity)."""
    u = tg_zone[(tg_zone.type == "supply") & tg_zone.tech.isin(FOSSIL) & tg_zone.gmc.notna()]
    cap = u.groupby(["owner_tag", "hour"]).quantity.sum().groupby("owner_tag").max()
    g = u.groupby("owner_tag").gmc.mean()
    order = (g - p_med).abs().sort_values(kind="stable").index
    pick, tot = {}, 0.0
    for unit in order:
        if tot >= S - 1e-6:
            break
        c = cap[unit]
        take = min(1.0, (S - tot) / c)
        pick[unit] = take
        tot += take * c
    return pick, tot, float(cap.sum())


def company_hour(tg_zh: pd.DataFrame, pick: dict):
    """Company's book orders in one hour (scaled) and its SRMC ladder (unit, MW, gmc)."""
    o = tg_zh[tg_zh.owner_tag.isin(pick.keys()) & (tg_zh.type == "supply")].copy()
    o["quantity"] = o.quantity * o.owner_tag.map(pick)
    lad = o.groupby("owner_tag").agg(mw=("quantity", "sum"), gmc=("gmc", "first"))
    return o, lad


def price_grid(rd_pts, extra):
    pr = np.array([p for _, p in rd_pts], float)
    lo = min(pr.min(), min(extra)) - 5.0
    hi = max(pr.max(), max(extra)) + 5.0
    g = np.unique(np.round(np.concatenate([np.linspace(lo, hi, 300),
                                           np.linspace(min(extra) - 40, max(extra) + 60, 300)]), 3))
    return g[(g >= lo) & (g <= hi)]


def offer_on_grid(orders_price, orders_mw, pgrid):
    return (np.asarray(orders_mw)[None, :] * (np.asarray(orders_price)[None, :] <= pgrid[:, None])).sum(1)


def x_at(x_grid, pgrid, p):
    """Offer curve value at price p (step: the last grid point <= p)."""
    i = np.searchsorted(pgrid, p, side="right") - 1
    return float(x_grid[i]) if i >= 0 else 0.0


def score(rd_c, x, cost, e_real, p_real):
    """(sim profit, sim price, sim q, pt_real profit, pt q, imp_real profit, imp price, imp q)."""
    ps, p, q = R.offer_profit(rd_c, x, cost)
    qpt = min(x_at(x, rd_c.p, p_real), cost.S)
    pt = p_real * qpt - float(cost.C(qpt))
    pi_, pr_, qr_ = R.offer_profit(rd_c.shifted_price(e_real), x, cost)
    return ps, p, q, pt, qpt, pi_, pr_, qr_


MARKUPS = [0.0, 0.05, 0.10, 0.20, 0.30, 0.50, 0.75, 1.00, 1.50, 2.00]
N_Q = 81


def hedge_scenarios(rd_c, errs, n=21):
    """Forecast curve shifted by the calibration-error quantiles (equal weights)."""
    qs = np.quantile(np.asarray(errs, float), (np.arange(n) + 0.5) / n)
    return [rd_c.shifted_price(e) for e in qs], np.full(n, 1.0 / n)


def run_zone_day(day, zone, tg, base_prices, real_prices, errors=None, sizes=SIZES, keep=None, only_arms=None):
    """All arms x sizes x hours for one (day, zone). errors: {(zone, band): array} from calibration days < day, or
    None (no hedged arm). Returns a list of row dicts."""
    rd = load_rd(day, zone)
    if rd is None:
        return []
    tz = tg[tg.zone == zone]
    pb = base_prices[base_prices.zone == zone].set_index("hour_utc").price
    pr = real_prices.get(zone, {})
    p_med = float(pb.median())
    rows = []
    for S in sizes:
        pick, tot, fossil_cap = select_portfolio(tz, p_med, S)
        if tot < 0.98 * S:
            rows.append(dict(day=day, zone=zone, S=S, hour=-1, arm="infeasible", fossil_cap=fossil_cap))
            continue
        for h in range(24):
            if h not in rd or h not in pb.index or h not in pr:
                continue
            zh = tz[tz.hour == h]
            o, lad = company_hour(zh, pick)
            if lad.mw.sum() < 1.0:
                continue
            cost = R.StepCost(lad.mw.values, lad.gmc.values)
            p_base, p_real = float(pb[h]), float(pr[h])
            pg = price_grid(rd[h], [p_base, p_real, *lad.gmc.values])
            D0 = R.ResidualDemand.from_injection_curve([a for a, _ in rd[h]], [b for _, b in rd[h]], pg)
            K = offer_on_grid(o.price.values, o.quantity.values, pg)
            rdc = D0.plus_supply(K)
            e_real = p_real - p_base
            arms = {"book": K, "truthful": cost.truthful_offer(pg)}
            for m in MARKUPS[1:]:
                arms[f"markup_{m:.2f}"] = R.markup_offer(pg, cost, m)
            x_c, _ = R.optimal_offer([rdc], [1.0], cost, n_q=N_Q)
            arms["cournot"] = x_c
            if errors is not None and (zone, BAND_OF[h]) in errors:
                sc, w = hedge_scenarios(rdc, errors[(zone, BAND_OF[h])])
                x_h, _ = R.optimal_offer(sc, w, cost, n_q=N_Q)
                arms["hedged"] = x_h
            if keep is not None:
                keep[(S, h, "carve")] = o[["price", "quantity"]].values.copy()
                for a, x in arms.items():
                    if only_arms is None or a in only_arms:
                        keep[(S, h, a)] = (pg, x)
            for a, x in arms.items():
                ps, p, q, pt, qpt, pi_, pr_, qr_ = score(rdc, x, cost, e_real, p_real)
                rows.append(dict(day=day, zone=zone, S=S, hour=h, arm=a, p_base=p_base, p_real=p_real,
                                 cap=cost.S, sim_profit=ps, sim_price=p, sim_q=q, pt_profit=pt, pt_q=qpt,
                                 imp_profit=pi_, imp_price=pr_, imp_q=qr_, fossil_cap=fossil_cap,
                                 slope_per100=float(D0.P(100.0) - D0.P(-100.0)) / 2.0,
                                 slope500_per100=float(D0.P(500.0) - D0.P(-500.0)) / 10.0))
    return rows


def calib_errors(days, zones, real_df):
    """{(zone, band): realised - forecast} over the given (calibration) days with cached baselines."""
    out = {}
    for d in days:
        f = MV.BASE / f"{d}.prices.csv"
        if not f.exists():
            continue
        pb = pd.read_csv(f)
        for z in zones:
            for h in range(24):
                b = pb[(pb.zone == z) & (pb.hour_utc == h)].price
                r = real_df.get((z, d), {}).get(h)
                if b.empty or r is None:
                    continue
                out.setdefault((z, BAND_OF[h]), []).append(r - float(b.iloc[0]))
    return {k: np.array(v) for k, v in out.items()}


def realised_table(path=MV.ROOT / "data/sdac/realised_hourly.csv"):
    r = pd.read_csv(path, parse_dates=["t_utc"])
    r["day"] = r.t_utc.dt.strftime("%Y-%m-%d")
    r["hour"] = r.t_utc.dt.hour
    return {(z, d): dict(zip(g.hour, g.price)) for (z, d), g in r.groupby(["zone", "day"])}
