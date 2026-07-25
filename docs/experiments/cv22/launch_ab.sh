#!/usr/bin/env bash
# Launch a sharded 39-zone coupled A/B for one arm. Usage: launch_ab.sh <arm> <nshards>
# arm=base sets EUPHEMIA_DISABLE_CV22=1 (cv21 control); arm=cv22 leaves it unset
# (all cv22 mechanisms ON). Each shard writes out_<arm>_<i>.tsv; concatenate for
# scoring. Reads the offline extract read-only. Run from the repo root.
set -u
ARM="$1"; NSHARDS="${2:-8}"
HERE="docs/experiments/cv22"
DAYS_JSON="$HERE/days_ab.json"
ROOT="$(pwd)"
export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_PATH="$ROOT/data/extracts/euphemia-live.duckdb"
export EUPHEMIA_DUCKDB_READONLY=true   # concurrent shards must open the extract read-only
export EUPHEMIA_DUCKDB_NPROCS_HINT=16
[ "$ARM" = "base" ] && export EUPHEMIA_DISABLE_CV22=1 || unset EUPHEMIA_DISABLE_CV22
mapfile -t DAYS < <(python3 -c "import json,sys;[print(d) for d in json.load(open('$DAYS_JSON'))]")
declare -a SHARDS
for i in "${!DAYS[@]}"; do s=$(( i % NSHARDS )); SHARDS[$s]="${SHARDS[$s]:-}${DAYS[$i]},"; done
pids=()
for i in $(seq 0 $((NSHARDS-1))); do
  [ -z "${SHARDS[$i]:-}" ] && continue
  dl="${SHARDS[$i]%,}"
  OUT="$HERE/out_${ARM}_${i}.tsv" ARM="$ARM" DAYS="$dl" \
    julia --project=. "$HERE/ab_cv22.jl" > "$HERE/log_${ARM}_${i}.txt" 2>&1 &
  pids+=($!)
done
echo "launched ${#pids[@]} shards for arm=$ARM"
for p in "${pids[@]}"; do wait "$p"; done
cat "$HERE/out_${ARM}_"*.tsv | awk 'NR==1||$1!="day"' > "$HERE/out_${ARM}.tsv"
echo "ARM $ARM ALL DONE -> $HERE/out_${ARM}.tsv ($(wc -l < "$HERE/out_${ARM}.tsv") rows)"
