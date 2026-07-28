#!/usr/bin/env bash
# Detached: wait for the 4 cv24.1 full-window shards to finish, concat cv24.tsv,
# score vs the reused cv23 base.tsv over all 3 windows. Writes ab/SCORE_cv24_1.txt.
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
OUTDIR=docs/experiments/cv24/ab
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
deadline=$(( $(date +%s) + 3*3600 ))
while true; do
  n=$(grep -l "DONE" "$OUTDIR"/log_cv24_s0.txt "$OUTDIR"/log_cv24_s1.txt \
        "$OUTDIR"/log_cv24_s2.txt "$OUTDIR"/log_cv24_s3.txt 2>/dev/null | wc -l)
  echo "$(date -u +%H:%M:%S) cv24.1 shards DONE: $n/4"
  [ "$n" -ge 4 ] && break
  [ "$(date +%s)" -gt "$deadline" ] && { echo TIMEOUT; break; }
  sleep 45
done
out="$OUTDIR/cv24.tsv"; printf 'day\tzone\ttimeslot\tprice\n' > "$out"
tail -q -n +2 "$OUTDIR/cv24_s0.tsv" "$OUTDIR/cv24_s1.tsv" \
              "$OUTDIR/cv24_s2.tsv" "$OUTDIR/cv24_s3.tsv" >> "$out" 2>/dev/null
echo "cv24.1 rows: $(wc -l < "$out")  base rows: $(wc -l < "$OUTDIR/base.tsv")"
EUPHEMIA_DUCKDB_PATH="$EXT" julia --project=. docs/experiments/cv24/score_cv24.jl \
  "$OUTDIR/base.tsv" "$OUTDIR/cv24.tsv" docs/experiments/cv24/windows_ab.json \
  > "$OUTDIR/SCORE_cv24_1.txt" 2>&1
echo "FULL cv24.1 SCORE WRITTEN"
