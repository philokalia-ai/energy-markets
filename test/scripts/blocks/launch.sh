#!/bin/bash
# launch.sh LABEL KINDS CORE_START  — clear the 8 calibration days for one arm, 4 procs x 2 days
# KINDS = value of EUPHEMIA_COMPLEX_ORDERS ("" = baseline)
source /home/pgeorgakopoulos/armada/em-team/results/blocks/env.sh
[ -n "$EXTRA_ENV" ] && export $EXTRA_ENV
export JULIA_NUM_THREADS=2
R=/home/pgeorgakopoulos/armada/em-team/results/blocks
label=$1; kinds=$2; c=$3
cd ${REPO:-/home/pgeorgakopoulos/armada/em-blocks}
mkdir -p $R/$label; echo "$(git rev-parse HEAD) kinds=$kinds $(date -u)" > $R/$label/PROVENANCE
if [ -z "$kinds" ]; then unset EUPHEMIA_COMPLEX_ORDERS; else export EUPHEMIA_COMPLEX_ORDERS=$kinds; fi
i=0
for pair in "2026-09-20 2026-10-19" "2026-11-04 2026-11-13" "2026-11-02 2026-10-06" "2026-09-27 2026-09-16"; do
  core=$((c + i))
  nohup taskset -c $core $J --project=. test/scripts/blocks/clear_days.jl $label $pair > $R/$label.$i.log 2>&1 &
  i=$((i+1))
done
