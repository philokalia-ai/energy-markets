#!/usr/bin/env python3
"""st-blocks price-taker scorer.

usage: ~/armada/em-team/venv-ops431/bin/python -I score_pt.py CAL.csv EVAL.csv [--json OUT.json] [--draws 10000] [--seed 4646]

Rows: run_pt.jl output. Units: profit €/day per row; tables report €/MW-day (profit / the archetype's MW).
1. Calibration (CAL rows only): for every (zone, archetype, format, su_scale) with a k_su grid, the k_su with the
   highest mean profit on the calibration days (pen = 0, hourly bids on hourly prices). Nothing is chosen on EVAL.
2. Evaluation (EVAL rows, calibrated k_su): per (zone, archetype, format): mean profit, Δ vs the benchmark
   (thermal: hourly_mc; others: hourly_oc) with a day-block bootstrap 90% interval (resample days with replacement,
   statistic = mean Δ over days, numpy default_rng(seed), 5th/95th percentiles), acceptance share (block formats:
   days with ≥ 1 family accepted), 'missed' share (no family accepted while the benchmark earned > 0), unfilled
   hours (thermal: realised P > SRMC and the unit off), re-traded MWh, profit P5 (5th percentile of daily €/MW-day).
3. Sensitivities on EVAL: pen = 10 €/MWh on re-traded MWh; true start-up × 0.5 (k_su recalibrated on CAL);
   15-minute: 60-min vs 15-min products on realised PT15M quarters.
"""
import argparse, json
import numpy as np
import pandas as pd

BENCH = {"CCGT": "hourly_mc", "COAL": "hourly_mc"}
KEY = ["zone", "arch", "format"]


def boot(x, draws, seed):
    x = np.asarray(x, float)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(x), size=(draws, len(x)))
    m = x[idx].mean(1)
    return float(np.percentile(m, 5)), float(np.percentile(m, 95))


def calibrate(cal):
    c = cal[(cal.pen == 0) & (cal.res_bid == 60) & (cal.res_eval == 60)]
    g = c.groupby(KEY + ["su_scale", "nl_scale", "k_su"]).profit.mean().reset_index()
    best = g.loc[g.groupby(KEY + ["su_scale", "nl_scale"]).profit.idxmax()]
    return {(r.zone, r.arch, r.format, r.su_scale, r.nl_scale): float(r.k_su) for r in best.itertuples()}


def pick(df, kmap):
    k = df.apply(lambda r: kmap.get((r.zone, r.arch, r.format, r.su_scale, r.nl_scale), 1.0), axis=1)
    return df[np.isclose(df.k_su, k)]


def table(ev, draws, seed, label):
    out = []
    for (z, a), g in ev.groupby(["zone", "arch"]):
        bf = BENCH.get(a, "hourly_oc")
        b = g[g.format == bf].set_index("day")
        if b.empty:
            continue
        cap = float(b.cap_mw.iloc[0])
        for f, h in g.groupby("format"):
            h = h.set_index("day")
            days = sorted(set(h.index) & set(b.index))
            pm = h.loc[days, "profit"] / cap
            d = (h.loc[days, "profit"] - b.loc[days, "profit"]) / cap
            lo, hi = boot(d.to_numpy(), draws, seed) if f != bf else (0.0, 0.0)
            blk = f not in ("hourly_mc", "hourly_ac", "hourly_oc", "hourly_sched")
            sc = g[g.format == "hourly_sched"].set_index("day")
            if not sc.empty and f != "hourly_sched":
                ds = (h.loc[days, "profit"] - sc.loc[days, "profit"]) / cap
                slo, shi = boot(ds.to_numpy(), draws, seed); dsm = ds.mean()
            else:
                dsm = slo = shi = np.nan
            acc = (h.loc[days, "n_fam_acc"] > 0).mean() if blk else np.nan
            missed = ((h.loc[days, "n_fam_acc"] == 0) & (b.loc[days, "profit"] > 0)).mean() if blk else np.nan
            out.append(dict(set=label, zone=z, arch=a, format=f, days=len(days),
                            k_su=float(h.k_su.iloc[0]), profit=pm.mean(), d=d.mean(), lo=lo, hi=hi,
                            acc=acc, missed=missed, unfilled_h=h.loc[days, "unfilled_h"].mean(),
                            retraded=h.loc[days, "dev_mwh"].mean(), p5=float(np.percentile(pm, 5)),
                            bench=bf, ds=dsm, slo=slo, shi=shi))
    return pd.DataFrame(out)


