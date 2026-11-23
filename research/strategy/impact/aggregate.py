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


def slope_table(df):
    b = df[(df.arm == "book")].drop_duplicates(["day", "zone", "hour"])
    b = b.assign(band=b.hour.map(ST.BAND_OF))
    d = b.groupby(["zone", "band", "day"])[["slope_per100", "slope500_per100"]].mean().reset_index()
    t = d.groupby(["zone", "band"]).agg(
        days=("day", "nunique"),
        s100_med=("slope_per100", "median"), s100_p25=("slope_per100", lambda s: s.quantile(.25)),
        s100_p75=("slope_per100", lambda s: s.quantile(.75)),
        s500_med=("slope500_per100", "median"), s500_p25=("slope500_per100", lambda s: s.quantile(.25)),
        s500_p75=("slope500_per100", lambda s: s.quantile(.75)))
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
        if (g.arm == "infeasible").all():
            out.append(dict(zone=z, S=S, note="fossil cap " + f"{g.fossil_cap.iloc[0]:.0f} MW < S"))
            continue
        days = sorted(g.day.unique())
        row = dict(zone=z, S=S, days=len(days))
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
        t = g[g.arm == "truthful"].set_index(["day", "hour"])
        c = g[g.arm == "cournot"].set_index(["day", "hour"])
        row["truthful_sim_k"] = T["sim_profit"].mean() / 1e3
        row["withheld_mw"] = float((t.sim_q - c.sim_q).mean())
        row["impact_eur"] = float((c.sim_price - t.sim_price).mean())
        row["truth_vs_base_eur"] = float((t.sim_price - t.p_base).mean())
        row["markup_eff"] = float(((c.sim_price - t.sim_price) / t.sim_price.clip(lower=1)).median())
        out.append(row)
    return out


def s_star(rows, key="cournot_sim"):
    res = {}
    for z in ZONES:
        zs = sorted([r for r in rows if r["zone"] == z and key in r], key=lambda r: r["S"])
        res[z] = next((r["S"] for r in zs if r[key][1] > 0), None)
    return res


def md_size(rows):
    hdr = ("| zone | S MW | days | truthful sim k€/d | Δ cournot sim | Δ cournot pt-real | Δ cournot imp-real | "
           "Δ hedged imp-real | Δ markup(m*) imp-real | m* | withheld MW | impact €/MWh |")
    lines = [hdr, "|" + "---|" * 12]
    for r in rows:
        if "note" in r:
            lines.append(f"| {r['zone']} | {r['S']} | – | {r['note']} |" + " |" * 8)
            continue
        f = lambda k: fmt(*r[k]) if k in r else "–"  # noqa: E731
        lines.append(f"| {r['zone']} | {r['S']} | {r['days']} | {r['truthful_sim_k']:.1f} | {f('cournot_sim')} | "
                     f"{f('cournot_pt')} | {f('cournot_imp')} | {f('hedged_imp')} | {f('markup_imp')} | "
                     f"{r.get('m_star', '–')} | {r['withheld_mw']:.0f} | {r['impact_eur']:+.1f} |")
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
            row[f"book_vs_pt_{lab}"] = fmt(*ci((p[(c, "book")] - p[(c, "pricetaker")]).values))
        out.append(row)
    return pd.DataFrame(out)


if __name__ == "__main__":
    df = load()
    print(f"rows {len(df)}, days cal={df[df.set == 'cal'].day.nunique()} eval={df[df.set == 'eval'].day.nunique()}")
    st = slope_table(df)
    st.to_csv(TAB / "slope.csv")
    print(st.to_markdown())
    for s in ["cal", "eval"]:
        rows = size_table(df, s)
        pd.DataFrame(rows).to_csv(TAB / f"size_{s}.csv", index=False)
        print(f"\n### {s}\n" + md_size(rows))
        print("S* (sim, CI lo > 0):", s_star(rows), " S* (imp-real):", s_star(rows, "cournot_imp"))
    ht = hydro_table()
    if ht is not None:
        ht.to_csv(TAB / "hydro.csv", index=False)
        print("\n### hydro shifting (k€/day, shift/book minus price-taker schedule)\n" + ht.to_markdown(index=False))
