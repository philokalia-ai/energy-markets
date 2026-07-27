#!/usr/bin/env bash
# Wait until both probe arms have written prices, then score the probe day.
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a49c46901af92fe34
base=docs/experiments/cv24/probe/base.tsv
cv24=docs/experiments/cv24/probe/cv24.tsv
while true; do
  bn=$(wc -l < "$base" 2>/dev/null || echo 0)
  cn=$(wc -l < "$cv24" 2>/dev/null || echo 0)
  if [ "$bn" -gt 1 ] && [ "$cn" -gt 1 ]; then break; fi
  sleep 20
done
echo "BOTH ARMS WROTE (base=$bn cv24=$cn) — scoring"
EUPHEMIA_DUCKDB_PATH=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb \
  julia --project=. docs/experiments/cv24/score_cv24.jl "$base" "$cv24" docs/experiments/cv24/windows_probe.json
echo "PROBE SCORE DONE"
