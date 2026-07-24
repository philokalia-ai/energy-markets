# Euphemia results browser (static SPA)

A dependency-free single-page app for browsing the model's ex-ante day-ahead price
predictions against settled actuals, per bidding zone: an hourly predicted-vs-actual
chart with a day picker, and an honest per-lead-time accuracy scoreboard
(MAE / bias / Pearson corr). Plain HTML/CSS/JS — no build step, no CDNs, no external
requests; it works fully offline from any static file server.

## Run locally

```bash
python3 -m http.server 8000 --directory web
# then open http://localhost:8000/
```

Any static file server works (the app only does `fetch('./data/...')`). Opening
`index.html` via `file://` will not work because browsers block `fetch` there.

## Where the data comes from

Since issue #152 the app tries three rungs in order (first that answers wins):

1. **Live Worker API** — `https://api.philokalia.ai/api/v1/…`,
   backed by R2 parquet the pipeline uploads seconds after each DB write
   (`bin/export_web_parquet.jl` + `workers/api/`). Fresh without a deploy.
   Disable with `?live=0`; point elsewhere with `?api=<base>`. When this rung
   serves the data, the footer shows a "data updated … ago" freshness badge
   from `/api/v1/manifest`.
2. **`./data/*.json`** — committed exports (permanent fallback + offline dev).
3. **`./fixtures/*.json`** — bundled synthetic fixtures (banner shown).

The app reads two kinds of JSON files:

- `data/scoreboard.json` — aggregate accuracy per zone × lead time × window
- `data/zones/<ZONE>.json` — per-day hourly predictions and actuals for one zone

These are produced by `bin/export_forecast_json.jl` and published as the
`forecast-data` artifact of the **"Daily ex-ante forecast"** GitHub workflow.
`web/data/` is git-ignored — drop an exported dataset there for local use:

```bash
# e.g. download the latest artifact into web/data/
gh run download --name forecast-data --dir web/data
```

When `data/` is missing (fresh checkout), the app falls back to the bundled
synthetic fixtures in `fixtures/` (marked `"fixture": true` in the JSON) and shows
a prominent **FIXTURE DATA** banner. Fixtures are for development only.

## Deploy

The whole `web/` directory is the deployable unit — host it on any static host
(GitHub Pages, nginx, S3, …). The repository ships
`.github/workflows/publish-results.yml` ("Publish results SPA"), which runs after
each successful "Daily ex-ante forecast" run (or manually via *Run workflow*),
downloads the `forecast-data` artifact into `web/data/`, and deploys `web/` to
GitHub Pages. **GitHub Pages must be enabled in the repository settings**
(Settings → Pages → Source: *GitHub Actions*) for the deploy step to succeed.

## Data contract

`data/scoreboard.json`:

```json
{"generated_utc": "2026-07-11T12:34:56Z", "code_version": 16,
 "zones": ["GR", "DE_LU", "..."],
 "scores": [{"zone": "GR", "lead_days": 1, "window": "all",
             "n_days": 37, "mae": 21.3, "bias": -2.2, "corr": 0.85}]}
```

`data/zones/<ZONE>.json` (days newest first, one entry per `(date, lead_days)`;
`actual` holds `null` for hours that have not settled yet):

```json
{"zone": "GR",
 "days": [{"date": "2026-07-12", "lead_days": 1,
           "prediction_made_utc": "2026-07-11T12:00:00Z",
           "hours": ["2026-07-12T00:00:00Z", "..."],
           "sim": [61.2], "actual": [58.9],
           "mae": 18.2, "bias": -3.1, "corr": 0.91}]}
```

Metric conventions: **bias** = simulated − actual (negative = model under-prices),
**MAE** in €/MWh, **corr** = Pearson correlation on hourly prices, all computed over
realized hours only. Predictions are frozen at `prediction_made_utc` and never
revised — this is a no-fit ex-ante counterfactual, so persistent residuals are
findings about the real market, not tuning targets.

## Regenerating fixtures

Fixtures were generated with a small deterministic script (3 zones × ~13 days ×
leads 1–2, including fully pending and partially settled days, with a scoreboard
aggregated from the same series). If the data contract changes, regenerate them to
match and keep `"fixture": true` set — the banner keys off that flag.

<!-- deploy-stamp: 2026-07-12T17:05Z -->
