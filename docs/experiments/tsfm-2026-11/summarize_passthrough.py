"""Summarise passthrough_<arm>.parquet: pass-through = ΣΔforecast / ΣΔsim (or per +MW of load).

Usage: python summarize_passthrough.py sim phys physresid
"""
import os, sys
import numpy as np, pandas as pd

OUT = os.environ.get("TSFM_OUT", "/home/pgeorgakopoulos/armada/em-team/results/tsfm")


def main(arms):
    p = pd.concat([pd.read_parquet(f"{OUT}/passthrough_{a}.parquet") for a in arms], ignore_index=True)
    rows = []
    for (arm, scen), g in p.groupby(["arm", "scenario"]):
        days = g.market_date.nunique()
        if scen == "dc574":
            for z in ["GR", "BG", "RO", "RS"]:
                s = g[g.zone == z]
                if len(s):
                    rows.append(dict(arm=arm, test=f"DC {z}", days=days, cells=len(s), dsim=s.dsim.mean(),
                                     dfc=s.dfc.mean(), passthrough=s.dfc.sum() / s.dsim.sum(),
                                     frac_hours_same_sign=(np.sign(s.dfc) == np.sign(s.dsim)).mean()))
        elif scen == "dc_loadonly":
            rows.append(dict(arm=arm, test="DC GR load-only (+574 MW, sim fixed)", days=days, cells=len(g),
                             dsim=0.0, dfc=g.dfc.mean(), passthrough=np.nan,
                             eur_per_100MW=100 * g.dfc.sum() / g.dload.sum()))
        elif scen == "ops":
            s = g[g.dsim.abs() > 0]
            rows.append(dict(arm=arm, test=f"cold ironing ({s.zone.nunique()} zones pooled)", days=days, cells=len(s),
                             dsim=s.dsim.mean(), dfc=s.dfc.mean(), passthrough=s.dfc.sum() / s.dsim.sum(),
                             frac_hours_same_sign=(np.sign(s.dfc) == np.sign(s.dsim)).mean()))
            pz = s.groupby("zone").apply(lambda x: x.dfc.sum() / x.dsim.sum(), include_groups=False)
            rows[-1]["zone_pt_median"] = pz.median()
        elif scen == "syn_sim10":
            pz = g.groupby("zone").apply(lambda x: x.dfc.sum() / x.dsim.sum(), include_groups=False)
            rows.append(dict(arm=arm, test="synthetic sim +10%", days=days, cells=len(g), dsim=g.dsim.mean(),
                             dfc=g.dfc.mean(), passthrough=g.dfc.sum() / g.dsim.sum(), zone_pt_median=pz.median(),
                             frac_hours_same_sign=(np.sign(g.dfc) == np.sign(g.dsim)).mean(),
                             zones_pt_lt_0=(pz < 0).sum()))
        elif scen == "syn_load10":
            rows.append(dict(arm=arm, test="synthetic residual load +10% (sim fixed)", days=days, cells=len(g),
                             dsim=0.0, dfc=g.dfc.mean(), passthrough=np.nan,
                             eur_per_100MW=100 * g.dfc.sum() / g.dload.sum(),
                             frac_hours_positive=(g.dfc > 0).mean()))
    t = pd.DataFrame(rows)
    pd.set_option("display.width", 250)
    print(t.round(3).to_string(index=False))
    t.to_csv(f"{OUT}/passthrough_summary.csv", index=False)


if __name__ == "__main__":
    main(sys.argv[1:])
