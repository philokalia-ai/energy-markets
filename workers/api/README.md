# euphemia-api — live data backend (issue #152)

Cloudflare Worker that serves the forecast data plane from the R2 bucket
`euphemia-web-data` (zstd parquet written by `bin/export_web_parquet.jl` and
pushed by `bin/web_data_push.sh` seconds after each pipeline DB write). It
decodes the parquet with [hyparquet](https://github.com/hyparam/hyparquet)
(pure JS) and emits the exact JSON shapes `web/app.js` consumes:

| Endpoint | Backing object | Shape |
|---|---|---|
| `GET /api/v1/zones/:zone` | `v1/zones/<zone>.parquet` | `web/data/zones/<zone>.json` |
| `GET /api/v1/scoreboard` | `v1/scoreboard.parquet` | `web/data/scoreboard.json` |
| `GET /api/v1/map` | `v1/map.parquet` | `web/data/map.json` |
| `GET /api/v1/manifest` | `v1/manifest.json` | `{updated_at, code_version, zones, row_counts, …}` |

Deployed at <https://api.philokalia.ai> (canonical; the legacy
`*.workers.dev` alias remains live during the migration and will be retired
by setting `workers_dev = false`). The R2 objects
themselves are the stable public data API (`/v1/`; breaking schema changes
bump `/v2/`) — see "Public data API" in the repo README.

Caching: the edge Cache API entry is keyed on the R2 object's ETag, so the
parquet is fetched + decoded at most once per object version per colo;
clients get `ETag`/`If-None-Match` 304s and `Cache-Control: max-age=60`.
CORS allows `https://energy.philokalia.ai` and localhost dev.

## Dev / test / deploy

**Config resolution gotcha:** the repo root has a `wrangler.jsonc` (the
static site itself). Always pass `--config wrangler.toml` (the npm scripts
do), otherwise wrangler resolves the ROOT config and serves the site assets.

```bash
npm install

# Shape-equality test: requires bin/export_web_parquet.jl output in
# data/web/v1 AND bin/export_forecast_json.jl output in web/data,
# exported back-to-back against the same DB state.
npm test

# Local dev against local R2 state (no credentials needed):
for f in $(cd ../../data/web/v1 && find . -type f | sed 's|^\./||'); do
  npx wrangler r2 object put "euphemia-web-data/v1/$f" \
    --file "../../data/web/v1/$f" --local --persist-to ../../.wrangler/state
done
npx wrangler dev --config wrangler.toml --persist-to ../../.wrangler/state

# Deploy (token needs the "Workers Scripts: Edit" permission):
CLOUDFLARE_API_TOKEN=... npm run deploy
```

## Custom-domain route

The Worker is reachable on workers.dev. To serve it under
`energy.philokalia.ai/api/*` (same-origin for the SPA), add a zone route —
dashboard: *Workers & Pages → euphemia-api → Settings → Domains & Routes →
Add route* `energy.philokalia.ai/api/*` on the `philokalia.ai` zone — or
uncomment in `wrangler.toml`:

```toml
routes = [{ pattern = "energy.philokalia.ai/api/*", zone_name = "philokalia.ai" }]
```

and redeploy (needs a token with Zone-scoped `Workers Routes: Edit` on
`philokalia.ai`). Until then `web/app.js` points at the workers.dev URL.
