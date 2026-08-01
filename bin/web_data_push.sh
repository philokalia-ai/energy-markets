#!/usr/bin/env bash
# Upload the web-data parquet staging dir (bin/export_web_parquet.jl output)
# to the R2 bucket that backs the Cloudflare Worker API (workers/api/).
#
#   bin/web_data_push.sh [staging-root]     # default data/web
#
# Uploads $STAGING/v1/** to s3://$WEB_S3_BUCKET/v1/**. The manifest is
# uploaded LAST so a reader that sees the new manifest also sees the new
# parquet objects (each object is individually atomic on R2).
#
# Env (same pattern as extract_store.sh's S3 backend):
#   WEB_S3_ENDPOINT     R2 S3 API endpoint, e.g. https://<account>.r2.cloudflarestorage.com
#                       (falls back to EXTRACT_S3_ENDPOINT)
#   WEB_S3_BUCKET       bucket name (default euphemia-web-data)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   R2 credentials
#   AWS_DEFAULT_REGION  should be "auto" for R2 (set if unset)
set -euo pipefail

STAGING="${1:-data/web}"
ENDPOINT="${WEB_S3_ENDPOINT:-${EXTRACT_S3_ENDPOINT:-}}"
BUCKET="${WEB_S3_BUCKET:-euphemia-web-data}"
# R2 API tokens are bucket-scoped: the extract-bucket keys get AccessDenied on
# euphemia-web-data (measured 2026-07-27, first CI push). Prefer dedicated
# WEB_S3_* keys when present; fall back to the ambient AWS_* pair.
if [ -n "${WEB_S3_ACCESS_KEY_ID:-}" ] && [ -n "${WEB_S3_SECRET_ACCESS_KEY:-}" ]; then
    export AWS_ACCESS_KEY_ID="$WEB_S3_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$WEB_S3_SECRET_ACCESS_KEY"
fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

[ -n "$ENDPOINT" ] || { echo "ERROR: WEB_S3_ENDPOINT (or EXTRACT_S3_ENDPOINT) is not set" >&2; exit 1; }
[ -d "$STAGING/v1" ] || { echo "ERROR: staging dir $STAGING/v1 not found — run bin/export_web_parquet.jl first" >&2; exit 1; }
command -v aws >/dev/null || { echo "ERROR: aws CLI required" >&2; exit 1; }

# DELETE SCOPE (incident 2026-08-01): a root-level `sync --delete` on v1/
# mirrors THIS RUN's staging and deletes every key other publishers own —
# it wiped the 1,235 record book parquets (v1/books/, published 03:34,
# deleted 04:06) and would nightly delete v1/zone_strategies.json and any
# v1/inputs/ from a cycle whose non-fatal exporter skipped. The destructive
# sync is scoped to the ONE subtree this exporter fully owns (v1/zones —
# pruning deleted zones is the original intent); everything else is
# additive. Books/inputs/zone_strategies are never deleted here.
aws s3 sync --endpoint-url "$ENDPOINT" \
    --content-type "application/vnd.apache.parquet" \
    --delete \
    "$STAGING/v1/zones" "s3://$BUCKET/v1/zones"
for f in "$STAGING"/v1/*.parquet; do
    [ -e "$f" ] || continue
    aws s3 cp --endpoint-url "$ENDPOINT" \
        --content-type "application/vnd.apache.parquet" \
        "$f" "s3://$BUCKET/v1/$(basename "$f")"
done
# Predictions inputs (v1/inputs/): additive sync of parquets when this cycle
# produced them; the inputs manifest still goes LAST (below).
if [ -d "$STAGING/v1/inputs" ]; then
    aws s3 sync --endpoint-url "$ENDPOINT" \
        --exclude "*manifest.json" \
        --content-type "application/vnd.apache.parquet" \
        "$STAGING/v1/inputs" "s3://$BUCKET/v1/inputs"
fi
# Record books captured by backfills/daily flow: additive only.
if [ -d "$STAGING/v1/books" ]; then
    aws s3 sync --endpoint-url "$ENDPOINT" \
        --content-type "application/vnd.apache.parquet" \
        "$STAGING/v1/books" "s3://$BUCKET/v1/books"
fi
# Coupled cross-border flows for the trade wedge (record/backfill days only):
# additive, same non-destructive discipline as books.
if [ -d "$STAGING/v1/flows" ]; then
    aws s3 sync --endpoint-url "$ENDPOINT" \
        --content-type "application/vnd.apache.parquet" \
        "$STAGING/v1/flows" "s3://$BUCKET/v1/flows"
fi

aws s3 cp --endpoint-url "$ENDPOINT" \
    --content-type "application/json" \
    "$STAGING/v1/manifest.json" "s3://$BUCKET/v1/manifest.json"

# The Predictions data plane manifest (only present when the — non-fatal —
# prediction-inputs export ran this cycle), uploaded last for the same reason.
if [ -f "$STAGING/v1/inputs/manifest.json" ]; then
    aws s3 cp --endpoint-url "$ENDPOINT" \
        --content-type "application/json" \
        "$STAGING/v1/inputs/manifest.json" "s3://$BUCKET/v1/inputs/manifest.json"
fi

echo "pushed $STAGING/v1 -> s3://$BUCKET/v1 ($ENDPOINT)"
