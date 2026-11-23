#!/bin/bash
# Full st-impact re-run on the cached RD curves: Part A (cal+eval), Part B, aggregation, reclear checks.
set -e
EM=$HOME/armada/em-team; R=$EM/strategy/runs/st-impact; WT=$EM/worktrees/strategy-st-impact; I=$WT/research/strategy/impact
PY="taskset -c 74-79 $EM/venv-ops431/bin/python -I"
cd $I
rm -f $R/strat/*
$PY run_strat.py cal $(cat $EM/strategy/days_cal.txt) > $R/logs/strat-cal-all.log 2>&1
$PY run_strat.py eval $(cat $EM/strategy/days_eval.txt) > $R/logs/strat-eval.log 2>&1
$PY mv_run.py > $R/logs/mv_run.log 2>&1
$PY mv_score.py > $R/tables/mv_score.md 2>&1
$PY aggregate.py > $R/tables/agg_full.md 2>&1
# reclear checks: the same 45 jobs (regenerated on the new curves)
J=""
for z in GR IT-SOUTH DE_LU FR ES; do for d in 2026-03-07 2026-09-13; do for S in 500 2000; do
  [ "$z" = IT-SOUTH ] && [ $S = 2000 ] && S=1000
  a="truthful,cournot"; [ $d = 2026-09-13 ] && a="truthful,cournot,hedged"
  for x in ${a//,/ }; do rm -f $R/rc/${d}_${z}_${S}_${x}.*; done
  J="$J,$($PY rc_jobs.py $d $z $S $a 2>/dev/null | tail -1)"
done; done; done
J=${J#,}; echo $J > $R/rc/jobs2.txt
cd $WT
MEM=2000M SCRIPT=research/strategy/impact/rc_check.jl JOBS=$J research/strategy/impact/rd.sh rcB > $R/logs/rcB.log 2>&1
ok=""; for j in ${J//,/ }; do [ -f $R/rc/$j.out.csv ] && ok="$ok $j"; done
$PY $I/rc_compare.py $ok > $R/tables/rc_check2.txt
echo RERUN DONE
