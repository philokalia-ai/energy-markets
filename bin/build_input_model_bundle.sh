#!/usr/bin/env bash
# Build the STANDALONE Euphemia input-model bundle: dist/euphemia-input-model-v1/
# (models + minimal python predictor + example + per-zone output parquets + README
# + CHECKSUMS) and a zip for a GitHub Release. dist/ is git-ignored — only this
# builder and the bin/input_model_bundle/ sources are committed.
#
# Usage:
#   bin/build_input_model_bundle.sh                 # full build (generates outputs)
#   SKIP_OUTPUTS=1 bin/build_input_model_bundle.sh  # reuse outputs already in dist/
#
# Output generation reuses the tested exporter (bin/export_prediction_inputs.jl)
# against a DuckDB extract + the PUBLIC open-meteo API. Env (all optional):
#   EUPHEMIA_DUCKDB_PATH  extract for the outputs (default data/extracts/euphemia-live.duckdb)
#   INPUTS_ASOF           ex-ante "now" date (default: today UTC)
#   INPUTS_BACK_DAYS      trailing window in market days (default 5)
#   INPUTS_HORIZON_DAYS   horizon in market days (default 1)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/bin/input_model_bundle"
MODELS_SRC="$REPO/bin/input_models"
NAME="euphemia-input-model-v1"
DIST="$REPO/dist/$NAME"
PILOTS="GR,ES,DE_LU,SE2,NL"

echo "== Euphemia input-model bundle builder =="
echo "   dist: $DIST"

rm -rf "$DIST"
mkdir -p "$DIST/models" "$DIST/python" "$DIST/examples" "$DIST/outputs"

# 1) models verbatim (15 LightGBM dumps + meta.json + geom.json)
for z in GR ES DE_LU SE2 NL; do
  cp "$MODELS_SRC/${z}_solar.txt" "$MODELS_SRC/${z}_wind.txt" "$MODELS_SRC/${z}_load.txt" "$DIST/models/"
done
cp "$MODELS_SRC/meta.json" "$MODELS_SRC/geom.json" "$DIST/models/"

# 2) minimal python predictor + example + README (committed sources)
cp "$SRC/python/"*.py "$SRC/python/requirements.txt" "$DIST/python/"
cp "$SRC/examples/"*.py "$DIST/examples/"
cp "$SRC/README.md" "$DIST/README.md"

# 3) per-zone output parquets (canonical predictions for a recent window)
if [ "${SKIP_OUTPUTS:-0}" = "1" ]; then
  echo "-- SKIP_OUTPUTS=1: expecting parquet already present in $DIST/outputs"
else
  EXTRACT="${EUPHEMIA_DUCKDB_PATH:-$REPO/data/extracts/euphemia-live.duckdb}"
  if [ ! -f "$EXTRACT" ]; then
    echo "!! extract not found: $EXTRACT" >&2
    echo "!! set EUPHEMIA_DUCKDB_PATH or SKIP_OUTPUTS=1 (with outputs pre-placed)" >&2
    exit 1
  fi
  STAGE="$(mktemp -d)"
  echo "-- generating outputs via bin/export_prediction_inputs.jl (extract: $EXTRACT)"
  export EUPHEMIA_DATA_STORE=duckdb
  export EUPHEMIA_DUCKDB_READONLY=true
  export EUPHEMIA_DUCKDB_PATH="$EXTRACT"
  export WEB_PARQUET_OUT="$STAGE"
  export INPUTS_ZONES="$PILOTS"
  export INPUTS_BACK_DAYS="${INPUTS_BACK_DAYS:-5}"
  export INPUTS_HORIZON_DAYS="${INPUTS_HORIZON_DAYS:-1}"
  [ -n "${INPUTS_ASOF:-}" ] && export INPUTS_ASOF
  julia --project="$REPO" "$REPO/bin/export_prediction_inputs.jl"
  cp "$STAGE/v1/inputs/"{GR,ES,DE_LU,SE2,NL}.parquet "$DIST/outputs/"
  cp "$STAGE/v1/inputs/manifest.json" "$DIST/outputs/"
  rm -rf "$STAGE"
fi

# 4) CHECKSUMS (sha256, repo-relative to the bundle root)
( cd "$DIST" && find . -type f ! -name CHECKSUMS -print0 | sort -z \
    | xargs -0 sha256sum > CHECKSUMS )

# 5) zip for the Release (never committed)
( cd "$REPO/dist" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )

echo "== done =="
echo "   bundle: $DIST"
echo "   zip:    $REPO/dist/$NAME.zip"
( cd "$DIST" && echo "   files: $(find . -type f | wc -l)" )
