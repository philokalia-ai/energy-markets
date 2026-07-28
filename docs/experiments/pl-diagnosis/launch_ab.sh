#!/bin/bash
# Detached launcher: nohup+disown so the julia A/B survives background-task
# reaping. Returns immediately with the PID. Resumable (skips done days).
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a62ce346a9048029f
export DAYS="2025-01-07,2025-07-08,2025-01-08,2025-07-09,2025-01-09,2025-07-10,2025-01-10,2025-07-11,2025-01-11,2025-07-12"
export SPREAD=0.10
export OUTDIR=docs/experiments/pl-diagnosis
export EUPHEMIA_RESULTS_DB=/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a62ce346a9048029f/scratch_results_ab.duckdb
nohup julia --project=. docs/experiments/pl-diagnosis/ab_pl_both.jl >> docs/experiments/pl-diagnosis/log_ab.txt 2>&1 &
disown
echo "launched ab_pl_both pid $!"
