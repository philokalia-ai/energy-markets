# Euphemia results browser (static SPA)

A dependency-free single-page app for browsing the model's ex-ante day-ahead price
predictions against settled actuals, per bidding zone. Plain HTML/CSS/JS — no build
step, no CDNs, no external requests; it works fully offline from any static file
server.

**One track, freshest forecast (2026-07-31).** The site shows a single forecast
track — the **ex-ante weather track** (`input_mode` starting with `weather`; all
model inputs, weather-based RES). The reference (`entsoe`) track stays in the data
plane for research but is hidden from the UI. Because every forecast uses the latest
admissible weather, the lead/D-n dimension is collapsed everywhere to the **freshest
forecast per delivery day** (deeper leads were noise). Views:

- **Recent days** — a continuous ±5-day ribbon around now: the freshest forecast
  per delivery day for the ~5 settled days before the **"now" seam** (each with the
  settled **actual overlaid** and a per-day MAE·bias chip) and today + the next ~5
  upcoming days as forecast alone. The seam marks the last settled hour; retro
  (post data-reset) days appear inline with a reset note. Below it, "What we said,
  when" shows one delivery day's freshest forecast vs actual.
- **Map** — day-average price per bidding zone.
- **Solver** — pillar 1: how the 39-zone coupled auction produces those prices.
  The GME/OMIE €0.00 validation, "a price is a dual", an interactive two-zone toy
  (drag the ATC slider to walk islanded → congested → coupled — the clear is a
  closed-form merit crossing in JS), a real congested border-hour opened live from
  `/api/v1/flows` + `/api/v1/zones`, and the two-pass anchor click-through.
- **Predicting RES & loads** — the open input model. A Europe map colours each of
  the 5 pilot zones (GR, ES, DE_LU, SE2, NL) by tomorrow's predicted **midday RES
  coverage** (predicted wind+solar ÷ predicted load) and flags collapse-risk zones;
  click a zone for the KNOBS panel — small-multiple driver time series (temperature,
  GHI, cloud, pressure, 100 m wind, reservoir state) aligned with the prediction and
  the settled actual, plus a plain-language methodology. Data comes from
  `GET /api/v1/inputs/{manifest,reservoir,:zone}` (see `workers/api/` and
  `bin/export_prediction_inputs.jl`); the open recipe is
  [docs/predictions.md](../docs/predictions.md).
