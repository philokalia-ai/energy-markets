#!/bin/bash
# Post-sim Timestral refresh of the TSFM overlay (step 3 of bin/emit_model_lines.sh, crontab
# 10:40 UTC; called there under `timeout`, non-fatal, kill-switch EMIT_NO_TSFM=1).
#
# The 06:30 UTC daily-forecast workflow publishes the pre-gate vintage (prices only). By 10:40 the
# lead-1 weather-track sim of tomorrow is frozen, so this re-issues the overlay with the sim as a
# known-future covariate (`--mode postsim`, issue_utc = the latest sim vintage made by the D-1
# 10:00 UTC gate). It writes a separate vintage row set into simulations.tsfm_overlay; the
# exporters serve the latest-issue vintage per zone-day, so this one wins once it is exported.
#
#   bin/emit_tsfm_refresh.sh                 # production: --delivery tomorrow --mode postsim --write
#   bin/emit_tsfm_refresh.sh <emitter args>  # anything else (e.g. a dry run on the extract)
#
# Env: TSFM_ARM (default timestral-209m = arm B: prices + lead-1 sim; the physics arm C
#      timestral-209m-phys stays opt-in), TSFM_THREADS (default 4), TSFM_VENV (default
#      .venv-overlay), HF_HOME (default data/hf: weights cache, ~0.9 GB, git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

REQ=bin/requirements-overlay.txt
VENV="${TSFM_VENV:-.venv-overlay}"
STAMP="$VENV/.requirements.sha256"
want=$(sha256sum "$REQ" | cut -d' ' -f1)
# (Re)build the venv when it is missing or the pinned requirements changed since it was built.
# The stamp is written only after a successful install, so a half-built venv is rebuilt next run.
if [ ! -x "$VENV/bin/python" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$want" ]; then
    case "$VENV" in ""|/|.|..) echo "refusing TSFM_VENV='$VENV'" >&2; exit 2 ;; esac
    echo "bootstrapping $VENV from $REQ (sha256 ${want:0:12})"
    rm -rf "$VENV"
    uv venv --quiet --python 3.12 "$VENV"
    uv pip install --quiet --python "$VENV/bin/python" --index-strategy unsafe-best-match -r "$REQ"
    echo "$want" > "$STAMP"
fi

export HF_HOME="${HF_HOME:-$PWD/data/hf}"
export TSFM_ARM="${TSFM_ARM:-timestral-209m}"
mkdir -p "$HF_HOME"
[ $# -gt 0 ] || set -- --delivery tomorrow --mode postsim --write
echo "TSFM refresh: arm $TSFM_ARM, $VENV ($("$VENV/bin/python" -V 2>&1)), args: $*"
exec "$VENV/bin/python" bin/emit_tsfm_overlay.py --threads "${TSFM_THREADS:-4}" "$@"
