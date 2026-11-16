#!/bin/bash
# Restart-until-complete wrapper. The harness is resumable (skips done day,arm
# from the CSV), so a HiGHS segfault (#182) just restarts and continues.
cd "${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_PATH="${EUPHEMIA_DUCKDB_PATH:?Set EUPHEMIA_DUCKDB_PATH to the read-only extract}"
export EUPHEMIA_DUCKDB_READONLY=true
export EUPHEMIA_RESULTS_DB="${EUPHEMIA_RESULTS_DB:?Set EUPHEMIA_RESULTS_DB to a writable scratch results database}"
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
