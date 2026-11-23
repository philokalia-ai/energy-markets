"""Aggregate Part A outputs (runs/st-impact/strat/*.csv.gz) into the report tables.
usage: python -I aggregate.py  -> prints markdown tables, writes runs/st-impact/tables/*.csv"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402
import strat as ST  # noqa: E402

RUN = MV.ROOT / "runs/st-impact"
TAB = RUN / "tables"
TAB.mkdir(parents=True, exist_ok=True)
CAL = set((MV.ROOT / "days_cal.txt").read_text().split())
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "ES", "NO2"]


def load():
    fs = sorted(f for f in (RUN / "strat").glob("*.csv.gz") if ".hydro." not in f.name)
    df = pd.concat([pd.read_csv(f) for f in fs], ignore_index=True)
    df["set"] = np.where(df.day.isin(CAL), "cal", "eval")
    return df


def ci(v):
    m, lo, hi = R.block_bootstrap_ci(v)
    return m, lo, hi


def fmt(m, lo, hi, k=1e3):
    return f"{m / k:+.1f} [{lo / k:+.1f}, {hi / k:+.1f}]"


def slope_table(df=None, which=None):
    """Residual-demand slope from the uncarved RD curves (portfolio-independent), €/MWh per 100 MW of company sales
    (negative: the price falls as the company sells more): centred ±100 MW and ±500 MW arcs. Per zone x band: the
    median over days of the day's band mean, with the day-to-day p25-p75."""
    rows = []
    for f in sorted(f for f in (RUN / "rd").glob("*.csv") if not f.name.endswith(".plus.csv")):
        day, zone = f.stem[:10], f.stem[11:]
        if which is not None and (day in CAL) != (which == "cal"):
            continue
        d = pd.read_csv(f)
        for h, g in d.groupby("hour_utc"):
            P = dict(zip(g.q, np.minimum.accumulate(g.price.values)))
            rows.append(dict(day=day, zone=zone, band=ST.BAND_OF[h], s100=(P[100.0] - P[-100.0]) / 2.0,
                             s500=(P[500.0] - P[-500.0]) / 10.0, s1000=(P[1000.0] - P[-1000.0]) / 20.0))
    r = pd.DataFrame(rows)
    d = r.groupby(["zone", "band", "day"])[["s100", "s500", "s1000"]].mean().reset_index()
    q = lambda k: (lambda s: s.quantile(k))  # noqa: E731
    t = d.groupby(["zone", "band"]).agg(days=("day", "nunique"),
                                        s100_med=("s100", "median"), s500_med=("s500", "median"),
                                        s500_p25=("s500", q(.25)), s500_p75=("s500", q(.75)),
                                        s1000_med=("s1000", "median"))
    return t.round(2)


def daily(df, arm, col):
    return df[df.arm == arm].groupby("day")[col].sum()


def best_markup_on_cal(df):
    """m* per (zone, S): max mean daily sim profit on calibration days."""
    c = df[(df.set == "cal") & df.arm.str.startswith("markup_")]
    g = c.groupby(["zone", "S", "arm"]).sim_profit.sum().reset_index()
    best = g.loc[g.groupby(["zone", "S"]).sim_profit.idxmax()]
    return {(r.zone, r.S): r.arm for r in best.itertuples()}


