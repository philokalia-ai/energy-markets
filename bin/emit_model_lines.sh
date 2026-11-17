#!/bin/bash
# Daily model-line emitter (crontab 10:40 UTC, after the JAO lead-1 freeze):
# 1. grow the feature cache: build the book for (today+1)-7 if not cached
#    (inputs for that past day exist; weekly persistence supplies the
#    forecast-horizon features ex-ante);
# 2. emit hybrid/stats model lines for today-2 .. today+7 into
#    simulations.model_lines (upsert); strict as-of is ON by default in Python,
#    MODEL_LINES_STRICT_ASOF=0 disables it; MODEL_LINES_REWRITE_PAST=1 allows backfills;
# 3. post-sim Timestral refresh of tomorrow's TSFM overlay (bin/emit_tsfm_refresh.sh):
#    NON-FATAL and bounded (30 min, EMIT_TSFM_TIMEOUT) — a failure prints a WARNING and never changes this
#    script's exit status. Kill switch: EMIT_NO_TSFM=1.
set -euo pipefail
cd "$(dirname "$0")/.."
# cron runs with a minimal PATH: make julia (juliaup) and uv (~/.local/bin) visible.
export PATH="$HOME/.juliaup/bin:$HOME/.local/bin:$PATH"
# Self-update (EMIT_NO_PULL=1 to skip). The production checkout drifted five
# days behind main in September 2026 and cron kept running a pre-fix emitter:
# the stats arm crashed every day ("Each group within index must be monotonic")
# while hybrid kept publishing, so the site showed a healthy physics+GBM line
# and a silently stale pure-stats line. Fast-forward only, and never on a dirty
# tree or a branch other than main — a mid-experiment checkout is left alone
# (it then keeps running its own code, which is the intended behaviour).
if [ -z "${EMIT_NO_PULL:-}" ] && [ -d .git ]; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$branch" = "main" ] && [ -z "$(git status --porcelain --untracked-files=no)" ]; then
        git fetch --quiet origin main && git merge --ff-only --quiet origin/main \
            && echo "checkout at $(git rev-parse --short HEAD) (fast-forwarded to origin/main)" \
            || echo "WARNING: could not fast-forward to origin/main — running $(git rev-parse --short HEAD)"
    else
        echo "WARNING: checkout on branch '$branch'$([ -n "$(git status --porcelain --untracked-files=no)" ] && echo ' with local changes') — self-update skipped, running $(git rev-parse --short HEAD)"
    fi
fi
# Both emitters need the cron environment, even when Julia/model-line preparation fails.
set -a; . ./.env; set +a
export EUPHEMIA_DATA_STORE=postgres

emit_model_lines() {
    # This function is called in an OR-list; Bash disables errexit there, so each
    # preparation command must explicitly return its original failure status.
    julia --project=. --startup-file=no -e 'using Pkg; Pkg.instantiate()' || return $?
    mkdir -p data/model_line_feats || return $?
    local feature_day
    feature_day=$(date -u -d "-6 days" +%F) || return $?
    if [ ! -f "data/model_line_feats/$feature_day.csv" ] && [ ! -f "data/backfill_books_cv37/$feature_day.parquet" ]; then
        julia --project=. bin/capture_book_features.jl "$feature_day" "data/model_line_feats/$feature_day.csv" || return $?
    fi
    local -a py=(python3)
    if ! python3 -c "import sklearn, joblib" 2>/dev/null; then
        py=(uv run --quiet --with scikit-learn,pandas,pyarrow,duckdb,joblib,psycopg2-binary python3)
    fi
    "${py[@]}" bin/emit_model_lines.py
}

rc=0
emit_model_lines || {
    rc=$?
    echo "WARNING: model-lines stage FAILED (exit $rc) — post-sim refresh remains independent" >&2
}
# 3. Post-sim TSFM refresh — after (and independent of) the model lines; their status is the exit status.
if [ "${EMIT_NO_TSFM:-0}" != "0" ]; then
    echo "TSFM refresh skipped (EMIT_NO_TSFM=$EMIT_NO_TSFM)"
else
    tsfm_timeout="${EMIT_TSFM_TIMEOUT:-1800}"
    timeout -k 60 "$tsfm_timeout" bash bin/emit_tsfm_refresh.sh || {
        st=$?; why=""
        if [ "$st" -eq 124 ] || [ "$st" -eq 137 ]; then why=", timed out after $tsfm_timeout s"; fi
        msg="WARNING: post-sim TSFM refresh FAILED (exit $st$why) — the site keeps the 06:30 pre-gate overlay; model lines unaffected"
        echo "$msg"; echo "$msg" >&2
    }
fi
exit $rc
