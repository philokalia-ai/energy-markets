#!/usr/bin/env bash
# cv24 full-window A/B launcher. Runs base (EUPHEMIA_DISABLE_CV24) then cv24 over
# the three windows, 4 shards per arm, ARMS SEQUENTIAL (≤4 concurrent 39-zone
# clears at any time — respects the WLS/no-thrash budget). Each shard resumable
# (ab_cv24.jl skips days already present in its OUT). Concats shards per arm.
#
#   bash docs/experiments/cv24/launch_ab.sh > docs/experiments/cv24/ab/launch.log 2>&1
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
OUTDIR=docs/experiments/cv24/ab; mkdir -p "$OUTDIR"
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
DAYS_ALL="2026-03-01,2026-03-02,2026-03-03,2026-03-04,2026-03-05,2026-03-06,2026-03-07,2026-03-08,2025-07-06,2025-07-07,2025-07-08,2025-07-09,2025-07-10,2025-07-11,2025-07-12,2025-07-13,2025-04-19,2025-04-20,2025-05-24,2025-05-25,2025-06-07,2025-06-08,2026-03-28,2026-03-29"
IFS=',' read -ra D <<< "$DAYS_ALL"
declare -a S0 S1 S2 S3
for i in "${!D[@]}"; do eval "S$((i%4))+=(\"${D[$i]}\")"; done
join_by(){ local IFS=,; echo "$*"; }
run_arm(){ # arm
  local arm=$1
  for idx in 0 1 2 3; do
    local var="S$idx[@]"; local days; days=$(join_by "${!var}")
    ARM=$arm DAYS="$days" OUT="$OUTDIR/${arm}_s${idx}.tsv" \
    EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
    EUPHEMIA_DUCKDB_PATH=$EXT EUPHEMIA_DUCKDB_THREADS=4 EUPHEMIA_DUCKDB_MEMORY=8GB \
    EUPHEMIA_DUCKDB_TEMP="$PWD/scratch_tmp" EUPHEMIA_DUCKDB_NPROCS_HINT=8 \
    nice -n 12 julia --project=. docs/experiments/cv24/ab_cv24.jl \
      > "$OUTDIR/log_${arm}_s${idx}.txt" 2>&1 &
  done
  wait
  local out="$OUTDIR/${arm}.tsv"; printf 'day\tzone\ttimeslot\tprice\n' > "$out"
  for i in 0 1 2 3; do tail -n +2 "$OUTDIR/${arm}_s${i}.tsv" >> "$out" 2>/dev/null; done
  echo "$arm arm complete: $(wc -l < "$out") rows"
}
echo "=== base arm (4 shards) ==="; run_arm base
echo "=== cv24 arm (4 shards) ==="; run_arm cv24
echo "AB COMPLETE"
EUPHEMIA_DUCKDB_PATH=$EXT julia --project=. docs/experiments/cv24/score_cv24.jl \
  "$OUTDIR/base.tsv" "$OUTDIR/cv24.tsv" docs/experiments/cv24/windows_ab.json
echo "SCORE COMPLETE"
