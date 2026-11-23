"""Part B driver. usage: python -I mv_run.py  (all days with RD curves + baselines)
Step 1 per (day, zone, hour): marginal technology at our price, m_book (flat markup equivalent to the book's ladder at
our price), m_real (flat markup the realised price implies; coupled via the RD curve; islanded variant too), and the
largest fossil firm's Cournot best-response price against the RD curve (Part A machinery, the firm's own units).
Step 2 (calibration days only): models
  M1  m-table: median m_real by zone x band x marginal tech (>= 5 uncensored obs, else zone x band, else none)
  M2  strategic: p = p_base + theta_z (P_cournot(largest firm) - p_base), theta_z in [0, 1] by MAE on cal days
Step 3 (evaluation days): share of the forecast miss explained = 1 - MAE(model)/MAE(base), day-block bootstrap 90%.
Writes runs/st-impact/mv/hours.csv and tables/mv_*.csv."""
import sys
from multiprocessing import Pool
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402
import strat as ST  # noqa: E402

RUN = MV.ROOT / "runs/st-impact"
OUT = RUN / "mv"
TAB = RUN / "tables"
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "ES", "NO2"]
CAL = set((MV.ROOT / "days_cal.txt").read_text().split())
MGRID = [-0.5, -0.3, -0.2, -0.1, -0.05, 0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0]


def firm_cournot(zh, rd_h, units, p_base):
    """Cournot best-response price of a firm owning `units` (all MW, at their SRMC) against the RD curve."""
    o, lad = ST.company_hour(zh, {u: 1.0 for u in units})
    lad = lad[lad.gmc.notna()]
    if lad.mw.sum() < 1:
        return np.nan, 0.0
    cost = R.StepCost(lad.mw.values, lad.gmc.values)
    pg = ST.price_grid(rd_h, [p_base, *lad.gmc.values])
    D0 = R.ResidualDemand.from_injection_curve([a for a, _ in rd_h], [b for _, b in rd_h], pg)
    rdc = D0.plus_supply(ST.offer_on_grid(o.price.values, o.quantity.values, pg))
    q, p, _ = R.cournot(rdc, cost)
    return p, float(cost.S)


def day_zone(args):
    day, zone, fuel, firms, real = args
    rd = ST.load_rd(day, zone)
    if rd is None or not (MV.BASE / f"{day}.tagged.csv.gz").exists():
        return []
    tg = MV.load_tagged(day, [zone], fuel)
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    pb = pb[pb.zone == zone].set_index("hour_utc").price
    zf = firms[firms.zone == zone]
    fossil = tg[(tg.type == "supply") & tg.tech.isin(ST.FOSSIL)]
    capu = fossil.groupby(["owner_tag", "hour"]).quantity.sum().groupby("owner_tag").max()
    fc = zf[zf.unit_code.isin(capu.index)].assign(cap=lambda d: d.unit_code.map(capu)).groupby("firm").cap.sum()
    top = fc.sort_values(ascending=False)
    top_firm = top.index[0] if len(top) else None
    top_units = list(zf[zf.firm == top_firm].unit_code) if top_firm else []
    hhi = float(((top / capu.sum()) ** 2).sum() * 1e4) if len(top) and capu.sum() > 0 else np.nan
    rows = []
    rr = real.get((zone, day), {})
    for h in range(24):
        if h not in rd or h not in pb.index or h not in rr:
            continue
        zh = tg[tg.hour == h]
        p_b, p_r = float(pb[h]), float(rr[h])
        D0c = MV.D0_from_rd(rd[h])
        D0i = MV.D0_islanded(zh, p_b)
        mb, fb, mw = MV.implied_markup(zh, D0c, p_b)
        mr, fr, _ = MV.implied_markup(zh, D0c, p_r)
        mi, fi, _ = MV.implied_markup(zh, D0i, p_r)
        pc, fcap = firm_cournot(zh, rd[h], top_units, p_b) if top_units else (np.nan, 0.0)
        rdp = [b for _, b in rd[h]]
        pm = {f"p_m{m:+.2f}": MV.price_with_markup(zh, D0c, m, p_b, lo=min(rdp) - 50, hi=max(rdp) + 50)
              for m in MGRID}
        rows.append(dict(**pm, day=day, zone=zone, hour=h, band=ST.BAND_OF[h], p_base=p_b, p_real=p_r,
                         tech=MV.marginal_tech(zh, p_b), m_book=mb, f_book=fb, m_real=mr, f_real=fr, m_real_isl=mi,
                         f_real_isl=fi, flex_mw=mw, top_firm=top_firm, top_firm_mw=fcap, hhi_fossil=hhi,
                         p_cournot_top=pc))
    return rows


def fit_and_score(H):
    cal, ev = H[H.day.isin(CAL)], H[~H.day.isin(CAL)]
    ok = cal[(cal.f_real == "") & cal.m_real.notna()]
    t3 = ok.groupby(["zone", "band", "tech"]).m_real.agg(["median", "size"])
    t2 = ok.groupby(["zone", "band"]).m_real.agg(["median", "size"])

    def mhat(r):
        k3 = (r.zone, r.band, r.tech)
        if k3 in t3.index and t3.loc[k3, "size"] >= 5:
            return t3.loc[k3, "median"]
        k2 = (r.zone, r.band)
        if k2 in t2.index and t2.loc[k2, "size"] >= 5:
            return t2.loc[k2, "median"]
        return np.nan

    theta = {}
    for z, g in cal.groupby("zone"):
        g = g[g.p_cournot_top.notna()]
        if g.empty:
            theta[z] = 0.0
            continue
        grid = np.linspace(0, 1, 21)
        mae = [np.abs(g.p_base + t * (g.p_cournot_top - g.p_base) - g.p_real).mean() for t in grid]
        theta[z] = float(grid[int(np.argmin(mae))])
    return t3, t2, mhat, theta


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    TAB.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(Path.home() / "armada/em-data/euphemia-live-20261115.duckdb"), read_only=True)
    fuel = MV.registry_fuel(con)
    firms = con.sql("select zone, unit_code, firm from simulations.unit_firms").df()
    con.close()
    real = ST.realised_table()
    days = sorted({f.name[:10] for f in (RUN / "rd").glob("*.csv")})
    jobs = [(d, z, fuel, firms, real) for d in days for z in ZONES]
    with Pool(6) as p:
        H = pd.DataFrame([r for rows in p.imap_unordered(day_zone, jobs) for r in rows])
    H["f_real"] = H.f_real.fillna("")
    H.to_csv(OUT / "hours.csv", index=False)
    print(f"hours {len(H)}; days cal={H[H.day.isin(CAL)].day.nunique()} eval={H[~H.day.isin(CAL)].day.nunique()}")
