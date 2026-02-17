#!/usr/bin/env bash
#
# Pull SQL questions from a remote Metabase instance into local files.
#
# Prerequisites: curl, jq
# Usage:
#   source .env
#   bash metabase/pull_questions.sh
#
# Environment variables:
#   METABASE_URL          — Base URL of your Metabase instance (required)
#   METABASE_USER         — Metabase login email (required)
#   METABASE_PASSWORD     — Metabase login password (required)
#   METABASE_COLLECTION   — Collection name to pull from (default: "energy")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"
METADATA_FILE="$SCRIPT_DIR/questions.json"
COLLECTION_NAME="${METABASE_COLLECTION:-energy}"

# --- Validation ---

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not installed." >&2
    exit 1
  fi
done

for var in METABASE_URL METABASE_USER METABASE_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set. Add it to .env and run: source .env" >&2
    exit 1
  fi
done

# Strip trailing slash from URL
METABASE_URL="${METABASE_URL%/}"

echo "Connecting to Metabase at $METABASE_URL ..."

# --- Authenticate ---

SESSION_TOKEN=$(curl -sf "$METABASE_URL/api/session" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$METABASE_USER\", \"password\": \"$METABASE_PASSWORD\"}" \
  | jq -r '.id')

if [[ -z "$SESSION_TOKEN" || "$SESSION_TOKEN" == "null" ]]; then
  echo "Error: Failed to authenticate with Metabase." >&2
  exit 1
fi

echo "Authenticated successfully."

auth_header="X-Metabase-Session: $SESSION_TOKEN"

# --- Find collection ---

echo "Looking for collection: $COLLECTION_NAME ..."

COLLECTION_ID=$(curl -sf "$METABASE_URL/api/collection" \
  -H "$auth_header" \
  | jq -r --arg name "$COLLECTION_NAME" \
    '.[] | select(.name == $name) | .id' \
  | head -1)

if [[ -z "$COLLECTION_ID" || "$COLLECTION_ID" == "null" ]]; then
  echo "Error: Collection '$COLLECTION_NAME' not found." >&2
  echo "Available collections:" >&2
  curl -sf "$METABASE_URL/api/collection" -H "$auth_header" \
    | jq -r '.[].name' >&2
  exit 1
fi

echo "Found collection '$COLLECTION_NAME' (ID: $COLLECTION_ID)."

# --- List items in collection ---

ITEMS=$(curl -sf "$METABASE_URL/api/collection/$COLLECTION_ID/items?models=card" \
  -H "$auth_header")

CARD_IDS=$(echo "$ITEMS" | jq -r '.data[]? // .[]? | select(.model == "card") | .id')

if [[ -z "$CARD_IDS" ]]; then
  echo "No questions found in collection '$COLLECTION_NAME'."
  exit 0
fi

CARD_COUNT=$(echo "$CARD_IDS" | wc -l | tr -d ' ')
echo "Found $CARD_COUNT question(s). Fetching details..."

# --- Fetch each card and save SQL ---

mkdir -p "$QUERIES_DIR"

# Initialize metadata JSON
echo "{}" > "$METADATA_FILE"

pulled=0

for CARD_ID in $CARD_IDS; do
  CARD=$(curl -sf "$METABASE_URL/api/card/$CARD_ID" -H "$auth_header")

  QUERY_TYPE=$(echo "$CARD" | jq -r '.dataset_query.type // empty')

  if [[ "$QUERY_TYPE" != "native" ]]; then
    NAME=$(echo "$CARD" | jq -r '.name // "unknown"')
    echo "  Skipping '$NAME' (ID: $CARD_ID) — not a native SQL query."
    continue
  fi

  NAME=$(echo "$CARD" | jq -r '.name // "untitled"')
  DESCRIPTION=$(echo "$CARD" | jq -r '.description // ""')
  DISPLAY=$(echo "$CARD" | jq -r '.display // "table"')
  SQL=$(echo "$CARD" | jq -r '.dataset_query.native.query // empty')

  if [[ -z "$SQL" ]]; then
    echo "  Skipping '$NAME' (ID: $CARD_ID) — empty SQL."
    continue
  fi

  # Generate slug from name: lowercase, replace non-alphanumeric with hyphens, trim
  SLUG=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  FILENAME="${SLUG}.sql"

  # Write SQL file with header comment
  {
    echo "-- Metabase Question: $NAME"
    echo "-- ID: $CARD_ID"
    if [[ -n "$DESCRIPTION" ]]; then
      echo "-- Description: $DESCRIPTION"
    fi
    echo "-- Visualization: $DISPLAY"
    echo "-- Pulled: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "--"
    echo ""
    echo "$SQL"
  } > "$QUERIES_DIR/$FILENAME"

  # Update metadata JSON
  TMP=$(mktemp)
  jq --arg id "$CARD_ID" --arg file "$FILENAME" --arg name "$NAME" \
    '. + {($id): {"filename": $file, "name": $name}}' \
    "$METADATA_FILE" > "$TMP" && mv "$TMP" "$METADATA_FILE"

  echo "  Saved: queries/$FILENAME"
  pulled=$((pulled + 1))
done

echo ""
echo "Done. Pulled $pulled SQL question(s) to $QUERIES_DIR/"
echo "Metadata saved to $METADATA_FILE"
