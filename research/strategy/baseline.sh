#!/bin/bash
# usage: baseline.sh LANE DAYS(comma)  — one capped scope, st-orch cores 64-67, 2 Julia threads.
LANE=$1; DAYS=$2; EM=$HOME/armada/em-team; WT=$EM/worktrees/strategy; RD=$EM/strategy/runs/baseline
mkdir -p $RD/logs $RD/tmp/$LANE
cd $WT
systemd-run --user --scope -q --unit=st-orch-base$LANE-$$ -p MemoryMax=${MEM:-4500M} -p MemorySwapMax=0 -p OOMPolicy=continue -p CPUWeight=20 \
 taskset -c ${CORES:-64-67} env -i HOME=$HOME PATH=/usr/local/bin:/usr/bin:/bin USER=$USER LANG=C.UTF-8 TMPDIR=$RD/tmp/$LANE \
  JULIA_DEPOT_PATH=$EM/depot-strategy:$EM/depot-cv46p:$EM/depot-lead:$EM/depot-ops \
  JULIA_NUM_THREADS=2 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
  EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true EUPHEMIA_FLOW_ASOF_MODE=v2 \
  EUPHEMIA_DUCKDB_PATH=$HOME/armada/em-data/euphemia-live-20261115.duckdb \
  EUPHEMIA_DUCKDB_TEMP=$RD/tmp/$LANE EUPHEMIA_DUCKDB_THREADS=2 EUPHEMIA_DUCKDB_MEMORY=1GB DAYS=$DAYS DAY=${DAY:-} REBUILD=${REBUILD:-} \
  $EM/runtimes/ops/julia-1.13.4/bin/julia --startup-file=no --heap-size-hint=3G --project=. ${SCRIPT:-research/strategy/baseline_days.jl}
