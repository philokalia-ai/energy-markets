"""Part A, energy-limited assets: shifting water between hours (st-impact).

Portfolio: S MW of the zone's hydro units priced by a water value in the book (strategy water_value_*; reservoir and
pumped-storage generation), cheapest mean water value first (the units that run), whole units, the last one scaled.
Carved from the book (K_t(p) = their orders priced <= p); D_c,t = D0,t + K_t as for thermal.
Daily energy E = what the book dispatches of those units (their offers cleared against D_c). Arms, all with <= E:
  book        the book's own hourly water-value offers
  pricetaker  the competitive schedule: E placed in the highest-FORECAST-price hours (price-taker at p_base,t)
  shift       the strategic schedule: E placed by the energy DP against D_c,t with its own price impact
Cost of water = the mean book water value of the day (one value for the day's water; leftover saved at it).
Pumping is not modelled (generation side only, stated).
Scores: sim (forecast curves), pt_real (schedule fixed, realised prices), imp_real (curve + realised error).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

import market_view as MV
import rdopt as R
import strat as ST

HYDRO_STRAT = ("water_value_gas_anchored", "water_value_reservoir", "water_value_anchored", "water_value_spill")


def select_hydro(tz, p_med, S):
    # reservoir only: pumped storage leaves the plain book as storage families (cannot be carved; book_build.jl:2234)
    u = tz[(tz.type == "supply") & tz.strategy.isin(HYDRO_STRAT) & ~tz.fuel.eq("Hydro Pumped Storage")]
    cap = u.groupby(["owner_tag", "hour"]).quantity.sum().groupby("owner_tag").max()
    wv = u.groupby("owner_tag").price.mean()
    pick, tot = {}, 0.0
    for unit in wv.sort_values(kind="stable").index:
        if tot >= S - 1e-6:
            break
        take = min(1.0, (S - tot) / cap[unit])
        pick[unit] = take
        tot += take * cap[unit]
    return pick, tot, float(cap.sum())


def run_zone_day(day, zone, tg, base_prices, real_prices, sizes=ST.SIZES):
    rd = ST.load_rd(day, zone)
    if rd is None:
        return []
    tz = tg[tg.zone == zone]
    pb = base_prices[base_prices.zone == zone].set_index("hour_utc").price
    pr = real_prices.get(zone, {})
    hours = [h for h in range(24) if h in rd and h in pb.index and h in pr]
    if len(hours) < 24:
        return []
    p_med = float(pb.median())
    rows = []
    for S in sizes:
        pick, tot, hcap = select_hydro(tz, p_med, S)
        if tot < 0.98 * S:
            rows.append(dict(day=day, zone=zone, S=S, arm="infeasible", hydro_cap=hcap))
            continue
        rdc, wv, uT, pT = [], [], [], []
        for h in hours:
            o = tz[(tz.hour == h) & tz.owner_tag.isin(pick.keys()) & (tz.type == "supply")].copy()
            o["quantity"] = o.quantity * o.owner_tag.map(pick)
            pg = ST.price_grid(rd[h], [float(pb[h]), float(pr[h]), *np.unique(o.price.values)])
            D0 = R.ResidualDemand.from_injection_curve([a for a, _ in rd[h]], [b for _, b in rd[h]], pg)
            K = ST.offer_on_grid(o.price.values, o.quantity.values, pg)
            c = D0.plus_supply(K)
            p, q = R.clear_offer(c, K)  # truthful = the book's water-value offers
            rdc.append(c)
            uT.append(q)
            pT.append(p)
            wv.append(float((o.price * o.quantity).sum() / max(o.quantity.sum(), 1e-9)))
        uT = np.array(uT)
        E = float(uT.sum())
        wbar = float(np.mean(wv))
        cap_h = float(tot)
        de = cap_h / 8.0
        E = round(E / de) * de
        if E <= 0:
            rows.append(dict(day=day, zone=zone, S=S, arm="no_energy", hydro_cap=hcap))
            continue
        pbase = np.array([float(pb[h]) for h in hours])
        us, _, _ = R.energy_dp(rdc, E, E, cap_h, 0.0, 1.0, wbar, de=de)
        upt, _, _ = R.energy_dp(rdc, E, E, cap_h, 0.0, 1.0, wbar, de=de, impact=False, pt_prices=pbase)
        e_real = np.array([pr[h] - pb[h] for h in hours])
        p_real = np.array([pr[h] for h in hours])
        for arm, u in (("book", uT), ("pricetaker", upt), ("shift", us)):
            left = E - float(np.sum(u))
            psim = np.array([c.P(x) for c, x in zip(rdc, u)])
            rows.append(dict(day=day, zone=zone, S=S, arm=arm, energy_mwh=float(np.sum(u)), budget_mwh=E,
                             leftover_value=left * wbar,
                             sim_profit=float((psim * u).sum() - wbar * np.sum(u)) ,
                             pt_profit=float((p_real * u).sum() - wbar * np.sum(u)),
                             imp_profit=float(((psim + e_real) * u).sum() - wbar * np.sum(u)),
                             mean_price_w=float((psim * u).sum() / max(np.sum(u), 1e-9)),
                             peak_mw=float(np.max(u)), price_spread=float(psim.max() - psim.min()),
                             base_spread=float(pb.max() - pb.min()), water_value=wbar, hydro_cap=hcap))
    return rows
