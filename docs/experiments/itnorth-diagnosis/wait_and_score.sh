#!/bin/bash
# Wait until the summer CSV has enough completed base+treat pairs, then score.
CSV="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/cv25_summer.csv"
DIR="/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a483a94dc4173ee7e/docs/experiments/itnorth-diagnosis"
TARGET="${1:-1040}"   # ~2 full pairs
i=0
while true; do
  n=$(cat "$CSV" 2>/dev/null | wc -l)
  if [ "$n" -gt "$TARGET" ]; then break; fi
  i=$((i+1)); if [ "$i" -ge 80 ]; then break; fi
  sleep 45
done
echo "=== waited $((i*45))s ; lines=$(cat "$CSV" 2>/dev/null | wc -l) ==="
echo "base days: $(cut -d, -f1,3 "$CSV" 2>/dev/null | sort -u | grep -c base)  treat days: $(cut -d, -f1,3 "$CSV" 2>/dev/null | sort -u | grep -c treat)"
python3 "$DIR/score_cv25.py" "$CSV" "cv25 summer A/B (partial)" 2>&1
