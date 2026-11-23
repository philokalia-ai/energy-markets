"""Compact report tables from the st-impact outputs (prints markdown)."""
import ast, sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
T = MV.ROOT / "runs/st-impact/tables"
RUN = MV.ROOT / "runs/st-impact"


def f(x, k=1e3):
    if isinstance(x, str):
        x = ast.literal_eval(x.replace("nan", "None")) if x.startswith("(") else x
    if not isinstance(x, tuple) or x[0] is None:
        return "–"
    return f"{x[0]/k:+.1f} [{x[1]/k:+.1f}, {x[2]/k:+.1f}]"


ev = pd.read_csv(T / "size_eval.csv")
ev = ev[ev.note.isna()] if "note" in ev else ev
print("### A. Thermal portfolio, evaluation days (k€/day; Δ = arm − truthful; 90% day-block CI)\n")
print("| zone | S MW | days | truthful sim | Δ Cournot sim | (% of truthful) | Δ Cournot realised+impact | Δ Cournot price-taker realised | "
      "Δ hedged realised+impact | withheld MW (mean) | price impact €/MWh | best flat markup m* (cal) and its Δ realised+impact |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in ev.itertuples():
    pct = ast.literal_eval(r.cournot_sim.replace("nan", "None"))[0] / (r.truthful_sim_k * 1e3) * 100
    print(f"| {r.zone} | {r.S} | {int(r.days)} | {r.truthful_sim_k:.0f} | {f(r.cournot_sim)} | {pct:+.1f}% | {f(r.cournot_imp)} | "
          f"{f(r.cournot_pt)} | {f(getattr(r, 'hedged_imp', None))} | {r.withheld_mw:.0f} | {r.impact_eur:+.1f} | "
          f"{r.m_star} : {f(r.markup_imp)} |")
print("\n### Hedge vs forecast-optimal (evaluation days, k€/day)\n")
print("| zone | S MW | sim (forecast) | price-taker realised | realised+impact |\n|---|---|---|---|---|")
for r in ev.itertuples():
    if isinstance(getattr(r, "hedge_vs_fc_imp", None), str):
        print(f"| {r.zone} | {r.S} | {f(r.hedge_vs_fc_sim)} | {f(r.hedge_vs_fc_pt)} | {f(r.hedge_vs_fc_imp)} |")
H = pd.read_csv(RUN / "mv/hours.csv")
H["f_real"] = H.f_real.fillna("")
H["set"] = np.where(H.day < "2026-07-01", "cal", "eval")
print("\n### B. Implied flat markup over SRMC (flexible thermal), by zone and marginal technology\n")
print("| zone | marginal tech | set | hours | book ladder m (median) | realised-implied m (median, uncensored) | p25–p75 | censored |")
print("|---|---|---|---|---|---|---|---|")
for (z, t, s), g in H.groupby(["zone", "tech", "set"]):
    if len(g) < 8 or t in ("res",) or z == "NO2":
        continue
    ok = g[(g.f_real == "") & g.m_real.notna()]
    if len(ok) < 5:
        continue
    print(f"| {z} | {t} | {s} | {len(g)} | {g.m_book.median():+.2f} | {ok.m_real.median():+.2f} | "
          f"{ok.m_real.quantile(.25):+.2f}…{ok.m_real.quantile(.75):+.2f} | {(g.f_real != '').mean():.0%} |")
print("\n### B. per zone (all hours)\n")
print("| zone | set | hours | coupled | book m | implied m (coupled) | implied m (islanded) | censored lo | median error €/MWh |")
print("|---|---|---|---|---|---|---|---|---|")
for (z, s), g in H.groupby(["zone", "set"]):
    ok = g[(g.f_real == "") & g.m_real.notna()]
    print(f"| {z} | {s} | {len(g)} | {(g.tech=='coupled').mean():.0%} | {g.m_book.median():+.2f} | {ok.m_real.median():+.2f} | "
          f"{g.m_real_isl.median():+.2f} | {(g.f_real=='lo').mean():.0%} | {(g.p_real-g.p_base).median():+.1f} |")

print("\n### B. Implied flat markup by zone x hour band x marginal technology (evaluation days; cells >= 10 hours, >= 5 uncensored)\n")
print("| zone | band | marginal tech | hours | book ladder m | implied m (median) | p25…p75 | censored |")
print("|---|---|---|---|---|---|---|---|")
for (z, b, t), g in H[H.set == "eval"].groupby(["zone", "band", "tech"]):
    ok = g[(g.f_real == "") & g.m_real.notna()]
    if len(g) < 10 or len(ok) < 5 or t in ("res", "nuclear") or z == "NO2":
        continue
    print(f"| {z} | {b} | {t} | {len(g)} | {g.m_book.median():+.2f} | {ok.m_real.median():+.2f} | "
          f"{ok.m_real.quantile(.25):+.2f}…{ok.m_real.quantile(.75):+.2f} | {(g.f_real != '').mean():.0%} |")
pd.DataFrame([dict(zone=z, band=b, tech=t, set=st, hours=len(g), m_book=g.m_book.median(),
                   m_real=g[(g.f_real == "") & g.m_real.notna()].m_real.median(),
                   censored=(g.f_real != "").mean())
              for (z, b, t, st), g in H.groupby(["zone", "band", "tech", "set"])]).to_csv(T / "mv_zone_band_tech.csv", index=False)

import rdopt as R  # noqa: E402
d = pd.read_csv(RUN / "strat/storage.csv")
d["set"] = np.where(d.day < "2026-07-01", "cal", "eval")
print("\n### A. Battery (new, S MW / 2S MWh, η 0.88): strategic − price-taker schedule (k€/day)\n")
print("| zone | S MW | set | days | price-taker sim | Δ sim | Δ realised+impact | Δ price-taker realised | throughput MWh pt → strat |")
print("|---|---|---|---|---|---|---|---|---|")
for (z, S, st), g in d.groupby(["zone", "S", "set"]):
    p = g.pivot(index="day", columns="arm", values=["sim_profit", "imp_profit", "pt_profit", "throughput_mwh"])
    dd = lambda c: f(tuple(R.block_bootstrap_ci((p[(c, "strategic")] - p[(c, "pricetaker")]).values)))  # noqa: E731
    print(f"| {z} | {S} | {st} | {len(p)} | {p[('sim_profit', 'pricetaker')].mean()/1e3:.0f} | {dd('sim_profit')} | "
          f"{dd('imp_profit')} | {dd('pt_profit')} | {p[('throughput_mwh', 'pricetaker')].mean():.0f} → "
          f"{p[('throughput_mwh', 'strategic')].mean():.0f} |")
hy = pd.read_csv(T / "hydro.csv")
print("\n### A. Reservoir hydro (carved, same daily energy): strategic − price-taker schedule (k€/day)\n")
print("| zone | S MW | set | days with energy | energy MWh | Δ sim | Δ realised+impact | Δ price-taker realised |")
print("|---|---|---|---|---|---|---|---|")
for r in hy[hy.S.isin([250, 1000])].itertuples():
    print(f"| {r.zone} | {r.S} | {r.set} | {r.days} | {r.energy_mwh:.0f} | {r.shift_vs_pt_sim} | {r.shift_vs_pt_imp} | {r.shift_vs_pt_pt} |")
