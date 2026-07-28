#!/bin/bash
# Detached launcher: runs the interleaved cv25 A/B fully outside the task
# framework (setsid) so it is not culled/restarted. stdout -> worktree log.
cd /home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a483a94dc4173ee7e
WIN="${1:-summer}"
OUT="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad"
julia --project=. docs/experiments/itnorth-diagnosis/ab_cv25_interleaved.jl "$WIN" "$OUT" \
  > docs/experiments/itnorth-diagnosis/ab_run_${WIN}.log 2>&1
echo "DONE $WIN" >> docs/experiments/itnorth-diagnosis/ab_run_${WIN}.log
