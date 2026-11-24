#!/bin/bash
# Score the long window (after overlay_lw.sh): comb_boot (paired day-block, seed 4646) per slice + score_2y paired.
EM=$HOME/armada/em-team; L=$EM/strategy/runs/st-impact/r2/long; PYT=$EM/venv-tsfm/bin/python
CB=$EM/worktrees/strategy-st-impact/research/strategy/impact/comb_boot.py; LBL="ShapeConduct(0) (63d0d11) − TranchesConduct (c490255)"
grep -q OVERLAY-LW-END $L/overlay_lw.log || { echo "overlay not done"; exit 2; }
run() { out=$1; shift; taskset -c 74-79 $PYT $CB $L/tsfm-base $L/tsfm-cand $L/phys-base $L/phys-cand $L/$out --label "$LBL" "$@" > /dev/null 2>&1; echo "$out rc=$?"; }
cd /tmp
$PYT -I $L/repro.py > $L/repro.md 2>&1; echo "repro rc=$?"
run boot_primary.md --start 2025-10-01 --end 2026-11-14 --exclude-days-file $EM/strategy/days_cal.txt --title " — window 2025-10-01..2026-11-14 minus the 12 calibration days (PRIMARY)"
run boot_all.md     --start 2025-10-01 --end 2026-11-14 --title " — whole window incl. calibration days"
run boot_eval.md    --start 2025-10-01 --end 2026-11-14 --days-file $EM/strategy/days_eval.txt --title " — 23 evaluation days"
run boot_rep.md     --start 2025-10-01 --end 2026-11-14 --days-file $EM/strategy/days_rep.txt --title " — 22 replication days"
run boot_cal.md     --start 2025-10-01 --end 2026-11-14 --days-file $EM/strategy/days_cal.txt --title " — 12 calibration days (in-sample, for reference)"
run boot_new.md     --start 2025-10-01 --end 2026-08-31 --exclude-days-file $EM/strategy/days_cal.txt --title " — 2025-10-01..2026-08-31 minus calibration days (new period)"
run boot_sepnov.md  --start 2026-09-01 --end 2026-11-14 --title " — 2026-09-01..11-14 (reproduction of the first combined check)"
cd $HOME/armada/em-tsfm && mkdir -p $L/paired && ln -sfn $L/tsfm-base/postsim $L/paired/pregate0630 && \
  taskset -c 74-79 $PYT docs/experiments/tsfm-2y-backtest/score_2y.py --tsfm $L/paired --c-root $L/tsfm-cand --phys-dir $L/phys-cand \
  --physics record --start 2025-10-01 --end 2026-11-14 --extract $HOME/armada/em-data/euphemia-live-20261115.duckdb \
  --json $L/paired.json --md $L/paired.md > /dev/null 2>&1; echo "score_2y paired rc=$?"
echo "SCORE-LW-END $(date -u +%FT%TZ)"
