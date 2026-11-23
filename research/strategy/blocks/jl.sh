#!/bin/bash
# st-blocks: run a Julia script from the st-blocks worktree in ONE capped scope (cores 68-73, 9.5G), our depot.
# usage: jl.sh UNIT_TAG script.jl [args...]
TAG=$1; shift
EM=$HOME/armada/em-team; WT=$EM/worktrees/strategy-st-blocks
cd $WT
exec systemd-run --user --scope -q --unit=st-blocks-$TAG-$$ -p MemoryMax=${MEM:-9500M} -p MemorySwapMax=0 -p OOMPolicy=continue \
  -p CPUWeight=20 taskset -c ${CORES:-68-73} \
  env JULIA_DEPOT_PATH=$EM/depot-strategy:$EM/depot-cv46p:$EM/depot-lead:$EM/depot-ops \
  JULIA_NUM_THREADS=${JT:-2} OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
  EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true EUPHEMIA_FLOW_ASOF_MODE=v2 \
  EUPHEMIA_DUCKDB_PATH=$HOME/armada/em-data/euphemia-live-20261115.duckdb EUPHEMIA_DUCKDB_THREADS=2 \
  $EM/runtimes/ops/julia-1.13.4/bin/julia --startup-file=no --heap-size-hint=5G --project=. "$@"
