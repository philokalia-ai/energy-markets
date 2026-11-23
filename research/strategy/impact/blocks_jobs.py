"""Strategic blocks (st-impact, task 2): does shifting the strategic offer into block orders pay?
usage: python -I blocks_jobs.py day zone S  -> prints job names; writes runs/st-impact/rc/<day>_<zone>_<S>_blk_<arm>.csv
and <...>.meta.json (per-hour cost ladder, prices, family members) for blocks_score.py.

Arms (all with the Part A portfolio of size S carved from the book, eval days):
  a  truthful hourly            every MW at SRMC (SimpleOrders, exact unit ladder)
  b  cournot hourly             the forecast-optimal step offer (Part A DP), SimpleOrders
  c  linked at cost (BLKL)      parent = Pmin_t over the window W at the cost of the cheapest Pmin MW; children = the rest
                                of the ladder, one child per (hour, unit) at SRMC; outside W the ladder bids hourly
  d  linked + cournot children  same parent; children = the Cournot offer above Pmin_t, one child per (hour, price step);
                                outside W the Cournot offer bids hourly
  e  exclusive group (BLKX)     3 members, each a 24 h schedule priced at its own cost per hour: the Cournot dispatch,
                                the hedged dispatch, and the midpoint of Cournot and truthful dispatch (all on our curve)
Pmin_t = sum over the portfolio's units of FuelTypeParameters.min_load_factor x unit MW (gas 0.35, hard coal 0.45,
lignite 0.45, coal-derived gas 0.40, oil 0.30). W = the contiguous window (>= 4 h, gas min_uptime) maximising the
forecast value of running Pmin plus the in-the-money rest. No start-up cost (portfolio slice; st-blocks covers it).
"""
import json
import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402
import strat as ST  # noqa: E402

RC = MV.ROOT / "runs/st-impact/rc"
MIN_LOAD = {"Fossil Gas": 0.35, "Fossil Hard coal": 0.45, "Fossil Brown coal/Lignite": 0.45,
            "Fossil Coal-derived gas": 0.40, "Fossil Oil": 0.30}  # src/FuelTypeParameters.jl:59,77,95,131,149
TECH_ML = {"gas": 0.35, "coal": 0.45, "lignite": 0.45, "oil": 0.30}
MIN_UP = 4  # gas min_uptime (FuelTypeParameters.jl, Fossil Gas)


def above(lad, pm):
    """The ladder's MW above the first pm MW (merit order): [(gmc, MW above), ...] per unit."""
    out, cum = [], 0.0
    for g, m in zip(lad.gmc, lad.mw):
        out.append((g, max(0.0, min(m, cum + m - pm))))
        cum += m
    return out


def best_window(val, Lmin):
    T = len(val)
    best = (0, T, -np.inf)
    for s in range(T):
        for L in range(Lmin, T - s + 1):
            v = float(np.sum(val[s:s + L]))
            if v > best[2]:
                best = (s, L, v)
    return best


