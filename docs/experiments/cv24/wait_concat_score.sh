#!/usr/bin/env bash
# Detached orchestrator: wait until all 8 A/B shards (4 base + 4 cv24) print their
# "ARM ... DONE" marker, then concat per arm and score. Writes the gate table to
# docs/experiments/cv24/ab/SCORE.txt. Run detached so it survives the harness
# task-wrapper lifetime cap:
#   setsid bash docs/experiments/cv24/wait_concat_score.sh > docs/experiments/cv24/ab/orch.log 2>&1 < /dev/null &
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
OUTDIR=docs/experiments/cv24/ab
EXT=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
deadline=$(( $(date +%s) + 4*3600 ))
while true; do
  done_n=$(grep -l "DONE" "$OUTDIR"/log_base_s0.txt "$OUTDIR"/log_base_s1.txt \
            "$OUTDIR"/log_base_s2.txt "$OUTDIR"/log_base_s3.txt \
            "$OUTDIR"/log_cv24_s0.txt "$OUTDIR"/log_cv24_s1.txt \
            "$OUTDIR"/log_cv24_s2.txt "$OUTDIR"/log_cv24_s3.txt 2>/dev/null | wc -l)
  echo "$(date -u +%H:%M:%S) shards DONE: $done_n/8"
  [ "$done_n" -ge 8 ] && break
  [ "$(date +%s)" -gt "$deadline" ] && { echo "TIMEOUT — scoring partial"; break; }
  sleep 60
done
for arm in base cv24; do
  out="$OUTDIR/${arm}.tsv"; printf 'day\tzone\ttimeslot\tprice\n' > "$out"
  tail -q -n +2 "$OUTDIR/${arm}_s0.tsv" "$OUTDIR/${arm}_s1.tsv" \
                "$OUTDIR/${arm}_s2.tsv" "$OUTDIR/${arm}_s3.tsv" >> "$out" 2>/dev/null
  echo "$arm rows: $(wc -l < "$out")"
done
EUPHEMIA_DUCKDB_PATH="$EXT" julia --project=. docs/experiments/cv24/score_cv24.jl \
  "$OUTDIR/base.tsv" "$OUTDIR/cv24.tsv" docs/experiments/cv24/windows_ab.json \
  > "$OUTDIR/SCORE.txt" 2>&1
echo "SCORE WRITTEN to $OUTDIR/SCORE.txt"
