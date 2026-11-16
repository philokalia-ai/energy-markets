#!/bin/bash
# launch_final.sh LABEL CORE_START "ENV=VAL ..." — 8 calibration days, 4 procs x 2 days, retry-wrapped
set -eo pipefail
source "${BLOCKS_RESULTS_DIR:?Set BLOCKS_RESULTS_DIR to the experiment results directory}/env.sh"
export J JULIA_NUM_THREADS=2
R="${BLOCKS_RESULTS_DIR:?Set BLOCKS_RESULTS_DIR to the experiment results directory}"
label=$1; c=$2; envs=$3
cd "${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v "${J:?Set J to the Julia executable}" >/dev/null
command -v nohup >/dev/null
if [ ! -x "$R/retry.sh" ]; then echo "Missing executable: $R/retry.sh" >&2; exit 1; fi
unset EUPHEMIA_COMPLEX_ORDERS EUPHEMIA_RES_OFFER_LADDER EUPHEMIA_BLOCK_PRICE EUPHEMIA_INMERIT_TRUTH
# envs is intentionally a whitespace-separated list of NAME=VALUE assignments.
if [ -n "$envs" ]; then export $envs; fi
revision=$(git rev-parse HEAD)
julia_version=$("$J" --version)
started=$(date -u)
mkdir -p "$R/$label"
echo "commit=$revision julia=$julia_version env='$envs' started=$started" > "$R/$label/PROVENANCE"
i=0
for pair in "2026-09-20 2026-10-19" "2026-11-04 2026-11-13" "2026-11-02 2026-10-06" "2026-09-27 2026-09-16"; do
  log="$R/$label.$i.log"
  : >> "$log"   # Check writability without truncating an existing retry log.
  # $pair intentionally expands into two date arguments.
  nohup "$R/retry.sh" "$((c + i))" "$log" "$label" $pair >/dev/null 2>&1 &
  i=$((i+1))
done
