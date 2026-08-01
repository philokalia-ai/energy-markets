#!/usr/bin/env bash
# Validation-B panel driver: a FRESH julia process per (day, arm) cell.
set -u
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a6e9a4443e04c8d5a
export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_READONLY=true
export EUPHEMIA_DUCKDB_PATH=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
export EUPHEMIA_OPENMETEO_ZONE_THROTTLE=0
for cell in "2026-07-24 old" "2026-07-25 old" "2026-07-25 ml" "2026-07-26 old" "2026-07-26 ml" "2026-07-27 old" "2026-07-27 ml"; do
  set -- $cell
  day=$1; arm=$2
  echo ">>> CELL $day $arm"
  julia --project=. docs/experiments/input-upgrade/panel_cell.jl "$day" "$arm" \
    >"docs/experiments/input-upgrade/panel_${day}_${arm}.out" \
    2>"docs/experiments/input-upgrade/panel_${day}_${arm}.err"
  echo "    rc=$? $(tail -1 docs/experiments/input-upgrade/panel_${day}_${arm}.out)"
done
echo "ALL_PANEL_CELLS_DONE"