def size_table(df, which_set):
    mk = best_markup_on_cal(df)
    out = []
    for (z, S), g in df[df.set == which_set].groupby(["zone", "S"]):
        if (g.arm == "infeasible").all() or not (g.arm != "infeasible").any():
            out.append(dict(zone=z, S=S, note="fossil cap " + f"{g.fossil_cap.iloc[0]:.0f} MW < S"))
            continue
        feas = g.groupby("day").arm.apply(lambda a: (a != "infeasible").any())
        days = sorted(feas[feas].index)
        g = g[g.day.isin(days)]
        row = dict(zone=z, S=S, days=len(days), days_infeasible=int((~feas).sum()))
        T = {c: daily(g, "truthful", c).reindex(days) for c in ["sim_profit", "pt_profit", "imp_profit"]}
        for arm in ["cournot", "hedged", mk.get((z, S), "markup_0.10"), "book"]:
            if arm not in set(g.arm):
                continue
            key = "markup" if arm.startswith("markup_") else arm
            for c, lab in [("sim_profit", "sim"), ("pt_profit", "pt"), ("imp_profit", "imp")]:
                v = (daily(g, arm, c).reindex(days) - T[c]).values
                row[f"{key}_{lab}"] = ci(v)
            if key == "markup":
                row["m_star"] = arm.split("_")[1]
        if "hedged" in set(g.arm):
            for c, lab in [("pt_profit", "pt"), ("imp_profit", "imp"), ("sim_profit", "sim")]:
                v = (daily(g, "hedged", c).reindex(days) - daily(g, "cournot", c).reindex(days)).values
                row[f"hedge_vs_fc_{lab}"] = ci(v)
        t = g[g.arm == "truthful"].set_index(["day", "hour"])
        c = g[g.arm == "cournot"].set_index(["day", "hour"])
        row["truthful_sim_k"] = T["sim_profit"].mean() / 1e3
        row["withheld_mw"] = float((t.sim_q - c.sim_q).mean())
        row["impact_eur"] = float((c.sim_price - t.sim_price).mean())
        row["truth_vs_base_eur"] = float((t.sim_price - t.p_base).mean())
        row["markup_eff"] = float(((c.sim_price - t.sim_price) / t.sim_price.clip(lower=1)).median())
        out.append(row)
    return out


def edge_table(df):
    """Share of zone-hours where an arm's simulated price lies at/beyond a residual-demand grid edge
    (uncarved injection D0(p) within 1 MW of the lowest or highest q on the grid)."""
    d = df[df.arm.isin(["truthful", "cournot", "hedged", "book"]) & df.d0_at_p.notna()]
    # strict edge, and the outermost grid segment ([-4000,-3000] / [+2000,+4000]: two points, linear only)
    d = d.assign(edge_lo=d.d0_at_p <= d.q_lo + 1, edge_hi=d.d0_at_p >= d.q_hi - 1,
                 seg_lo=d.d0_at_p < -3000, seg_hi=d.d0_at_p > 2000, p_ge_1000=d.sim_price >= 1000)
    return d.groupby(["zone", "S", "arm", "set"])[["edge_lo", "edge_hi", "seg_lo", "seg_hi", "p_ge_1000"]].mean().round(3)


def md_hedge(rows):
    lines = ["| zone | S MW | days | hedged − forecast-optimal, sim | pt-real | imp-real |", "|---|---|---|---|---|---|"]
    for r in rows:
        if "hedge_vs_fc_imp" in r:
            lines.append(f"| {r['zone']} | {r['S']} | {r['days']} | {fmt(*r['hedge_vs_fc_sim'])} | "
                         f"{fmt(*r['hedge_vs_fc_pt'])} | {fmt(*r['hedge_vs_fc_imp'])} |")
    return "\n".join(lines)


def structure_table(rows_cal, rows_eval):
    """Per zone: residual-demand slope (±500 MW, all hours, median), fossil HHI and capacity (book, firm map), S*."""
    sl = slope_table().reset_index().groupby("zone").s500_med.median()
    H = pd.read_csv(RUN / "mv/hours.csv") if (RUN / "mv/hours.csv").exists() else None
    out = []
    sc, se = s_star(rows_cal), s_star(rows_eval)
    sci, sei = s_star(rows_cal, "cournot_imp"), s_star(rows_eval, "cournot_imp")
    for z in ZONES:
        out.append(dict(zone=z, slope500=sl.get(z, np.nan),
                        hhi_fossil=H[H.zone == z].hhi_fossil.mean() if H is not None else np.nan,
                        top_firm=(H[H.zone == z].top_firm.mode().iloc[0] if H is not None and H[H.zone == z].top_firm.notna().any() else ""),
                        top_firm_mw=H[H.zone == z].top_firm_mw.median() if H is not None else np.nan,
                        S_star_sim_cal=sc[z], S_star_sim_eval=se[z], S_star_imp_cal=sci[z], S_star_imp_eval=sei[z],
                        S_star1pct_sim_cal=s_star(rows_cal, material=0.01)[z],
                        S_star1pct_sim_eval=s_star(rows_eval, material=0.01)[z],
                        S_star1pct_imp_cal=s_star(rows_cal, "cournot_imp", 0.01)[z],
                        S_star1pct_imp_eval=s_star(rows_eval, "cournot_imp", 0.01)[z]))
    return pd.DataFrame(out)


