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
commit = subprocess.run(["git", "-C", str(WT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
src = (D / "REPORT.src.md").read_text().replace("@@METHOD@@", (D / "METHOD.md").read_text())
rep = {"STRUCT": rows, "TABLE_A": section("A. Thermal portfolio"), "HEDGE": section("Hedge vs forecast-optimal"),
       "STORAGE": section("A. Battery"), "HYDRO": section("A. Reservoir hydro"), "MVSCORE": mv,
       "MV_ZONE": section("B. per zone"), "MV_BAND": section("B. Implied flat markup by zone x hour band"),
       "COMMIT": commit}
for k, v in rep.items():
    src = src.replace(f"@@{k}@@", v)
assert "@@" not in src, re.findall(r"@@\w+@@", src)
(D / "REPORT.md").write_text(src)
print("REPORT.md", len(src.splitlines()), "lines, commit", commit)