def main(day, zone, S):
    con = duckdb.connect(str(Path.home() / "armada/em-data/euphemia-live-20261115.duckdb"), read_only=True)
    fuel = MV.registry_fuel(con)
    con.close()
    real = ST.realised_table()
    CAL = (MV.ROOT / "days_cal.txt").read_text().split()
    errs = ST.calib_errors(CAL, [zone], real)
    tg = MV.load_tagged(day, [zone], fuel)
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    keep = {}
    rows = pd.DataFrame(ST.run_zone_day(day, zone, tg, pb, {zone: real[(zone, day)]}, errors=errs, sizes=[S],
                                        keep=keep, only_arms={"truthful", "cournot", "hedged"}))
    tz = tg[tg.zone == zone]
    pbz = pb[pb.zone == zone].set_index("hour_utc").price
    pick, tot, _ = ST.select_portfolio(tz, float(pbz.median()), S)
    hours = sorted(h for h in range(24) if (S, h, "cournot") in keep)
    ladders, pmin, cpmin, F = {}, {}, {}, {}
    for h in hours:
        o, lad = ST.company_hour(tz[tz.hour == h], pick)
        tech = o.groupby("owner_tag").tech.first()
        lad = lad.assign(ml=[TECH_ML.get(tech[u], 0.35) for u in lad.index]).sort_values("gmc")
        ladders[h] = lad
        pmin[h] = float((lad.ml * lad.mw).sum())
        cost = R.StepCost(lad.mw.values, lad.gmc.values)
        cpmin[h] = float(cost.C(pmin[h])) / max(pmin[h], 1e-9)
        F[h] = float(pbz[h])
    val = np.array([(F[h] - cpmin[h]) * pmin[h] + sum(max(0.0, F[h] - g) * r for g, r in above(ladders[h], pmin[h]))
                    for h in hours])
    s0, L, _ = best_window(val, MIN_UP)
    W = set(hours[s0:s0 + L])
    sim = rows.set_index(["hour", "arm"]).sim_q
    pre = f"{zone}:IMP{S}"
    out = {a: [] for a in "abcde"}

    def add(a, h, kind, p, mw, fam=""):
        if mw > 1e-6:
            out[a].append((day, zone, h, kind, round(float(p), 4), float(mw), fam))

    for h in hours:
        lad = ladders[h]
        pg, xc = keep[(S, h, "cournot")]
        xc = np.maximum.accumulate(xc)
        inc = np.diff(np.concatenate([[0.0], xc]))
        steps = [(p, d) for p, d in zip(pg, inc) if d > 1e-6]
        for g, m in zip(lad.gmc, lad.mw):
            add("a", h, "offer", g, m)
        for p, d in steps:
            add("b", h, "offer", p, d)
        if h in W:
            for a in "cd":
                add(a, h, "lho", cpmin[h], pmin[h], f"BLKL:{pre}-p")
            for k, (g, rest) in enumerate(above(lad, pmin[h])):
                add("c", h, "lho", g, rest, f"BLKL:{pre}-c{h}u{k}:parent=IMP{S}-p")
            cum = 0.0
            agg = {}
            for p, d in steps:
                rest = max(0.0, min(d, cum + d - pmin[h]))
                cum += d
                if rest > 1e-6:
                    agg[round(p * 2) / 2] = agg.get(round(p * 2) / 2, 0.0) + rest
            for k, (p, d) in enumerate(sorted(agg.items())):
                add("d", h, "lho", p, d, f"BLKL:{pre}-d{h}s{k}:parent=IMP{S}-p")
        else:
            for g, m in zip(lad.gmc, lad.mw):
                add("c", h, "offer", g, m)
            for p, d in steps:
                add("d", h, "offer", p, d)
        qs = {"cournot": float(sim.get((h, "cournot"), 0.0)), "hedged": float(sim.get((h, "hedged"), np.nan)),
              "mid": 0.5 * (float(sim.get((h, "cournot"), 0.0)) + float(sim.get((h, "truthful"), 0.0)))}
        cost = R.StepCost(lad.mw.values, lad.gmc.values)
        for k, (nm, q) in enumerate(qs.items()):
            if np.isnan(q) or q <= 1e-6:
                continue
            add("e", h, "lho", float(cost.C(q)) / q, q, f"BLKX:{pre}-x{k}:group=IMP{S}")
    names = []
    meta = dict(day=day, zone=zone, S=S, window=sorted(W), pmin={h: pmin[h] for h in hours},
                p_base={h: F[h] for h in hours}, p_real={h: float(real[(zone, day)][h]) for h in hours},
                ladder={h: list(zip(ladders[h].gmc.round(4), ladders[h].mw.round(4))) for h in hours},
                curve_pred={a: {int(h): [float(rows[(rows.hour == h) & (rows.arm == a)].sim_price.iloc[0]),
                                         float(rows[(rows.hour == h) & (rows.arm == a)].sim_q.iloc[0])] for h in hours}
                            for a in ("truthful", "cournot")})
    for a, nm in zip("abcde", ["truthful", "cournot", "linked_cost", "linked_cournot", "exclusive"]):
        carve = [(day, zone, h, "carve", float(p), float(q), "") for h in hours for p, q in keep[(S, h, "carve")]]
        name = f"{day}_{zone}_{S}_blk_{a}_{nm}"
        pd.DataFrame(out[a] + carve, columns=["day", "zone", "hour", "kind", "price", "mw", "family"]).to_csv(
            RC / f"{name}.csv", index=False)
        (RC / f"{name}.meta.json").write_text(json.dumps(meta))
        names.append(name)
    print(",".join(names))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]))
