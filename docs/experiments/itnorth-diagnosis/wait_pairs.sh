#!/bin/bash
CSV="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/cv25_summer.csv"
TARGET="${1:-1000}"
i=0
while true; do
  n=$(cat "$CSV" 2>/dev/null | wc -l)
  if [ "$n" -gt "$TARGET" ]; then break; fi
  i=$((i+1))
  if [ "$i" -ge 60 ]; then break; fi
  sleep 30
done
echo "waited $((i*30))s ; lines=$(cat "$CSV" 2>/dev/null | wc -l)"
cut -d, -f1,3 "$CSV" 2>/dev/null | sort -u | grep -E "base|treat"
