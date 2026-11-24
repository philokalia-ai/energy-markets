"""15-minute vs hourly storage orders with price impact: summary (evaluation fast-tier days, 96-step baselines).
usage: python -I s96_summary.py runs/st-impact/s96/<file>.csv -> markdown table + runs/st-impact/tables/s96.md
Per zone x asset x size x format: profit per MW-day for res=60 and res=15 on our re-cleared market (sim) and price-taker
on realised PT15M quarter prices (pt); Δ(15 − 60) with a day-block 90% CI; own price impact = sim − (price-taker at our
own forecast), per MW-day; mean |Δp| the orders cause in the zone."""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R  # noqa: E402
P_MW = {"BESS": 100.0, "PSP": 300.0}
d = pd.read_csv(sys.argv[1])
d = d[d.status.isin(["optimal", "time_limit"])]
d["mw"] = d.asset.map(P_MW) * d["size"]
for c in ("profit_sim", "profit_pt", "profit_fc"):
    d[c + "_mw"] = d[c] / d.mw
d["impact_mw"] = d.profit_sim_mw - d.profit_fc_mw
f = lambda t: f"{t[0]:+.1f} [{t[1]:+.1f}, {t[2]:+.1f}]"  # noqa: E731
L = ["| zone | asset | size | format | days | sim €/MW-d 60 → 15 | Δ sim (15−60) | realised PT15M €/MW-d 60 → 15 | Δ realised (15−60) | clear − price-taker at our forecast €/MW-d 60 / 15 (acceptance + own price impact) | mean abs Δp €/MWh 60 / 15 | families accepted / offered: 60 ; 15 |",
     "|" + "---|" * 12]
for (z, a, s, fm), g in d.groupby(["zone", "asset", "size", "format"]):
    p = g.pivot_table(index="day", columns="res", values=["profit_sim_mw", "profit_pt_mw", "impact_mw", "dp_mean_abs", "n_fam", "n_fam_acc"])
    if 60 not in p["profit_sim_mw"] or 15 not in p["profit_sim_mw"]:
        continue
    p = p.dropna(subset=[("profit_sim_mw", 60), ("profit_sim_mw", 15)])
    ds = R.block_bootstrap_ci((p[("profit_sim_mw", 15)] - p[("profit_sim_mw", 60)]).values)
    dr = R.block_bootstrap_ci((p[("profit_pt_mw", 15)] - p[("profit_pt_mw", 60)]).values)
    L.append(f"| {z} | {a} | {s:.0f}x | {fm} | {len(p)} | {p[('profit_sim_mw', 60)].mean():.0f} → {p[('profit_sim_mw', 15)].mean():.0f} | {f(ds)} | "
             f"{p[('profit_pt_mw', 60)].mean():.0f} → {p[('profit_pt_mw', 15)].mean():.0f} | {f(dr)} | "
             f"{p[('impact_mw', 60)].mean():+.0f} / {p[('impact_mw', 15)].mean():+.0f} | "
             f"{p[('dp_mean_abs', 60)].mean():.2f} / {p[('dp_mean_abs', 15)].mean():.2f} | "
             f"{p[('n_fam_acc', 60)].mean():.1f} / {p[('n_fam', 60)].mean():.1f} ; {p[('n_fam_acc', 15)].mean():.1f} / {p[('n_fam', 15)].mean():.1f} |")
txt = "\n".join(L)
(MV.ROOT / "runs/st-impact/tables/s96.md").write_text(txt + "\n")
print(txt)
