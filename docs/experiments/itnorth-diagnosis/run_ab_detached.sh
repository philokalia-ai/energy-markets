#!/bin/bash
# Detached launcher: runs the interleaved cv25 A/B fully outside the task
# framework (setsid) so it is not culled/restarted. stdout -> worktree log.
cd "${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WIN="${1:-summer}"
OUT="${EM_SCRATCH_DIR:?Set EM_SCRATCH_DIR to the experiment scratch directory}"
julia --project=. docs/experiments/itnorth-diagnosis/ab_cv25_interleaved.jl "$WIN" "$OUT" \
  > docs/experiments/itnorth-diagnosis/ab_run_${WIN}.log 2>&1
echo "DONE $WIN" >> docs/experiments/itnorth-diagnosis/ab_run_${WIN}.log
