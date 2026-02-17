# Metabase Integration

This directory contains SQL queries synced from the remote Metabase instance and tooling to manage them.

## Setup

Add your Metabase URL and API key to `.env` (already in `.gitignore`):

```
METABASE_URL=https://your-metabase-server:3000
METABASE_API_KEY=mb_your_api_key_here
```

To create an API key: **Metabase Admin > Settings > Authentication > API Keys**.

## Pulling Questions from Metabase

The pull script downloads SQL questions from a specific Metabase collection:

```bash
source .env
bash metabase/pull_questions.sh
```

By default it pulls from the `"energy"` collection. Override with:

```bash
export METABASE_COLLECTION="my-collection"
bash metabase/pull_questions.sh
```

This creates:
- `queries/<slug>.sql` — one file per SQL question, with a header comment
- `questions.json` — metadata mapping (question ID to filename)

## Editing Queries

1. Edit any `.sql` file in `queries/`
2. Copy the SQL into Metabase via **New Question > Native query**
3. Or update an existing question by pasting into Metabase's SQL editor

The pull script uses `questions.json` to track which files it manages. Hand-written files without entries in `questions.json` will not be overwritten on re-pull.

## Embedding Charts on the Website

Metabase charts can be embedded on the VitePress website via public sharing:

1. In Metabase, go to a saved question
2. Click **Sharing and embedding > Enable sharing**
3. Copy the public link UUID
4. Update `website/.vitepress/metabase.config.ts` with the UUID

The `MetabaseEmbed.vue` component renders these as responsive iframes — no Metabase login required for viewers.

## Directory Structure

```
metabase/
  pull_questions.sh       # Fetch SQL questions from remote Metabase
  questions.json          # Auto-generated metadata (question ID → filename)
  README.md               # This file
  queries/
    *.sql                 # SQL queries (pulled or hand-written)
```
