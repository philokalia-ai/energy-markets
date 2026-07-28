#!/usr/bin/env bash
# cv24.1 summer2025 inner-loop: fork BOTH arms (base + cv24), 4 shards each (2
# days/shard), fully detached (setsid) into ab_summer/. Machine is free, so all
# 8 run concurrently. Resumable. Followed by wait_score_summer.sh.
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
OUTDIR=docs/experiments/cv24/ab_summer; mkdir -p "$OUTDIR"
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
declare -A DAYS
DAYS[0]="2025-07-06,2025-07-10"
DAYS[1]="2025-07-07,2025-07-11"
DAYS[2]="2025-07-08,2025-07-12"
DAYS[3]="2025-07-09,2025-07-13"
for arm in base cv24; do
  for idx in 0 1 2 3; do
    setsid env ARM="$arm" DAYS="${DAYS[$idx]}" OUT="$OUTDIR/${arm}_s${idx}.tsv" \
      EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
      EUPHEMIA_DUCKDB_PATH="$EXT" EUPHEMIA_DUCKDB_THREADS=4 EUPHEMIA_DUCKDB_MEMORY=8GB \
      EUPHEMIA_DUCKDB_TEMP="$PWD/scratch_tmp" EUPHEMIA_DUCKDB_NPROCS_HINT=8 \
      nice -n 12 julia --project=. docs/experiments/cv24/ab_cv24.jl \
      > "$OUTDIR/log_${arm}_s${idx}.txt" 2>&1 < /dev/null &
  done
done
sleep 1
echo "forked 8 summer shards (detached): $(pgrep -fc ab_cv24)"
