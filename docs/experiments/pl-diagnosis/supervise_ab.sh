#!/bin/bash
# Crash-resilient supervisor: relaunches the A/B harness after a HiGHS SIGSEGV
# (#182) until AB_BOTH_COMPLETE. The harness resumes (skips done days), so each
# relaunch only re-precompiles then continues. Runs detached (nohup+disown).
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a62ce346a9048029f
export DAYS="2025-01-07,2025-07-08,2025-01-08,2025-07-09,2025-01-09,2025-07-10,2025-01-10,2025-07-11,2025-01-11,2025-07-12"
export SPREAD=0.10
export OUTDIR=docs/experiments/pl-diagnosis
export EUPHEMIA_RESULTS_DB=/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a62ce346a9048029f/scratch_results_ab.duckdb
LOG=docs/experiments/pl-diagnosis/log_ab.txt
for i in $(seq 1 40); do
  if grep -q "AB_BOTH_COMPLETE" "$LOG" 2>/dev/null; then echo "SUPERVISOR: complete" >> "$LOG"; break; fi
  echo "SUPERVISOR: launch attempt $i" >> "$LOG"
  julia --project=. docs/experiments/pl-diagnosis/ab_pl_both.jl >> "$LOG" 2>&1
  echo "SUPERVISOR: julia exited (code $?) attempt $i" >> "$LOG"
  sleep 3
done
echo "SUPERVISOR: done" >> "$LOG"
