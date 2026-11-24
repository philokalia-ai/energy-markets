#!/bin/bash
# After lw.sh: export both arms (export_phys.py, cv46 copy), reuse checks vs the existing 07-02..11-14 exports, and
# base record vs cv46 bf96-PR-74d9fc3 per day (ident.py). Writes $L/post_records.md. Read-only on cv46-physics.
EM=$HOME/armada/em-team; L=$EM/strategy/runs/st-impact/r2/long; HS=$EM/strategy/st-impact/harness; PY=$EM/venv-ops431/bin/python
C=$EM/cv46-physics/runs/cp-runs; CMB=$EM/strategy/runs/st-impact/r2/comb
for a in base cand; do
  systemd-run --user --scope -q --unit=st-impact-lw-exp-$a-$$ -p MemoryMax=8G -p MemorySwapMax=0 -p CPUWeight=20 \
    taskset -c 74-79 $PY -I $HS/export_phys.py $L/$a/db $L/phys-$a > $L/export-$a.log 2>&1 &
done; wait
$PY -I - <<'PYEOF' > $L/post_records.md
import os, glob, pandas as pd
L=os.path.expanduser('~/armada/em-team/strategy/runs/st-impact/r2/long')
ref={'base':os.path.expanduser('~/armada/em-team/cv46-physics/runs/cp-runs/combined-pr-74d9fc3/phys-PR'),
     'cand':os.path.expanduser('~/armada/em-team/strategy/runs/st-impact/r2/comb/phys-SHAPE')}
print('# Long-window records: exports and reuse checks\n')
for a in ('base','cand'):
    fs=sorted(os.listdir(f'{L}/phys-{a}')); rows=sum(len(pd.read_csv(f'{L}/phys-{a}/{f}')) for f in fs)
    print(f'- {a}: {len(fs)} Athens-day files {fs[0]}..{fs[-1]}, {rows:,} rows')
    rf=sorted(os.listdir(ref[a])); same=0; diff=[]; cells=0
    for f in rf:
        x=pd.read_csv(f'{ref[a]}/{f}'); p=f'{L}/phys-{a}/{f}'
        if not os.path.exists(p): diff.append(f+' missing'); continue
        y=pd.read_csv(p); cells+=len(x)
        if len(x)==len(y) and (x.columns==y.columns).all() and x.equals(y): same+=1
        else: diff.append(f)
    print(f'  reuse check vs {ref[a]}: {same}/{len(rf)} files identical ({cells:,} cells); differing: {diff[:10]}')
    print(f'  REUSE_{a.upper()}={"yes" if not diff else "no"}')
PYEOF
echo "" >> $L/post_records.md; echo "## base record vs cv46 bf96-PR-74d9fc3 (ident.py per market day)" >> $L/post_records.md
n=0; ok=0; bad=(); for f in $L/base/db/*.duckdb; do d=$(basename $f .duckdb); [ -e $C/bf96-PR-74d9fc3/db/$d.duckdb ] || continue
  n=$((n+1)); $PY -I $HS/../../../cv46-physics/cp-runs/harness/ident.py $C/bf96-PR-74d9fc3/db/$d.duckdb $f > /dev/null 2>&1 && ok=$((ok+1)) || bad+=($d); done
echo "- $ok/$n days identical; differing: ${bad[*]:0:40}" >> $L/post_records.md
$PY -I $L/zone_days.py >> $L/post_records.md 2>&1
echo "POST-RECORDS-END $(date -u +%FT%TZ)" >> $L/post_records.md
