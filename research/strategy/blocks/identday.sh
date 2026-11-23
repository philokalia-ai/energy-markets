#!/bin/bash
# st-blocks identity run: one record-pipeline day from worktree WT (main defaults, no company orders) into OUT/<day>.duckdb.
# usage: identday.sh WT DAY OUT CORES MEM   (record_day.jl copied from cv46-blocks/cb-harness, unchanged)
WT=$1; DAY=$2; OUT=$3; CORES=$4; MEM=$5
EM=$HOME/armada/em-team; H=$EM/worktrees/strategy-st-blocks/research/strategy/blocks
mkdir -p $OUT/tmp/$DAY; rm -f $OUT/$DAY.duckdb $OUT/$DAY.duckdb.wal
cd $WT
systemd-run --user --scope -q --unit=st-blocks-ident-$(basename $OUT)-$DAY-$$ -p MemoryMax=$MEM -p MemorySwapMax=0 \
  -p OOMPolicy=continue -p CPUWeight=20 taskset -c $CORES \
  env -i HOME=$HOME PATH=/usr/local/bin:/usr/bin:/bin USER=$USER LANG=C.UTF-8 TMPDIR=$OUT/tmp/$DAY \
  JULIA_DEPOT_PATH=$EM/depot-strategy:$EM/depot-cv46p:$EM/depot-lead:$EM/depot-ops \
  JULIA_NUM_THREADS=2 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
  EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true EUPHEMIA_FLOW_ASOF_MODE=v2 \
  EUPHEMIA_DUCKDB_PATH=$HOME/armada/em-data/euphemia-live-20261115.duckdb \
  EUPHEMIA_DUCKDB_TEMP=$OUT/tmp/$DAY EUPHEMIA_DUCKDB_THREADS=2 EUPHEMIA_DUCKDB_MEMORY=1GB \
  EUPHEMIA_RESULTS_DB=$OUT/$DAY.duckdb DAYS=$DAY SOLVERS=1 BOOKS=1 IN_FLIGHT=1 \
  $EM/runtimes/ops/julia-1.13.4/bin/julia --startup-file=no --heap-size-hint=3G --project=. $H/record_day.jl > $OUT/$DAY.log 2>&1
echo "rc=$? $(date -u +%FT%TZ)" >> $OUT/$DAY.log
gzip -f $OUT/$DAY.log; rm -rf $OUT/tmp/$DAY
