#!/bin/bash
# usage: DAYS=d1,d2 [ZONES=..] [QGRID=..] rd.sh TAG — one capped scope on st-impact cores 74-79, MemoryMax 7.5G.
TAG=$1; EM=$HOME/armada/em-team; WT=$EM/worktrees/strategy-st-impact; R=$EM/strategy/runs/st-impact
mkdir -p $R/logs $R/tmp/$TAG
cd $WT
systemd-run --user --scope -q --unit=st-impact-rd$TAG-$$ -p MemoryMax=${MEM:-7500M} -p MemorySwapMax=0 -p OOMPolicy=continue -p CPUWeight=20 \
 taskset -c ${CORES:-74-79} env -i HOME=$HOME PATH=/usr/local/bin:/usr/bin:/bin USER=$USER LANG=C.UTF-8 TMPDIR=$R/tmp/$TAG \
  JULIA_DEPOT_PATH=$EM/depot-strategy:$EM/depot-cv46p:$EM/depot-lead:$EM/depot-ops \
  JULIA_NUM_THREADS=4 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
  EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true EUPHEMIA_FLOW_ASOF_MODE=v2 \
  EUPHEMIA_DUCKDB_PATH=$HOME/armada/em-data/euphemia-live-20261115.duckdb \
  EUPHEMIA_DUCKDB_TEMP=$R/tmp/$TAG EUPHEMIA_DUCKDB_THREADS=2 EUPHEMIA_DUCKDB_MEMORY=1GB \
  DAYS=$DAYS ZONES=${ZONES:-} QGRID=${QGRID:-} HARNESS=${HARNESS:-} JOBS=${JOBS:-} SUFFIX=${SUFFIX:-} \
  $EM/runtimes/ops/julia-1.13.4/bin/julia --startup-file=no --heap-size-hint=5G --project=. ${SCRIPT:-research/strategy/impact/rd_days.jl}
