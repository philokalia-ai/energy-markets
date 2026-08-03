# Euphemia results browser (static SPA)

A dependency-free single-page app for browsing the model's ex-ante day-ahead price
predictions against settled actuals, per bidding zone. Plain HTML/CSS/JS — no build
step, no CDNs, no external requests; it works fully offline from any static file
server.

**The global track switch (2026-08).** A header-level segmented control flips the
whole site between two tracks — a cross-cutting lens over every price-series
surface, not a separate view:

- **Predicted** (default) — our fitted inputs end-to-end (`input_mode` starting
  with `weather`; all model inputs, weather-based RES): "how much can you trust our
  model".
- **As announced** — the TSOs' announced D-1 inputs (`input_mode` `entsoe*`) run
  through the same bid-construction and solver: "the fair test of the bidding
  mechanism with inputs held at the official figures".

The switch state lives in the URL (`&track=`) + `localStorage` (default Predicted).
The gap between the tracks is itself a product: where announced beats predicted, a
**track-gap chip** ("announced MAE 12.1 · predicted 14.3 → input cost +2.2",
computed client-side) surfaces the measured cost of our inputs. Views where the
announced track has no meaning — the Predictions input-model cards, which ARE the
Predicted pillar — state that inline instead of silently ignoring the switch.
Both tracks are carried in every zones/scoreboard parquet (`input_mode`) and in
`map.parquet` (`track` column); `manifest.json` declares
`tracks:["predicted","announced"]` with per-track freshness.

Because every forecast uses the latest admissible inputs, the lead/D-n dimension is
collapsed everywhere to the **freshest forecast per delivery day** (deeper leads
were noise). Views:

- **Recent days** — a continuous ±5-day ribbon around now: the freshest forecast
  per delivery day for the ~5 settled days before the **"now" seam** (each with the
  settled **actual overlaid** and a per-day MAE·bias chip) and today + the next ~5
  upcoming days as forecast alone. The seam marks the last settled hour; retro
  (post data-reset) days appear inline with a reset note. Below it, "What we said,
  when" shows one delivery day's freshest forecast vs actual.
- **Map** — day-average price per bidding zone (Forecast / Actual metrics), plus
  an **Error %** metric: the exporter-computed load-weighted WAPE per zone-day
  (`err_pct`; Σ_h load_h·|fc_h − act_h| / Σ_h load_h·|act_h| × 100 — null until
  the day fully settles, or when the denominator is degenerate). Settled-only
  metrics on a day with no settled data render an explicit "Not settled yet"
  state — never a blank map, never synthetic numbers.
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
- **Scoreboard** — accuracy (MAE / bias / Pearson corr) by window on the selected
  track, with the track-gap chip on each MAE cell where both tracks scored.

## Run locally

```bash
python3 -m http.server 8000 --directory web
# then open http://localhost:8000/
```

Any static file server works (the app only fetches relative JSON). Opening
`index.html` via `file://` will not work because browsers block `fetch` there.

## Where the data comes from

The app has **one** data plane, live-only:

- **Live Worker API** — `https://api.philokalia.ai/api/v1/…`,
  backed by R2 parquet the pipeline uploads seconds after each DB write
  (`bin/export_web_parquet.jl` + `workers/api/`). Fresh without a deploy.
  Disable with `?live=0`; point elsewhere with `?api=<base>`. When this rung
  serves the data, the footer shows a "data updated … ago" freshness badge
  from `/api/v1/manifest`.

There is **no bundled-snapshot fallback** and there are **no runtime fixtures**.
The owner directive is absolute: synthetic/example data must never render as if
it were model output. When the API does not answer, every view paints an honest
**"Live data unavailable — retry"** state (the shared `liveUnavailable`
component in `app.js`, styled `.live-unavailable`) with a retry action — it
never substitutes a snapshot. The app-level bootstrap (the scoreboard) shows the
same state with a Retry that re-runs the bootstrap.

**Offline / local development.** Because there is no fixture rung, drive the app
against a local API instead: run the worker locally against local R2 state
(`workers/api` — `wrangler dev --persist-to …`, see that README) and open the
site with `?api=http://127.0.0.1:8787/api`. That renders real shapes with no
synthetic data.

The app reads two kinds of JSON files (from the live API):

- `scoreboard` — aggregate accuracy per zone × lead time × window
- `zones/<ZONE>` — per-day hourly predictions and actuals for one zone

The reference shapes are produced by `bin/export_forecast_json.jl` (which writes
`web/data/` locally — the directory is git-ignored; the exported shapes are
uploaded to R2 as parquet by `bin/export_web_parquet.jl`).

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

Both tracks are served (the global switch filters client-side): `input_mode`
starting with `weather` is the **Predicted** track, everything else (`entsoe*`) is
the **As announced** track. Where a zone has no day yet on the selected track, the
view shows an empty state and fills as that track's runs accumulate.

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

## No runtime fixtures

The shipped site carries **no** fixtures — the `web/fixtures/` directory and the
snapshot fallback rung were removed (owner directive: synthetic data must never
render as if it were model output). The only fixtures in the repo now live under
`workers/api/test/fixtures/` and are used solely by the worker test suite; they
are never served to a browser. To render the app offline, point it at a local
worker (`?api=…`, see "Data plane" above).

<!-- deploy-stamp: 2026-07-12T17:05Z -->
