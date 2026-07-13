#!/usr/bin/env bash
# Canonical store for DuckDB extracts — pull/push named artifacts with
# integrity checking, so many consumers (CI runners, dev checkouts) share ONE
# refreshed "living" extract.
#
#   bin/extract_store.sh pull <name> <dest-path>
#   bin/extract_store.sh push <src-path> <name>
#
# Backends:
#   * LOCAL (default): the canonical dir $EUPHEMIA_EXTRACT_STORE
#     (default /opt/euphemia/extracts). Writes are atomic (cp to a temp file +
#     mv) and serialized with flock; every artifact has a .sha256 sidecar that
#     pull verifies after copying.
#   * S3-COMPATIBLE: set EXTRACT_S3_ENDPOINT and EXTRACT_S3_BUCKET (plus the
#     standard AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY) and the same
#     subcommands use `aws s3 cp --endpoint-url` instead. This is the future
#     Cloudflare R2 / seaweedfs hook — flipping backends is env-only, zero code
#     change.
#
# Examples:
#   bin/extract_store.sh pull euphemia-live.duckdb data/extracts/euphemia-live.duckdb
#   bin/extract_store.sh push data/extracts/euphemia-live.duckdb euphemia-live.duckdb
set -euo pipefail

STORE="${EUPHEMIA_EXTRACT_STORE:-/opt/euphemia/extracts}"
S3_ENDPOINT="${EXTRACT_S3_ENDPOINT:-}"
S3_BUCKET="${EXTRACT_S3_BUCKET:-}"

usage() {
    echo "usage: $0 pull <name> <dest-path> | $0 push <src-path> <name>" >&2
    exit 2
}

[ $# -eq 3 ] || usage
CMD="$1"

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# S3-compatible backend (R2 / seaweedfs / minio)
# ---------------------------------------------------------------------------
if [ -n "$S3_ENDPOINT" ] && [ -n "$S3_BUCKET" ]; then
    command -v aws >/dev/null || { echo "ERROR: aws CLI required for the S3 backend" >&2; exit 1; }
    case "$CMD" in
        pull)
            NAME="$2"; DEST="$3"
            mkdir -p "$(dirname "$DEST")"
            aws s3 cp --endpoint-url "$S3_ENDPOINT" "s3://$S3_BUCKET/$NAME" "$DEST" || {
                echo "ERROR: '$NAME' not found in s3://$S3_BUCKET ($S3_ENDPOINT)." >&2
                echo "Seed it once with: $0 push <local-extract> $NAME" >&2
                exit 1
            }
            if aws s3 cp --endpoint-url "$S3_ENDPOINT" "s3://$S3_BUCKET/$NAME.sha256" "$DEST.sha256" 2>/dev/null; then
                WANT="$(cut -d' ' -f1 "$DEST.sha256")"
                GOT="$(sha_of "$DEST")"
                [ "$WANT" = "$GOT" ] || { echo "ERROR: sha256 mismatch pulling $NAME" >&2; exit 1; }
                echo "pulled $NAME -> $DEST (sha256 OK)"
            else
                echo "pulled $NAME -> $DEST (no .sha256 sidecar in store — skipped verification)" >&2
            fi
            ;;
        push)
            SRC="$2"; NAME="$3"
            [ -f "$SRC" ] || { echo "ERROR: source not found: $SRC" >&2; exit 1; }
            SHA="$(sha_of "$SRC")"
            aws s3 cp --endpoint-url "$S3_ENDPOINT" "$SRC" "s3://$S3_BUCKET/$NAME"
            echo "$SHA  $NAME" | aws s3 cp --endpoint-url "$S3_ENDPOINT" - "s3://$S3_BUCKET/$NAME.sha256"
            echo "pushed $SRC -> s3://$S3_BUCKET/$NAME (sha256 $SHA)"
            ;;
        *) usage ;;
    esac
    exit 0
fi

# ---------------------------------------------------------------------------
# Local canonical-dir backend
# ---------------------------------------------------------------------------
if [ ! -d "$STORE" ]; then
    # One-time creation; passwordless sudo expected on the canonical host.
    if mkdir -p "$STORE" 2>/dev/null; then :; else
        echo "Creating $STORE (sudo)" >&2
        sudo mkdir -p "$STORE"
        sudo chown "$(id -un):$(id -gn)" "$STORE"
    fi
fi

LOCK="$STORE/.lock"

case "$CMD" in
    pull)
        NAME="$2"; DEST="$3"
        if [ ! -f "$STORE/$NAME" ]; then
            echo "ERROR: '$STORE/$NAME' does not exist." >&2
            echo "One-time seed: build an extract (bin/build_duckdb_extract.jl), then" >&2
            echo "  $0 push <local-extract.duckdb> $NAME" >&2
            exit 1
        fi
        mkdir -p "$(dirname "$DEST")"
        (
            flock -w 600 9
            cp "$STORE/$NAME" "$DEST.tmp"
            [ -f "$STORE/$NAME.sha256" ] && cp "$STORE/$NAME.sha256" "$DEST.sha256"
        ) 9>"$LOCK"
        mv "$DEST.tmp" "$DEST"
        if [ -f "$DEST.sha256" ]; then
            WANT="$(cut -d' ' -f1 "$DEST.sha256")"
            GOT="$(sha_of "$DEST")"
            [ "$WANT" = "$GOT" ] || { echo "ERROR: sha256 mismatch pulling $NAME" >&2; exit 1; }
            echo "pulled $NAME -> $DEST (sha256 OK)"
        else
            echo "pulled $NAME -> $DEST (no .sha256 sidecar in store — skipped verification)" >&2
        fi
        ;;
    push)
        SRC="$2"; NAME="$3"
        [ -f "$SRC" ] || { echo "ERROR: source not found: $SRC" >&2; exit 1; }
        SHA="$(sha_of "$SRC")"
        (
            flock -w 600 9
            cp "$SRC" "$STORE/$NAME.tmp"
            GOT="$(sha_of "$STORE/$NAME.tmp")"
            [ "$SHA" = "$GOT" ] || { rm -f "$STORE/$NAME.tmp"; echo "ERROR: copy corrupted pushing $NAME" >&2; exit 1; }
            mv "$STORE/$NAME.tmp" "$STORE/$NAME"
            echo "$SHA  $NAME" > "$STORE/$NAME.sha256"
        ) 9>"$LOCK"
        echo "pushed $SRC -> $STORE/$NAME (sha256 $SHA)"
        ;;
    *) usage ;;
esac
