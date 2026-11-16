#!/bin/bash
# Guard for step 3 of bin/emit_model_lines.sh (the post-sim TSFM refresh): it must be non-fatal,
# bounded, kill-switchable, and never change the script's exit status (= the model-lines status).
# Runs the real script in a sandbox with stubbed julia/uv/python steps; no DB, no network.
#   bash test/scripts/test_emit_model_lines_tsfm_step.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/repo/bin" "$SB/home/.local/bin" "$SB/home/.juliaup/bin" "$SB/repo/data/model_line_feats"
cp "$ROOT/bin/emit_model_lines.sh" "$SB/repo/bin/"
touch "$SB/repo/.env" "$SB/repo/data/model_line_feats/$(date -u -d '-6 days' +%F).csv"
printf '#!/bin/bash\nexit 0\n' > "$SB/home/.juliaup/bin/julia"
# `uv run ... python3 bin/emit_model_lines.py` -> exit $MODEL_LINES_RC
cat > "$SB/home/.local/bin/uv" <<'EOF'
#!/bin/bash
echo "model lines (stub)"
echo "MODEL_LINES_STRICT_ASOF=${MODEL_LINES_STRICT_ASOF-unset} MODEL_LINES_REWRITE_PAST=${MODEL_LINES_REWRITE_PAST-unset}"
exit ${MODEL_LINES_RC:-0}
EOF
printf '#!/bin/bash\nexit 1\n' > "$SB/home/.local/bin/python3"   # no sklearn -> the uv branch
cat > "$SB/repo/bin/emit_tsfm_refresh.sh" <<'EOF'
#!/bin/bash
echo "tsfm refresh (stub: $TSFM_STUB)"
case "$TSFM_STUB" in ok) exit 0 ;; fail) exit 7 ;; hang) sleep 30 ;; esac
EOF
chmod +x "$SB"/home/.local/bin/* "$SB"/home/.juliaup/bin/* "$SB"/repo/bin/*

fails=0
run() {  # run <expect_rc> <expect_regex> [ENV=...]
    local want_rc=$1 want=$2; shift 2
    out=$(cd "$SB/repo" && env -i HOME="$SB/home" PATH=/usr/bin:/bin EMIT_NO_PULL=1 "$@" \
          bash bin/emit_model_lines.sh 2>&1); rc=$?
    if [ "$rc" = "$want_rc" ] && grep -qE "$want" <<<"$out"; then echo "ok   rc=$rc  $*"
    else echo "FAIL rc=$rc (want $want_rc, /$want/)  $*"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
}
run 0 "tsfm refresh \(stub: ok\)"                       TSFM_STUB=ok
run 0 "WARNING: post-sim TSFM refresh FAILED \(exit 7\)" TSFM_STUB=fail
run 0 "FAILED \(exit 124, timed out after 2 s\)"         TSFM_STUB=hang EMIT_TSFM_TIMEOUT=2
run 0 "TSFM refresh skipped"                            TSFM_STUB=fail EMIT_NO_TSFM=1
run 3 "tsfm refresh \(stub: ok\)"                       TSFM_STUB=ok MODEL_LINES_RC=3
run 3 "FAILED \(exit 7\)"                               TSFM_STUB=fail MODEL_LINES_RC=3
run 0 "tsfm refresh \(stub: ok\)"                       TSFM_STUB=ok EMIT_NO_TSFM=0
run 0 "MODEL_LINES_STRICT_ASOF=unset"                    TSFM_STUB=ok
run 0 "MODEL_LINES_STRICT_ASOF=0 MODEL_LINES_REWRITE_PAST=1" TSFM_STUB=ok MODEL_LINES_STRICT_ASOF=0 MODEL_LINES_REWRITE_PAST=1
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
