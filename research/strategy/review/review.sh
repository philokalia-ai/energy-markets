#!/bin/bash
# st-impact review: st-blocks' committed scripts from a detached worktree of strategy@efe6271, one capped scope on st-impact cores.
# usage: research/strategy/review/review.sh TAG CORES script.jl args...  (WT = a detached worktree of strategy, default st-impact-review @efe6271)
TAG=$1; CORES=$2; shift 2
EM=$HOME/armada/em-team; WT=${WT:-$EM/worktrees/st-impact-review}
cd $WT
exec systemd-run --user --scope -q --unit=st-impact-rev$TAG-$$ -p MemoryMax=${MEM:-4500M} -p MemorySwapMax=0 -p OOMPolicy=continue \
  -p CPUWeight=20 taskset -c $CORES \
  env JULIA_DEPOT_PATH=$EM/depot-strategy:$EM/depot-cv46p:$EM/depot-lead:$EM/depot-ops \
  JULIA_NUM_THREADS=2 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
  EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true EUPHEMIA_FLOW_ASOF_MODE=v2 \
  EUPHEMIA_DUCKDB_PATH=$HOME/armada/em-data/euphemia-live-20261115.duckdb EUPHEMIA_DUCKDB_THREADS=2 \
  $EM/runtimes/ops/julia-1.13.4/bin/julia --startup-file=no --heap-size-hint=3G --project=. "$@"
