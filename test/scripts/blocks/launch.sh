#!/bin/bash
# launch.sh LABEL KINDS CORE_START  — clear the 8 calibration days for one arm, 4 procs x 2 days
# KINDS = value of EUPHEMIA_COMPLEX_ORDERS ("" = baseline)
set -eo pipefail
source "${BLOCKS_RESULTS_DIR:?Set BLOCKS_RESULTS_DIR to the experiment results directory}/env.sh"
# EXTRA_ENV is intentionally a whitespace-separated list of NAME=VALUE assignments.
if [ -n "${EXTRA_ENV:-}" ]; then export $EXTRA_ENV; fi
export JULIA_NUM_THREADS=2
R="${BLOCKS_RESULTS_DIR:?Set BLOCKS_RESULTS_DIR to the experiment results directory}"
label=$1; kinds=$2; c=$3
cd "${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v "${J:?Set J to the Julia executable}" >/dev/null
command -v nohup >/dev/null
command -v taskset >/dev/null
revision=$(git rev-parse HEAD)
started=$(date -u)
mkdir -p "$R/$label"
echo "$revision kinds=$kinds $started" > "$R/$label/PROVENANCE"
if [ -z "$kinds" ]; then unset EUPHEMIA_COMPLEX_ORDERS; else export EUPHEMIA_COMPLEX_ORDERS="$kinds"; fi
i=0
for pair in "2026-09-20 2026-10-19" "2026-11-04 2026-11-13" "2026-11-02 2026-10-06" "2026-09-27 2026-09-16"; do
  core=$((c + i))
  log="$R/$label.$i.log"
  : > "$log"   # Validate the log path before starting a background process.
  # $pair intentionally expands into two date arguments.
  nohup taskset -c "$core" "$J" --project=. test/scripts/blocks/clear_days.jl "$label" $pair > "$log" 2>&1 &
  i=$((i+1))
done
