# euphemia-api — live data backend

> **Deploy gotcha:** always pass `--config workers/api/wrangler.toml` (the npm
> scripts do). The repo root has its own `wrangler.jsonc` (the static-assets
> worker) and wrangler resolves that one otherwise, deploying the wrong worker.

Cloudflare Worker serving the forecast data plane from the R2 bucket
`euphemia-web-data` (zstd parquet written by `bin/export_web_parquet.jl`, pushed
by `bin/web_data_push.sh` seconds after each pipeline DB write). It decodes the
parquet with [hyparquet](https://github.com/hyparam/hyparquet) (pure JS) and
emits the exact JSON shapes `web/app.js` consumes:

| Endpoint | Backing object | Shape |
|---|---|---|
| `GET /api/v1/zones/:zone` | `v1/zones/<zone>.parquet` | `web/data/zones/<zone>.json` |
| `GET /api/v1/books/:zone/:date` | `v1/books/<date>.parquet` (filtered to zone) | order-book ladder (see below) |
| `GET /api/v1/scoreboard` | `v1/scoreboard.parquet` | `web/data/scoreboard.json` |
| `GET /api/v1/map` | `v1/map.parquet` | `web/data/map.json` |
| `GET /api/v1/units` | `v1/units.parquet` | `{units:{<code>:{name,fuel,firm,zone}}}` (order-book join) |
| `GET /api/v1/flows/:date` | `v1/flows/<date>.parquet` | `{flows:{<tsIso>:[[src,sink,mw],…]}}` (trade wedge; record days only) |
| `GET /api/v1/manifest` | `v1/manifest.json` | `{updated_at, code_version, zones, row_counts, …}` |
| `GET /api/v1/book_methodology` | `v1/book_methodology.json` | Bid-methodology object — cost model, form constants, strategy glossary, provenance, cv-ledger (`bin/export_book_methodology.jl`) |
| `GET /api/v1/zone_strategies` | `v1/zone_strategies.json` | Resolved per-zone `ZoneProfile` calibration table (`bin/export_zone_strategies.jl`) |
| `GET /api/v1/boundaries` | `v1/boundaries.json` | Boundary-zones object — elastic boundary books + fixed-neighbour list + flow rule (`bin/export_boundaries.jl`) |
| `GET /api/v1/inputs/:zone` | `v1/inputs/<zone>.parquet` | RES/load driver + prediction panel (columnar series) |
| `GET /api/v1/inputs/reservoir` | `v1/inputs/reservoir.parquet` | `{zones:{<Z>:[{week_start,fill_ratio,dryness,…}]}}` |
| `GET /api/v1/inputs/manifest` | `v1/inputs/manifest.json` | Predictions-page plane (see `bin/export_prediction_inputs.jl`) |
| `GET /api/v1/inputs/scorecard` | `v1/inputs/scorecard.json` | Model-card VALID scores per (zone,target) + winner + collapse (see `bin/export_prediction_scorecard.jl`) |
| `GET /api/v1/inputs/skill` | `v1/inputs/skill.json` | Per-lead (D-1..D-7) input skill; warming-up until the vintage archive fills |

`.json`-backed rows are pass-throughs (no parquet decode) and also match with a
literal `.json` suffix. They 404 until explicitly published — no fixture
fallback, the SPA paints its honest "live data unavailable" state.

**Order-book ladder** (`/api/v1/books/:zone/:date`, `date` = `YYYY-MM-DD`):
`shapeBook` reads the per-day book parquet (all 39 zones — columns
`market_date, zone, ts, side, price, mw, owner, code_version`), keeps the
requested zone, and emits
`{zone, date, market_day_tz, code_version, owners:[…], hours:[…],
supply:[[[price,mw,ownerIdx],…] per hour], demand:[…]}` — supply ascending in
price (the merit order), demand descending, owners de-duplicated into an index
table so the biggest zones (FR ≈ 660 KB, DE_LU ≈ 470 KB) stay under 1 MB.
Clearing price and settled actual are NOT embedded; the SPA overlays them from
`zones/<zone>`. A missing day 404s.

Deployed at <https://api.philokalia.ai> (canonical custom domain, declared in
`wrangler.toml`; `web/app.js` defaults to it). The legacy `*.workers.dev` alias
stays live until `workers_dev = false`. The R2 objects themselves are the
stable public data API (`/v1/`; breaking schema changes bump `/v2/`) — see
"Public data API" in the repo README.

Caching: the edge Cache API entry is keyed on the R2 object's ETag, so a parquet
is decoded at most once per object version per colo; clients get
`ETag`/`If-None-Match` 304s and `Cache-Control: max-age=60`. CORS allows
`https://energy.philokalia.ai` and localhost dev.

## Dev / test / deploy

```bash
npm install

# Shape-equality test: requires bin/export_web_parquet.jl output in
# data/web/v1 AND bin/export_forecast_json.jl output in web/data,
# exported back-to-back against the same DB state.
npm test

# Order-book ladder shape test (merit-order ascending, owner-index integrity,
# <1MB per-zone-day budget). Needs a per-day book parquet: set
# BOOK_PARQUET=<file>. Without it, it tries two hard-coded local paths
# (data/backfill_books_cv27/2023-01-15.parquet, data/web/v1/books/2023-01-15.parquet);
# `data/` is git-ignored, so a fresh clone has neither and the test SKIPS
# (exit 0). Point it at a real book parquet if you want it to run.
npm run test:book

# Local dev against local R2 state (no credentials needed):
for f in $(cd ../../data/web/v1 && find . -type f | sed 's|^\./||'); do
  npx wrangler r2 object put "euphemia-web-data/v1/$f" \
    --file "../../data/web/v1/$f" --local --persist-to ../../.wrangler/state
done
npx wrangler dev --config wrangler.toml --persist-to ../../.wrangler/state

# Deploy (token needs the "Workers Scripts: Edit" permission):
CLOUDFLARE_API_TOKEN=... npm run deploy
```
