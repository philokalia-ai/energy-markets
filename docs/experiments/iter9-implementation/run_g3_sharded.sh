#!/usr/bin/env bash
# G3 A/B, sharded: split the 29 days into 4 shards and run each shard of each
# arm as its own read-only process (8 processes total). The per-day work is
# single-threaded (book build + :v3 365-day analogue queries + MPCC solve), so
# ~1 core/process; the machine has ample idle cores. All open the extract
# EUPHEMIA_DUCKDB_READONLY=true (shared read-only, no lock confound). Merged
# into ab_39.tsv / ab_43.tsv at the end. Identical backend/flow/solver as the
# non-sharded run — sharding only partitions days, so the A/B is unchanged.
set -uo pipefail
EXTRACT="$1"; SCRATCH="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
cd "$REPO"

# 4 contiguous day-shards over the sorted 29-day set (mar 8, apr 5, jul 16).
S1="2026-03-01..2026-03-08"
S2="2026-04-01..2026-04-05,2026-07-06..2026-07-08"
S3="2026-07-09..2026-07-15"
S4="2026-07-16..2026-07-21"
SHARDS=("$S1" "$S2" "$S3" "$S4")

common=(
  EUPHEMIA_DATA_STORE=duckdb
  EUPHEMIA_DUCKDB_PATH="$EXTRACT"
  EUPHEMIA_DUCKDB_READONLY=true
  EUPHEMIA_DUCKDB_NPROCS_HINT=8
  OPTIMIZER=highs
)

pids=()
for arm in 39 43; do
  for k in 0 1 2 3; do
    out="$HERE/ab_${arm}_s$((k+1)).tsv"
    log="$SCRATCH/ab_${arm}_s$((k+1)).log"
    rm -f "$out"
    env "${common[@]}" ZONESET="$arm" DAYS="${SHARDS[$k]}" OUT="$out" \
      nice -n 10 julia --project=. "$HERE/ab_run.jl" > "$log" 2>&1 &
    pids+=($!)
    echo "launched arm=$arm shard=$((k+1)) days=${SHARDS[$k]} pid=$! -> $out"
  done
done

echo "waiting on ${#pids[@]} shard processes..."
fail=0
for p in "${pids[@]}"; do wait "$p" || { echo "pid $p exited nonzero"; fail=1; }; done

# Merge shards per arm (header once, then all data rows).
for arm in 39 43; do
  dst="$HERE/ab_${arm}.tsv"
  echo -e "zone\ttimeslot\tprice" > "$dst"
  for k in 1 2 3 4; do
    s="$HERE/ab_${arm}_s${k}.tsv"
    [ -f "$s" ] && tail -n +2 "$s" >> "$dst"
  done
  echo "merged arm $arm -> $dst rows=$(( $(wc -l < "$dst") - 1 ))"
done
echo "G3 sharded A/B complete (fail=$fail)"
