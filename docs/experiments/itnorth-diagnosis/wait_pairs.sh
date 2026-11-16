#!/bin/bash
CSV="${EM_SCRATCH_DIR:?Set EM_SCRATCH_DIR to the experiment scratch directory}/cv25_summer.csv"
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
