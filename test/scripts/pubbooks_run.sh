#!/usr/bin/env bash
# Published-books clearing validation runner: one FRESH Julia process per market
# day (protocol §3). Requires PUBBOOKS_DIR set to the (uncommitted) pubbooks dir.
# Usage: PUBBOOKS_DIR=/path test/scripts/pubbooks_run.sh <GME|OMIE> [day ...]
set -euo pipefail
cd "$(dirname "$0")/../.."

export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_PATH="${EUPHEMIA_DUCKDB_PATH:-/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb}"
export EUPHEMIA_DUCKDB_READONLY=true

EX="$1"; shift
exl=$(echo "$EX" | tr '[:upper:]' '[:lower:]')

if [[ $# -eq 0 ]]; then
  # derive days from the cells file
  mapfile -t DAYS < <(cut -f3 "$PUBBOOKS_DIR/intermediate/${exl}_cells.tsv" | tail -n +2 | sort -u)
else
  DAYS=("$@")
fi

for d in "${DAYS[@]}"; do
  echo ">>> $EX $d"
  julia --project=. test/scripts/pubbooks_clear.jl "$EX" "$d"
done
