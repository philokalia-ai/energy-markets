#!/usr/bin/env bash
# Pull the daily-refreshed living extract from the public data bucket and
# verify its checksum — the fastest way to run anything (evals, A/Bs,
# scenarios, backfills) on current data WITHOUT touching live Postgres.
#
#   bin/pull_live_extract.sh [dest]     # default data/extracts/euphemia-live.duckdb
#
# Then:  EUPHEMIA_DUCKDB_PATH=<dest> EUPHEMIA_DATA_STORE=duckdb \
#          EUPHEMIA_DUCKDB_READONLY=true julia --project=. ...
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-data/extracts/euphemia-live.duckdb}"
URL="https://data.philokalia.ai/euphemia-live.duckdb"

mkdir -p "$(dirname "$DEST")"
TMP="$DEST.download"
echo "⬇️  $URL"
curl -L --progress-bar -o "$TMP" "$URL"
EXPECT=$(curl -sL "$URL.sha256" | awk '{print $1}')
GOT=$(sha256sum "$TMP" | awk '{print $1}')
if [ "$EXPECT" != "$GOT" ]; then
    echo "❌ sha256 mismatch (mid-refresh download? retry in a minute)" >&2
    echo "   expected $EXPECT" >&2
    echo "   got      $GOT" >&2
    rm -f "$TMP"
    exit 1
fi
mv "$TMP" "$DEST"
echo "✅ $DEST ($(du -h "$DEST" | cut -f1), sha256 verified)"