def s_star(rows, key="cournot_sim", material=0.0):
    """Smallest S whose Δ interval lies above `material` x truthful simulated profit (0 = above zero)."""
    res = {}
    for z in ZONES:
        zs = sorted([r for r in rows if r["zone"] == z and key in r], key=lambda r: r["S"])
        res[z] = next((r["S"] for r in zs if r[key][1] > material * r["truthful_sim_k"] * 1e3), None)
    return res


def md_size(rows):
    hdr = ("| zone | S MW | days | truthful sim k€/d | Δ cournot sim | Δ cournot pt-real | Δ cournot imp-real | "
           "Δ hedged imp-real | Δ markup(m*) imp-real | m* | Δ book sim | withheld MW | impact €/MWh |")
    lines = [hdr, "|" + "---|" * 13]
    for r in rows:
        if "note" in r:
            lines.append(f"| {r['zone']} | {r['S']} | – | {r['note']} |" + " |" * 9)
            continue
        f = lambda k: fmt(*r[k]) if k in r else "–"  # noqa: E731
        lines.append(f"| {r['zone']} | {r['S']} | {r['days']} | {r['truthful_sim_k']:.1f} | {f('cournot_sim')} | "
                     f"{f('cournot_pt')} | {f('cournot_imp')} | {f('hedged_imp')} | {f('markup_imp')} | "
                     f"{r.get('m_star', '–')} | {f('book_sim')} | {r['withheld_mw']:.0f} | {r['impact_eur']:+.1f} |")
    return "\n".join(lines)


def hydro_table():
    fs = sorted((RUN / "strat").glob("*.hydro.csv.gz"))
    if not fs:
        return None
    h = pd.concat([pd.read_csv(f) for f in fs if f.stat().st_size > 30], ignore_index=True)
    h = h[h.arm.isin(["book", "pricetaker", "shift"])]
    h["set"] = np.where(h.day.isin(CAL), "cal", "eval")
    out = []
    for (st, z, S), g in h.groupby(["set", "zone", "S"]):
        p = g.pivot_table(index="day", columns="arm", values=["sim_profit", "pt_profit", "imp_profit", "energy_mwh"])
        if ("sim_profit", "shift") not in p.columns:
            continue
        row = dict(set=st, zone=z, S=S, days=len(p), energy_mwh=p[("energy_mwh", "pricetaker")].mean())
        for c, lab in [("sim_profit", "sim"), ("pt_profit", "pt"), ("imp_profit", "imp")]:
            row[f"shift_vs_pt_{lab}"] = fmt(*ci((p[(c, "shift")] - p[(c, "pricetaker")]).values))
            row[f"shift_vs_book_{lab}"] = fmt(*ci((p[(c, "shift")] - p[(c, "book")]).values))
            row[f"book_vs_pt_{lab}"] = fmt(*ci((p[(c, "book")] - p[(c, "pricetaker")]).values))
        out.append(row)
    return pd.DataFrame(out)


if __name__ == "__main__":
    df = load()
    print(f"rows {len(df)}, days cal={df[df.set == 'cal'].day.nunique()} eval={df[df.set == 'eval'].day.nunique()}")
    st = slope_table()
    st.to_csv(TAB / "slope.csv")
    print(MV.md(st))
    R_ = {}
    for s in ["cal", "eval"]:
        rows = size_table(df, s)
        R_[s] = rows
        pd.DataFrame(rows).to_csv(TAB / f"size_{s}.csv", index=False)
        print(f"\n### {s}\n" + md_size(rows))
        print("S* (sim, CI lo > 0):", s_star(rows), " S* (imp-real):", s_star(rows, "cournot_imp"))
    print("\n### hedge (eval)\n" + md_hedge(R_["eval"]))
    et = edge_table(df)
    et.to_csv(TAB / "grid_edge.csv")
    print("\n### grid edge (share of hours), GR\n" + MV.md(et.loc["GR"]))
    print("\n### grid edge, all zones, S >= 2000, cournot/truthful\n" +
          MV.md(et.reset_index().query("S >= 2000 and arm in ['cournot', 'truthful']").set_index(["zone", "S", "arm", "set"])))
    stt = structure_table(R_["cal"], R_["eval"])
    stt.to_csv(TAB / "structure.csv", index=False)
    print("\n### structure\n" + MV.md(stt, index=False))
    ht = hydro_table()
    if ht is not None:
        ht.to_csv(TAB / "hydro.csv", index=False)
        print("\n### hydro shifting (k€/day, shift/book minus price-taker schedule)\n" + MV.md(ht, index=False))
