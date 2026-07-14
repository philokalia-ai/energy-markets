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
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

[ -n "$ENDPOINT" ] || { echo "ERROR: WEB_S3_ENDPOINT (or EXTRACT_S3_ENDPOINT) is not set" >&2; exit 1; }
[ -d "$STAGING/v1" ] || { echo "ERROR: staging dir $STAGING/v1 not found — run bin/export_web_parquet.jl first" >&2; exit 1; }
command -v aws >/dev/null || { echo "ERROR: aws CLI required" >&2; exit 1; }

# Parquet objects first (sync prunes deleted zones), manifest last.
aws s3 sync --endpoint-url "$ENDPOINT" \
    --exclude "manifest.json" \
    --content-type "application/vnd.apache.parquet" \
    --delete \
    "$STAGING/v1" "s3://$BUCKET/v1"

aws s3 cp --endpoint-url "$ENDPOINT" \
    --content-type "application/json" \
    "$STAGING/v1/manifest.json" "s3://$BUCKET/v1/manifest.json"

echo "pushed $STAGING/v1 -> s3://$BUCKET/v1 ($ENDPOINT)"
