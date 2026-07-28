#!/usr/bin/env bash
# cv24.1 FULL 3-window run: only the cv24 arm (24 days, 4 shards, detached) — the
# base arm is byte-identical to cv23 and already computed (ab/base.tsv, hash-
# verified == cv24 run's base), so we reuse it. Clears the stale cv24-arm shards
# from the previous (cv24) run first, then forks fresh cv24.1 shards.
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
OUTDIR=docs/experiments/cv24/ab
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
rm -f "$OUTDIR"/cv24_s0.tsv "$OUTDIR"/cv24_s1.tsv "$OUTDIR"/cv24_s2.tsv "$OUTDIR"/cv24_s3.tsv "$OUTDIR"/cv24.tsv
declare -A DAYS
DAYS[0]="2026-03-01,2026-03-05,2025-07-06,2025-07-10,2025-04-19,2025-06-07"
DAYS[1]="2026-03-02,2026-03-06,2025-07-07,2025-07-11,2025-04-20,2025-06-08"
DAYS[2]="2026-03-03,2026-03-07,2025-07-08,2025-07-12,2025-05-24,2026-03-28"
DAYS[3]="2026-03-04,2026-03-08,2025-07-09,2025-07-13,2025-05-25,2026-03-29"
for idx in 0 1 2 3; do
  setsid env ARM=cv24 DAYS="${DAYS[$idx]}" OUT="$OUTDIR/cv24_s${idx}.tsv" \
    EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
    EUPHEMIA_DUCKDB_PATH="$EXT" EUPHEMIA_DUCKDB_THREADS=4 EUPHEMIA_DUCKDB_MEMORY=8GB \
    EUPHEMIA_DUCKDB_TEMP="$PWD/scratch_tmp" EUPHEMIA_DUCKDB_NPROCS_HINT=8 \
    nice -n 12 julia --project=. docs/experiments/cv24/ab_cv24.jl \
    > "$OUTDIR/log_cv24_s${idx}.txt" 2>&1 < /dev/null &
done
sleep 1
echo "forked 4 cv24.1 full-window shards (detached): $(pgrep -fc ab_cv24)"
