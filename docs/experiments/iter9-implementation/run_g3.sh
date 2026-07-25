#!/usr/bin/env bash
# G3 A/B launcher: run the 39-zone (control) and 43-zone (treatment) arms
# offline against the SAME read-only DuckDB extract, HiGHS, :v3 flows (default),
# save_to_db=false. Identical backend for both arms => ULP-stable, fair delta.
#
# Usage: run_g3.sh <extract.duckdb> <scratchdir>
set -euo pipefail
EXTRACT="$1"; SCRATCH="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
cd "$REPO"

common_env=(
  EUPHEMIA_DATA_STORE=duckdb
  EUPHEMIA_DUCKDB_PATH="$EXTRACT"
  EUPHEMIA_DUCKDB_READONLY=true
  EUPHEMIA_DUCKDB_NPROCS_HINT=2
  OPTIMIZER=highs
  DAYS="2026-04-01..2026-04-05,2026-07-06..2026-07-21,2026-03-01..2026-03-08"
)

run_arm () {
  local zoneset="$1" out="$2" log="$3"
  env "${common_env[@]}" ZONESET="$zoneset" OUT="$out" \
    nice -n 10 julia --project=. "$HERE/ab_run.jl" > "$log" 2>&1
}

# Two arms in parallel against the read-only extract (no writes; save_to_db=false).
run_arm 39 "$HERE/ab_39.tsv" "$SCRATCH/ab_39.log" &
P39=$!
run_arm 43 "$HERE/ab_43.tsv" "$SCRATCH/ab_43.log" &
P43=$!
wait $P39; echo "ARM39 exit $?"
wait $P43; echo "ARM43 exit $?"
echo "G3 A/B arms complete"
