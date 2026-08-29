#!/bin/bash
# Daily model-line emitter (crontab 10:40 UTC, after the JAO lead-1 freeze):
# 1. grow the feature cache: build the book for (today+1)-7 if not cached
#    (inputs for that past day exist; weekly persistence supplies the
#    forecast-horizon features ex-ante);
# 2. emit hybrid/stats model lines for today-2 .. today+7 into
#    simulations.model_lines (upsert).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export EUPHEMIA_DATA_STORE=postgres
mkdir -p data/model_line_feats
F=$(date -u -d "-6 days" +%F)
if [ ! -f "data/model_line_feats/$F.csv" ] && [ ! -f "data/backfill_books_cv37/$F.parquet" ]; then
    julia --project=. bin/capture_book_features.jl "$F" "data/model_line_feats/$F.csv"
fi
if python3 -c "import sklearn, joblib" 2>/dev/null; then PY=python3; else PY="uv run --quiet --with scikit-learn,pandas,pyarrow,duckdb,joblib,psycopg2-binary python3"; fi
$PY bin/emit_model_lines.py
