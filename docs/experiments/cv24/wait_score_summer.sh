#!/usr/bin/env bash
# Detached: wait for the 8 summer shards to finish, concat per arm, score the
# summer window only. Writes docs/experiments/cv24/ab_summer/SCORE.txt.
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
OUTDIR=docs/experiments/cv24/ab_summer
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
printf '{"summer2025": ["2025-07-06","2025-07-07","2025-07-08","2025-07-09","2025-07-10","2025-07-11","2025-07-12","2025-07-13"]}\n' > "$OUTDIR/win.json"
deadline=$(( $(date +%s) + 2*3600 ))
while true; do
  n=$(grep -l "DONE" "$OUTDIR"/log_base_s0.txt "$OUTDIR"/log_base_s1.txt \
        "$OUTDIR"/log_base_s2.txt "$OUTDIR"/log_base_s3.txt \
        "$OUTDIR"/log_cv24_s0.txt "$OUTDIR"/log_cv24_s1.txt \
        "$OUTDIR"/log_cv24_s2.txt "$OUTDIR"/log_cv24_s3.txt 2>/dev/null | wc -l)
  echo "$(date -u +%H:%M:%S) summer shards DONE: $n/8"
  [ "$n" -ge 8 ] && break
  [ "$(date +%s)" -gt "$deadline" ] && { echo TIMEOUT; break; }
  sleep 30
done
for arm in base cv24; do
  out="$OUTDIR/${arm}.tsv"; printf 'day\tzone\ttimeslot\tprice\n' > "$out"
  tail -q -n +2 "$OUTDIR/${arm}_s0.tsv" "$OUTDIR/${arm}_s1.tsv" \
                "$OUTDIR/${arm}_s2.tsv" "$OUTDIR/${arm}_s3.tsv" >> "$out" 2>/dev/null
done
EUPHEMIA_DUCKDB_PATH="$EXT" julia --project=. docs/experiments/cv24/score_cv24.jl \
  "$OUTDIR/base.tsv" "$OUTDIR/cv24.tsv" "$OUTDIR/win.json" > "$OUTDIR/SCORE.txt" 2>&1
echo "SUMMER SCORE WRITTEN"
