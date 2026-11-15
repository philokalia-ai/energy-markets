#!/bin/bash
# worker_bt.sh CORES — two-month cv42 vs cv43 backtest worker (Julia 1.13.4 + HiGHS 1.27).
source /home/pgeorgakopoulos/armada/em-team/results/level-env13.sh
R=/home/pgeorgakopoulos/armada/em-team/results/level-bt
S=/tmp/claude-1000/-home-pgeorgakopoulos-armada-em-level/1beb691d-7c8a-4266-afda-d61321c708c2/scratchpad
SCRIPT=/home/pgeorgakopoulos/armada/em-level/test/scripts/level/clear_capture.jl
cores=$1
while true; do
  [ -f $R/STOP ] && break
  job=$(flock $R/queue.lock bash -c "head -1 $R/queue.txt; sed -i 1d $R/queue.txt")
  [ -z "$job" ] && break
  set -- $job; arm=$1; day=$2
  wt=$S/cv43main; [ "$arm" = cv42 ] && wt=$S/cv42
  echo "$(date -u +%H:%M:%S) [$cores] start $arm $day" >> $R/queue.log
  (cd $wt && LEVEL_CAPTURE=0 JULIA_NUM_THREADS=3 taskset -c $cores $J --project=. $SCRIPT $R/$arm $day > $R/$arm.$day.log 2>&1)
  echo "$(date -u +%H:%M:%S) [$cores] end $arm $day rc=$? $(grep -E '^(DONE|FAILED|skip)' $R/$arm.$day.log | tail -1)" >> $R/queue.log
done
