"""Solar cannibalisation table (evaluation days)."""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R  # noqa: E402
d = pd.read_csv(MV.ROOT / "runs/st-impact/strat/solar.csv")
e = d[d.day >= "2026-07-01"].copy()
e["rate"] = e.capture / e.avg_with
e["rate_bat"] = e.capture_with_bat / e.avg_with
L = ["| zone | PV MWp | days | capture price €/MWh | Δ capture vs 100 MWp (paired, 90% CI) | capture rate (vs baseload with the PV) | market's own solar-weighted price | curtailed MWh/day | PV revenue €/MWp-day | with co-located battery: PV capture €/MWh | PV + battery €/MWp-day | capture on realised + impact |",
     "|" + "---|" * 12]
for (z, S), g in e.groupby(["zone", "S"]):
    g0 = e[(e.zone == z) & (e.S == 100)].set_index("day").capture
    m, lo, hi = R.block_bootstrap_ci((g.set_index("day").capture - g0.reindex(g.day).values).values)
    L.append(f"| {z} | {S} | {len(g)} | {g.capture.mean():.1f} | {m:+.1f} [{lo:+.1f}, {hi:+.1f}] | {g.rate.mean():.2f} | {g.base_solar_wavg.mean():.1f} | {g.curt_mwh.mean():.0f} | "
             f"{g.rev_per_mwp_day.mean():.0f} | {g.capture_with_bat.mean():.1f} | {g.combined_per_mwp_day.mean():.0f} | {g.capture_real_imp.mean():.1f} |")
txt = "\n".join(L)
(MV.ROOT / "runs/st-impact/tables/solar.md").write_text(txt + "\n")
print(txt)