def show(t, title):
    print(f"\n### {title}")
    for (z, a), g in t.groupby(["zone", "arch"]):
        print(f"\n{z} {a} (benchmark {g.bench.iloc[0]}, {g.days.max()} days)")
        print("| format | k_su | profit €/MW-d | Δ vs bench [90%] | Δ vs hourly_sched [90%] | accepted | missed | unfilled h | re-traded MWh | P5 |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for r in g.sort_values("d", ascending=False).itertuples():
            fmt = lambda v, n=1: "—" if pd.isna(v) else f"{v:.{n}f}"
            dss = "—" if pd.isna(r.ds) else f"{r.ds:+.1f} [{r.slo:+.1f},{r.shi:+.1f}]"
            print(f"| {r.format} | {r.k_su:.2f} | {r.profit:.1f} | {r.d:+.1f} [{r.lo:+.1f},{r.hi:+.1f}] | {dss} | "
                  f"{fmt(r.acc, 2)} | {fmt(r.missed, 2)} | {fmt(r.unfilled_h)} | {r.retraded:.0f} | {r.p5:.1f} |")


def thermal_grid(E, draws, seed):
    """Δ of the fixed structure (CCGT exclusive / COAL linked / block) vs hourly_mc and vs hourly_ac per cost cell."""
    out = []
    th = E[E.arch.isin(["CCGT", "COAL"])]
    for (z, ar, su, nl), g in th.groupby(["zone", "arch", "su_scale", "nl_scale"]):
        cap = float(g.cap_mw.iloc[0])
        mc = g[g.format == "hourly_mc"].set_index("day").profit
        ac = g[g.format == "hourly_ac"].set_index("day").profit
        for f in (["exclusive", "block"] if ar == "CCGT" else ["linked", "block"]):
            h = g[g.format == f].set_index("day").profit
            days = sorted(set(h.index) & set(mc.index) & set(ac.index))
            dm = (h.loc[days] - mc.loc[days]) / cap; da = (h.loc[days] - ac.loc[days]) / cap
            mlo, mhi = boot(dm.to_numpy(), draws, seed); alo, ahi = boot(da.to_numpy(), draws, seed)
            out.append(dict(zone=z, arch=ar, format=f, su=su, nl=nl, dmc=dm.mean(), mlo=mlo, mhi=mhi, dac=da.mean(),
                            alo=alo, ahi=ahi, pmc=mc.loc[days].mean() / cap, pac=ac.loc[days].mean() / cap))
    return pd.DataFrame(out).sort_values(["arch", "zone", "format", "nl", "su"], ascending=[True, True, False, False, True])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cal"); ap.add_argument("eval"); ap.add_argument("--json")
    ap.add_argument("--draws", type=int, default=10000); ap.add_argument("--seed", type=int, default=4646)
    a = ap.parse_args()
    assert a.draws >= 10000
    cal, ev = pd.read_csv(a.cal), pd.read_csv(a.eval)
    assert not set(cal.day) & set(ev.day), "calibration and evaluation days overlap"
    kmap = calibrate(cal)
    E = pick(ev, kmap)
    if "nl_scale" not in E:
        E["nl_scale"] = 1.0
    NL1 = E.nl_scale == 1
    grid = thermal_grid(E[(E.pen == 0) & (E.res_bid == 60) & (E.res_eval == 60)], a.draws, a.seed)
    main_t = table(E[NL1 & (E.pen == 0) & (E.su_scale == 1) & (E.res_bid == 60) & (E.res_eval == 60)], a.draws, a.seed, "main")
    pen_t = table(E[NL1 & (E.pen == 10) & (E.su_scale == 1) & (E.res_bid == 60) & (E.res_eval == 60)], a.draws, a.seed, "pen10")
    su_t = table(E[NL1 & (E.pen == 0) & (E.su_scale == 0.5) & (E.res_bid == 60) & (E.res_eval == 60)], a.draws, a.seed, "su0.5")
    q = E[NL1 & (E.pen == 0) & (E.su_scale == 1) & (E.res_eval == 15)]
    q15 = []
    for (z, ar, f), g in q.groupby(KEY):
        h60 = g[g.res_bid == 60].set_index("day").profit; h15 = g[g.res_bid == 15].set_index("day").profit
        days = sorted(set(h60.index) & set(h15.index))
        if not days:
            continue
        cap = float(g.cap_mw.iloc[0]); d = (h15.loc[days] - h60.loc[days]) / cap
        lo, hi = boot(d.to_numpy(), a.draws, a.seed)
        q15.append(dict(zone=z, arch=ar, format=f, days=len(days), p60=h60.loc[days].mean() / cap,
                        p15=h15.loc[days].mean() / cap, d=d.mean(), lo=lo, hi=hi))
    q15 = pd.DataFrame(q15)
    print(f"st-blocks price-taker score: cal days {cal.day.nunique()}, eval days {ev.day.nunique()}, draws {a.draws}, seed {a.seed}")
    show(main_t, "MAIN: realised hourly SDAC, intraday re-trade at the DA price (pen 0), repo start-up cost")
    show(pen_t, "SENSITIVITY: re-traded MWh cost 10 €/MWh")
    show(su_t, "SENSITIVITY: true start-up cost × 0.5 (k_su recalibrated)")
    print("\n### THERMAL SENSITIVITY: true no-load × start-up cost (k_su recalibrated per cell on CAL; ×1.5 = stress)")
    print("Fixed structure per archetype (CCGT exclusive, COAL linked; plain block shown too). Δ €/MW-day [90%].")
    print("| zone | arch | format | no-load | start-up | vs hourly_mc | vs hourly_ac | hourly_mc profit | hourly_ac profit |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in grid.itertuples():
        print(f"| {r.zone} | {r.arch} | {r.format} | ×{r.nl:g} | ×{r.su:g} | {r.dmc:+.1f} [{r.mlo:+.1f},{r.mhi:+.1f}] | "
              f"{r.dac:+.1f} [{r.alo:+.1f},{r.ahi:+.1f}] | {r.pmc:.1f} | {r.pac:.1f} |")
    print("\n### 15-MINUTE: 15-min products vs 60-min products on realised PT15M quarters (Δ = 15 − 60, €/MW-day)")
    print("| zone | arch | format | days | 60-min | 15-min | Δ [90%] |\n|---|---|---|---|---|---|---|")
    for r in q15.itertuples():
        print(f"| {r.zone} | {r.arch} | {r.format} | {r.days} | {r.p60:.1f} | {r.p15:.1f} | {r.d:+.1f} [{r.lo:+.1f},{r.hi:+.1f}] |")
    if a.json:
        json.dump({"kmap": {"|".join(map(str, k)): v for k, v in kmap.items()},
                   "main": main_t.to_dict("records"), "pen10": pen_t.to_dict("records"),
                   "su05": su_t.to_dict("records"), "q15": q15.to_dict("records"), "thermal_grid": grid.to_dict("records")}, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
