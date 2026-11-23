#!/usr/bin/env python3
"""Report tables from score_pt.py --json: per archetype, every zone × format with the main Δ, Δ vs hourly_sched,
and the two sensitivities side by side. usage: python -I tables_pt.py SCORE.json > tables.md"""
import json, sys
import pandas as pd
j = json.load(open(sys.argv[1]))
m = pd.DataFrame(j["main"]); p = pd.DataFrame(j["pen10"]); s = pd.DataFrame(j["su05"])
key = ["zone", "arch", "format"]
m = m.merge(p[key + ["d", "lo", "hi"]].rename(columns={"d": "dp", "lo": "plo", "hi": "phi"}), on=key, how="left")
m = m.merge(s[key + ["d", "lo", "hi"]].rename(columns={"d": "ds5", "lo": "slo5", "hi": "shi5"}), on=key, how="left")
order = {"hourly_mc": 0, "hourly_ac": 1, "hourly_oc": 0, "hourly_sched": 1, "block": 2, "linked": 3, "exclusive": 4, "mar": 5}
f = lambda v, lo, hi: "—" if pd.isna(v) else f"{v:+.1f} [{lo:+.1f},{hi:+.1f}]"
g = lambda v, n=2: "—" if pd.isna(v) else f"{v:.{n}f}"
for ar in ["CCGT", "COAL", "HYDRO", "PSP", "BESS", "PVBAT", "FLEX"]:
    t = m[m.arch == ar].copy(); t["o"] = t.format.map(order); t = t.sort_values(["zone", "o"])
    print(f"\n#### {ar} (benchmark {t.bench.iloc[0]})")
    print("| zone | format | k_su | profit €/MW-d | Δ vs bench [90%] | Δ vs hourly_sched [90%] | Δ, re-trade +10 €/MWh | Δ, start-up ×0.5 | accepted | missed | unfilled h | P5 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in t.itertuples():
        print(f"| {r.zone} | {r.format} | {r.k_su:.2f} | {r.profit:.1f} | {f(r.d, r.lo, r.hi)} | {f(r.ds, r.slo, r.shi)} | "
              f"{f(r.dp, r.plo, r.phi)} | {f(r.ds5, r.slo5, r.shi5)} | {g(r.acc)} | {g(r.missed)} | {r.unfilled_h:.1f} | {r.p5:.1f} |")
