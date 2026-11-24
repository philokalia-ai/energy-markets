"""Assemble strategy/st-impact/REPORT.md from REPORT.src.md + METHOD.md + generated tables (no retyped numbers)."""
import re, subprocess
from pathlib import Path
import pandas as pd
D = Path.home() / "armada/em-team/strategy/st-impact"
T = Path.home() / "armada/em-team/strategy/runs/st-impact/tables"
WT = Path.home() / "armada/em-team/worktrees/strategy-st-impact"
rt = (T / "report_tables.md").read_text()


def section(title_start):
    m = re.search(r"^### " + re.escape(title_start) + r".*?\n\n(.*?)(?=\n### |\Z)", rt, re.S | re.M)
    return m.group(1).strip()


st = pd.read_csv(T / "structure.csv")
fmt = lambda v: "–" if pd.isna(v) else f"{int(v)}"  # noqa: E731
rows = "\n".join(f"| {r.zone} | {r.slope500:+.2f} | {'' if pd.isna(r.hhi_fossil) else f'{r.hhi_fossil:.0f}'} | "
                 f"{fmt(r.S_star1pct_sim_eval)} | {fmt(r.S_star1pct_imp_eval)} | {fmt(r.S_star_sim_eval)} / {fmt(r.S_star_imp_eval)} |"
                 for r in st.itertuples())
mv = (T / "mv_score.md").read_text().split("\n\n")[0].strip().split("\n")
mv = "\n".join(l for l in mv if l.startswith("|"))
ra = pd.read_csv(T / "rc_check_absorption.csv")
rc_abs = "<details><summary>reclear check, competitive battery schedules (24 jobs)</summary>\n\n" + "\n".join(
    ["| job | mean abs Δp €/MWh | max abs Δp | value at re-cleared prices € | best price-taking value € | optimality gap % |",
     "|---|---|---|---|---|---|"] + [f"| {r.job} | {r.mae_p:.2f} | {r.max_p:.1f} | {r.value_rc:,.0f} | {r.best_pt_value:,.0f} | {r.opt_gap_pct:.1f} |"
                                    for r in ra.itertuples()]) + "\n\n</details>"
mk = pd.read_csv(T / "mk_score.csv")
mk_md = "\n".join(["| model | unit | zones | days | MAE baseline | MAE model | Δ MAE (90% CI) | share of miss explained | bias baseline | bias model | shape MAE baseline → model | Δ shape (90% CI) |",
                    "|---|---|---|---|---|---|---|---|---|---|---|---|"] +
                   [f"| {r.variant} | {r.unit} | {r.zones} | {r.days} | {r.mae_base:.2f} | {r.mae_model:.2f} | {r.dmae} | {r.share} | "
                    f"{r.bias_base:+.1f} | {r.bias_model:+.1f} | {r.shape_mae_base:.1f} → {r.shape_mae_model:.1f} | {r.dshape} |" for r in mk.itertuples()])
commit = subprocess.run(["git", "-C", str(WT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
src = (D / "REPORT.src.md").read_text().replace("@@METHOD@@", (D / "METHOD.md").read_text())
rep = {"STRUCT": rows, "TABLE_A": section("A. Thermal portfolio"), "HEDGE": section("Hedge vs forecast-optimal"),
       "STORAGE": section("A. Battery"), "HYDRO": section("A. Reservoir hydro"), "MVSCORE": mv,
       "MV_ZONE": section("B. per zone"), "MV_BAND": section("B. Implied flat markup by zone x hour band"),
       "COMMIT": commit,
       "ABSORB": (T / "absorption.md").read_text().strip(),
       "SOLAR": "\n".join(l for l in (T / "solar.md").read_text().strip().split("\n")
                          if l.startswith("| zone") or l.startswith("|---") or any(f"| {s} |" in l for s in ("100", "1000", "2000", "4000"))),
       "ROBUST": "\n".join(l for l in (T / "robust.md").read_text().strip().split("\n")
                           if l.startswith("| asset") or l.startswith("|---") or "| eval |" in l or "| cal | 0 |" in l),
       "RC_ABS": rc_abs,
       "MKSCORE": mk_md,
       "ABSORB4": (T / "absorption_4h.md").read_text().strip(),
       "S96": (T / "s96.md").read_text().strip(),
       "REP_TABLES": (T.parent / "rep" / "replication.md").read_text().strip()}
for k, v in rep.items():
    src = src.replace(f"@@{k}@@", v)
assert "@@" not in src, re.findall(r"@@\w+@@", src)
(D / "REPORT.md").write_text(src)
print("REPORT.md", len(src.splitlines()), "lines, commit", commit)
