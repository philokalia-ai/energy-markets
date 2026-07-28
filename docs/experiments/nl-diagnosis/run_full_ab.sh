#!/bin/bash
# Restart-until-complete wrapper. The harness is resumable (skips done day,arm
# from the CSV), so a HiGHS segfault (#182) just restarts and continues.
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a2e9a829cb1e0a48e
export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_PATH=/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb
export EUPHEMIA_DUCKDB_READONLY=true
export EUPHEMIA_RESULTS_DB=/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/scratch_results.duckdb
export NL_DAYS="$1"
export NL_OUT="$2"
LOG="$3"
for attempt in $(seq 1 20); do
  echo "=== wrapper attempt $attempt $(date +%H:%M:%S) ===" >> "$LOG"
  stdbuf -oL -eL julia --project=. docs/experiments/nl-diagnosis/ab_harness.jl >> "$LOG" 2>&1
  rc=$?
  grep -q "HARNESS COMPLETE" "$LOG" && { echo "WRAPPER_DONE_COMPLETE rc=$rc" >> "$LOG"; break; }
  echo "=== wrapper: harness exited rc=$rc, restarting ===" >> "$LOG"
  sleep 3
done
echo "WRAPPER_EXIT" >> "$LOG"