- **Zone explorer** — per-day hourly forecast vs actual, freshest weather day per date.
- **Order book** — per zone × market day × hour, the merit-order supply ladder
  stacked by ascending offer price (x = cumulative MW, y = €/MWh), coloured by
  owner, with a dashed marker where the **clearing price** landed ("πού έκατσε η
  μπίλια") and a second marker at the settled actual. Hour slider + play-through-day.
  Ladder data comes from `GET /api/v1/books/:zone/:date` (see `workers/api/`).
- **Scoreboard** — weather-track accuracy (MAE / bias / Pearson corr) by window.

## Run locally

```bash
python3 -m http.server 8000 --directory web
# then open http://localhost:8000/
```

Any static file server works (the app only fetches relative JSON). Opening
`index.html` via `file://` will not work because browsers block `fetch` there.

## Where the data comes from

The app tries two rungs in order (first that answers wins):

1. **Live Worker API** — `https://api.philokalia.ai/api/v1/…`,
   backed by R2 parquet the pipeline uploads seconds after each DB write
   (`bin/export_web_parquet.jl` + `workers/api/`). Fresh without a deploy.
   Disable with `?live=0`; point elsewhere with `?api=<base>`. When this rung
   serves the data, the footer shows a "data updated … ago" freshness badge
   from `/api/v1/manifest`. This is the SOLE live data plane — the committed
   `./data` rung and the daily bot commits that fed it were retired in July
   2026 (single-publication-path cleanup).
2. **`./fixtures/*.json`** — bundled snapshot (offline dev + last-resort;
   banner shown).

The app reads two kinds of JSON files:

- `data/scoreboard.json` — aggregate accuracy per zone × lead time × window
- `data/zones/<ZONE>.json` — per-day hourly predictions and actuals for one zone

These are produced by `bin/export_forecast_json.jl` (which still writes
`web/data/` locally — the directory is git-ignored; the exported shapes are
uploaded to R2 as parquet by `bin/export_web_parquet.jl`).

Without the live API (fresh checkout, offline), the app falls back to the
bundled fixtures in `fixtures/` (marked `"fixture": true` in the JSON) and
shows a prominent **FIXTURE DATA** banner. Fixtures are for development only.

## Deploy

The whole `web/` directory is the deployable unit — host it on any static
host. Production is Cloudflare (energy.philokalia.ai) serving `web/` from
`main`, with all data coming live from the R2-backed Worker API. (The former
GitHub Pages mirror and its `publish-results.yml` workflow were retired in
July 2026 — one site, one data plane.)

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

Only the **ex-ante weather track** is shown (`input_mode` starting with
`weather`); the reference (`entsoe`) track is filtered out in the UI. Where a zone
has no weather-track day yet, the view shows an empty state and fills as the daily
weather runs accumulate.

## Order-book data contract

`GET /api/v1/books/:zone/:date` (worker route; per-day book parquet filtered to
the zone) returns the merit-order ladder:

```json
{"zone": "GR", "date": "2026-07-27", "market_day_tz": "Europe/Athens",
 "code_version": 27, "owners": ["RES", "IMPORT", "29WGU-…", "…"],
 "hours": ["2026-07-26T21:00:00Z", "…"],
 "supply": [[[2.85, 163.4, 3], [5.0, 96.5, 4], "…"], "…"],
 "demand": [[[3000.0, 5182.2, 0], "…"], "…"]}
```

Per hour, `supply` is ascending in offer price (the merit order) and `demand`
descending; each order is `[price €/MWh, mw, ownerIdx]` where `ownerIdx` indexes
`owners`. The clearing price and settled actual are NOT in the book — the SPA
overlays them from `zones/<zone>` (`sim`/`actual`) by aligning the hour index.

## Predictions data contract (`/api/v1/inputs/…`)

`GET /api/v1/inputs/:zone` — the per-zone driver + prediction panel (columnar
series, hours ascending):

```json
{"zone": "GR", "market_day_tz": "Europe/Athens",
 "src": {"solar": "ml", "wind": "pack", "load": "ml"},
 "hours": ["2026-07-19T00:00:00Z", "…"],
 "series": {"temp_c": [27.6], "ghi_wm2": [0.0], "cloud_pct": [0.24],
            "pressure_hpa": [943.0], "wind100_ms": [10.2],
            "pred_solar_mw": [0.0], "pred_wind_mw": [525.4], "pred_res_mw": [525.4],
            "pred_load_mw": [5703.8], "ref_solar_mw": [52.5], "ref_wind_mw": [577.5],
            "ref_load_mw": [5610.0], "act_solar_mw": [77.0], "act_wind_mw": [500.5],
            "act_load_mw": [5561.5], "vintage_lag": [1]}}
```

`GET /api/v1/inputs/reservoir` — `{zones: {"<Z>": [{week_start, iso_year, iso_week,
stored_energy_mwh, fill_ratio, dryness}, …]}}` (weeks ascending). `GET
/api/v1/inputs/manifest` — freshness + the column dictionary + the per-zone
freshest-day midday RES-coverage summary the map colours by. Produced by
`bin/export_prediction_inputs.jl` (the additive `v1/inputs/` contract); the open
model recipe is [docs/predictions.md](../docs/predictions.md).

## Regenerating fixtures

Fixtures (`fixtures/`, `"fixture": true`) are development-only. They are labelled
`input_mode: "weather"` so the offline fallback exercises the weather-only UI, and
carry one GR order-book fixture (`fixtures/books/GR/<date>`, no extension) so the
order-book view renders offline. If the data contract changes, regenerate them to
match and keep `"fixture": true` set — the banner keys off that flag.

<!-- deploy-stamp: 2026-07-12T17:05Z -->
