#!/bin/bash
# worker.sh CORE [WAITPID] — pop "<arm> <day>" lines from the queue and clear them on one core.
source /home/pgeorgakopoulos/armada/em-team/results/level-env.sh
R=/home/pgeorgakopoulos/armada/em-team/results/level
core=$1; [ -n "$2" ] && while kill -0 $2 2>/dev/null; do sleep 20; done
cd /home/pgeorgakopoulos/armada/em-level
while true; do
  job=$(flock $R/queue.lock bash -c "head -1 $R/queue.txt; sed -i 1d $R/queue.txt")
  [ -z "$job" ] && break
  set -- $job; arm=$1; day=$2
  if [ "$arm" = inmerit ]; then export EUPHEMIA_INMERIT_TRUTH=1; else unset EUPHEMIA_INMERIT_TRUTH; fi
  echo "$(date -u +%H:%M) core $core start $arm $day" >> $R/queue.log
  JULIA_NUM_THREADS=1 taskset -c $core $J --project=. test/scripts/level/clear_capture.jl $R/$arm $day > $R/$arm.$day.log 2>&1
  echo "$(date -u +%H:%M) core $core end $arm $day rc=$? $(tail -1 $R/$arm.$day.log | cut -c1-80)" >> $R/queue.log
done
