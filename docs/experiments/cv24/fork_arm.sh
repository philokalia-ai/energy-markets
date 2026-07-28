#!/usr/bin/env bash
# Fork the 4 shards of ONE arm as fully-detached (setsid) julia processes, then
# EXIT immediately — so there is no long-lived parent for the harness to reap
# (the orphaned julia procs run to completion and write their OUT tsv). Each
# shard is resumable (ab_cv24.jl skips days already in its OUT). Usage:
#   bash docs/experiments/cv24/fork_arm.sh <arm>       # arm = base | cv24
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
arm=$1
OUTDIR=docs/experiments/cv24/ab
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
declare -A DAYS
DAYS[0]="2026-03-01,2026-03-05,2025-07-06,2025-07-10,2025-04-19,2025-06-07"
DAYS[1]="2026-03-02,2026-03-06,2025-07-07,2025-07-11,2025-04-20,2025-06-08"
DAYS[2]="2026-03-03,2026-03-07,2025-07-08,2025-07-12,2025-05-24,2026-03-28"
DAYS[3]="2026-03-04,2026-03-08,2025-07-09,2025-07-13,2025-05-25,2026-03-29"
for idx in 0 1 2 3; do
  setsid env ARM="$arm" DAYS="${DAYS[$idx]}" OUT="$OUTDIR/${arm}_s${idx}.tsv" \
    EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
    EUPHEMIA_DUCKDB_PATH="$EXT" EUPHEMIA_DUCKDB_THREADS=4 EUPHEMIA_DUCKDB_MEMORY=8GB \
    EUPHEMIA_DUCKDB_TEMP="$PWD/scratch_tmp" EUPHEMIA_DUCKDB_NPROCS_HINT=8 \
    nice -n 12 julia --project=. docs/experiments/cv24/ab_cv24.jl \
    > "$OUTDIR/log_${arm}_s${idx}.txt" 2>&1 < /dev/null &
done
sleep 1
echo "forked $arm shards (detached): $(pgrep -fc ab_cv24)"
