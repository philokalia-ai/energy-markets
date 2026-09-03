# Euphemia results browser (static SPA)

A dependency-free single-page app for browsing the model's ex-ante day-ahead
price predictions against settled actuals, per bidding zone. Plain HTML/CSS/JS
— no build step, no CDNs, no external requests.

```bash
python3 -m http.server 8000 --directory web   # then open http://localhost:8000/
```

Any static file server works; `file://` will not, because browsers block
`fetch` there. Production is Cloudflare (energy.philokalia.ai) serving `web/`
from `main`.

## The global track switch

A header-level segmented control flips the whole site between two tracks — a
lens over every price surface, not a separate view:

- **Predicted** (default) — our fitted inputs end-to-end (`input_mode` starting
  with `weather`): "how much can you trust our model".
- **As announced** — the TSOs' announced D-1 inputs (`input_mode` `entsoe*`)
  through the same bid construction and solver: "the fair test of the bidding
  mechanism with inputs held at the official figures".

State lives in the URL (`&track=`) + `localStorage`. The gap between tracks is
itself a product: where announced beats predicted, a **track-gap chip**
("announced MAE 12.1 · predicted 14.3 → input cost +2.2") surfaces the measured
cost of our inputs. Views where the announced track has no meaning (the
Predictions input-model cards, which *are* the Predicted pillar) say so inline.

Because every forecast uses the latest admissible inputs, the lead/D-n
dimension is collapsed everywhere to the **freshest forecast per delivery day**.

## Views

- **Recent days** — a continuous ±5-day ribbon around now: settled days carry
  the actual overlaid with a per-day MAE·bias chip; today and the next ~5 days
  are forecast alone. The seam marks the last settled hour. Two statistical
  **model lines** (hybrid and pure-stats GBM) overlay the physics as dashed
  series — see `models.html` for what they are and what they can't do.
- **Map** — day-average price per zone (Forecast / Actual), plus **Error %**:
  the exporter-computed load-weighted WAPE per zone-day (null until the day
  settles). A settled-only metric on an unsettled day renders an explicit
  "Not settled yet" state — never a blank map, never synthetic numbers.
- **Solver** — how the 39-zone coupled auction produces the prices: the
  GME/OMIE €0.00 validation, "a price is a dual", an interactive two-zone toy
  (drag the ATC slider: islanded → congested → coupled), a real congested
  border-hour from `/api/v1/flows`, and the two-pass anchor click-through.
- **Predicting RES & loads** — the open input model. A map colours the 5 pilot
  zones (GR, ES, DE_LU, SE2, NL) by tomorrow's predicted midday RES coverage
  and flags collapse risk; clicking one opens the driver time series
  (temperature, GHI, cloud, pressure, 100 m wind, reservoir) aligned with the
  prediction and the actual. Recipe: [docs/predictions.md](../docs/predictions.md).
- **Zone explorer** — per-day hourly forecast vs actual.
- **Order book** — per zone × market day × hour, the merit-order supply ladder
  by ascending offer price (x = cumulative MW, y = €/MWh), coloured by owner,
  with dashed markers where the clearing price and the settled actual landed.
  Hour slider + play-through-day.
- **Scoreboard** — MAE / bias / Pearson corr by window on the selected track,
  with the track-gap chip on each cell where both tracks scored.
- **Case studies** and **models** — scenario results and the two statistical
  reference lines, as standalone pages.

## Data plane

**One plane, live only:** the Worker API at `https://api.philokalia.ai/api/v1/…`,
backed by R2 parquet the pipeline uploads seconds after each DB write
(`bin/export_web_parquet.jl` + [`workers/api/`](../workers/api/README.md)).
Fresh without a deploy. Disable with `?live=0`, point elsewhere with
`?api=<base>`; the footer shows a freshness badge from `/api/v1/manifest`.

There is **no bundled snapshot and there are no runtime fixtures**. The owner
directive is absolute: synthetic data must never render as if it were model
output. When the API does not answer, every view paints an honest **"Live data
unavailable — retry"** state (the shared `liveUnavailable` component) — it never
substitutes a snapshot. To develop offline, run the worker locally
(`wrangler dev --persist-to …`) and open the site with
`?api=http://127.0.0.1:8787/api`. The only fixtures in the repo live under
`workers/api/test/fixtures/` and are never served to a browser.

## Data contracts

`scoreboard` — aggregate accuracy per zone × lead × window × track.
`zones/<ZONE>` — per-day hourly predictions and actuals (days newest first;
`actual` is `null` for hours that have not settled):

```json
{"zone": "GR",
 "days": [{"date": "2026-08-26", "lead_days": 1,
           "prediction_made_utc": "2026-08-25T06:40:00Z",
           "hours": ["2026-08-26T00:00:00Z", "…"],
           "sim": [61.2], "actual": [58.9],
           "mae": 18.2, "bias": -3.1, "corr": 0.91}]}
```

`GET /api/v1/books/:zone/:date` — the merit-order ladder. Per hour, `supply` is
ascending in offer price and `demand` descending; each order is
`[price €/MWh, mw, ownerIdx]` indexing `owners`. The clearing price and settled
actual are not in the book — the SPA overlays them from `zones/<zone>`.

`GET /api/v1/inputs/:zone` — the per-zone driver + prediction panel (columnar
series, hours ascending: `temp_c`, `ghi_wm2`, `cloud_pct`, `pressure_hpa`,
`wind100_ms`, `pred_*`, `ref_*`, `act_*`, `vintage_lag`).
`GET /api/v1/inputs/reservoir` — weekly fill ratio and dryness per hydro zone.
`GET /api/v1/inputs/manifest` — freshness, column dictionary, and the per-zone
midday RES-coverage summary the map colours by.

Every payload carries the producing `code_version` (currently 37). Metric
conventions: **bias** = simulated − actual (negative = model under-prices),
**MAE** in €/MWh, **corr** = Pearson on hourly prices, all over realized hours
only. Predictions are frozen at `prediction_made_utc` and never revised — this
is a no-fit ex-ante counterfactual, so persistent residuals are findings about
the real market, not tuning targets.

Reference JSON shapes are produced by `bin/export_forecast_json.jl`; the R2
parquet by `bin/export_web_parquet.jl` and `bin/export_prediction_inputs.jl`.
