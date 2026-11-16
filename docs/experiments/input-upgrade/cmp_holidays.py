import os
from pathlib import Path
import sys, json
sys.path.insert(0,str(Path(__file__).resolve().parents[3] / 'docs/experiments/input-upgrade'))
import features as F
jl=json.load(open(str(Path((os.environ.get('INPUT_UPGRADE_DIR') or sys.exit("Set INPUT_UPGRADE_DIR to the required local file or directory"))) / 'ml_holidays_jl.json')))
ok=True
for c in ["GR","BG","RO","RS","ES","DE","SE","NL","FR","PL"]:
    py=sorted(str(d.date()) for d in F.holidays(c,range(2024,2028)))
    j=sorted(jl[c])
    same=(py==j)
    ok=ok and same
    print(f"{c:3s} py={len(py):2d} jl={len(j):2d} MATCH={same}")
    if not same:
        print("  py-only:",set(py)-set(j)); print("  jl-only:",set(j)-set(py))
# spot: GR 2026 orthodox good friday Apr10 present, western Apr3 absent
gr=set(jl["GR"])
print("GR 2026-04-10 (orthodox GoodFri) in set:", "2026-04-10" in gr)
print("GR 2026-04-03 (western GoodFri) NOT in set:", "2026-04-03" not in gr)
print("LOCKSTEP_OK" if ok else "LOCKSTEP_FAIL")
