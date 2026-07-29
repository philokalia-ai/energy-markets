# Data dictionary — the public data artifact (`euphemia-data-v1.1`)

What is inside `euphemia-data-v1.1.tar.zst` (from <https://data.philokalia.ai>),
column by column, with explicit provenance per table. The same tables, with the
same names, exist in the maintainers' Postgres and in the living extract — this
dictionary applies to all three.

**Conventions that apply everywhere:**

- **Every timestamp is naive UTC** (the extract builder converts all
  `timestamptz` columns; the original Postgres stores UTC too).
- Tables are physically **sorted by (zone, date)** (the per-unit output table
  by `(month, unit, date)`) so DuckDB row-group zonemaps prune per-zone /
  per-day scans — filter on the zone and a timestamp range for fast queries.
- **Zone identifiers**: `*_map_code` columns carry the short bidding-zone
  codes used throughout this repo (`GR`, `DE_LU`, `IT-NORTH`, …);
  `*_area_code` columns carry ENTSO-E EIC codes (`10YGR-HTSO-----Y`).
  **Always join/filter on the map codes.**
- **`area_type_code`**: filter with `LIKE 'BZN%'` (values `BZN`, `BZN/CTA`,
  `BZN/CTY`, `BZN/CTA/CTY` — the combined values exist where a bidding zone
  coincides with a control area or country, and dropping them loses zones).
- `resolution_code` is the ENTSO-E market-time-unit of the row: `PT60M`,
  `PT30M`, `PT15M`. Mixed within most tables — aggregate to the hour by
  averaging MW values (MW is power; the hourly mean preserves energy).
- `MANIFEST.json` carries rows / bytes / sha256 per table; `SHA256SUMS`
  verifies every file.

## Data sources, explicitly

| Source | Tables | Terms |
|---|---|---|
| **ENTSO-E Transparency Platform** (transparency.entsoe.eu), pulled by the maintainers' ETL | all `entsoe.*` | Redistributed with attribution under the [TP terms of use](https://transparency.entsoe.eu/content/static_content/Static%20content/terms%20and%20conditions/terms%20and%20conditions.html); free reuse with source attribution |
| **Yahoo Finance** via `yfinance` | `yfinance.ttf_f` (ticker `TTF=F`, Dutch TTF natural-gas front-month futures, €/MWh), `yfinance.eua_co2` (ticker `CO2.L`, SparkChange Physical Carbon EUA ETC — physically holds EU Allowances, so its close tracks EUA spot ~1:1) | market-data quotes; used as daily reference closes |

## Table by table

### `entsoe.energy_prices` — day-ahead auction results (2.47M rows)

TP dataset: *Energy Prices*. **Used for validation only** — never as a model
input (the no-fit rule).

- Grain: one row per (`map_code`, `date_time_utc`, `contract_type`,
  `sequence`).
- `price_currency_mwh` (€/MWh), `currency` (`EUR`), `contract_type` — filter
  `= 'Day-ahead'`.
- ⚠️ **`sequence` revisions**: some zones publish multiple revisions of the
  same MTU with *different prices* (e.g. AT). Dedup to the highest
  `sequence` (tie-break: latest `update_time_utc`) before any aggregation —
  this is the committed eval convention (`test/scripts/eu_eval_metrics.jl`).
- ⚠️ Resolutions are mixed and changed over time (many zones moved to PT15M
  in Oct 2025) — compare models at the hourly mean.

### `entsoe.day_ahead_total_load_forecast` — D-1 load forecast (2.73M rows)

TP dataset: *Day-ahead Total Load Forecast*. The model's demand input
(published before the auction — D-1-legal).

- Grain: (`area_map_code`, `date_time_utc`); `total_load_mw`.

### `entsoe.generation_forecasts_for_wind_and_solar` — RES forecasts (5.69M rows)

TP dataset: *Generation Forecasts for Wind and Solar*. The model's RES input.

- Grain: (`area_map_code`, `date_time_utc`, `production_type` ∈
  Solar / Wind Onshore / Wind Offshore).
- Three forecast vintages per row: `day_ahead_generation_forecast_mw` (what
  the model uses — D-1-legal), `intraday_…`, `current_…`.

### `entsoe.physical_flows` — realized cross-border flows (20.3M rows)

TP dataset: *Cross-Border Physical Flows*. Used for the observed-flow
injections (backward-looking runs) and as the target/history of the ex-ante
flow rule (see README "How it works" §3).

- Grain: one **directed** row per (`out_area_map_code` → `in_area_map_code`,
  `date_time_utc`); `flow_mw` ≥ 0. Both directions of a border can be nonzero
  in the same interval (gross flows).
- ⚠️ Some counterparty codes carry an `_IPS` suffix (post-synchronization
  Baltic aliases) and some are country aggregates (`IT`, `DK`, `SE`, `NO`,
  `GB`) rather than bidding zones — the loader normalizes/dedups these
  (`src/merit_order/flows_imports.jl`).

### `entsoe.offered_transfer_capacities_implicit` / `_explicit` — offered ATC (21.3M / 11.9M rows)

TP datasets: *Offered Transfer Capacities* for implicit (market-coupling) and
explicit allocations. The multi-zone network build takes the union of both
(`enrich_network=true`).

- Grain: directed (`out_map_code` → `in_map_code`, `date_time_utc`,
  `contract_type`); `capacity_mw`.
- ⚠️ Note the column names: these tables use `out_map_code`/`in_map_code`
  (not `*_area_map_code` as in `physical_flows`).
- ⚠️ Flow-based borders (Core FBMC, Nordic-internal) publish "offered ATC"
  values that do NOT bound the real flow-based domain — the model drops them
  from the endogenous network on purpose (`flow_based_drop_borders`).

### `entsoe.aggregated_generation_per_type` — per-type actual output (33.3M rows)

TP dataset: *Actual Generation per Production Type*.

- Grain: (`area_map_code`, `date_time_utc`, `production_type` — 21 types);
  `actual_generation_output_mw`, `actual_consumption_mw` (pumping/charging).
- Feeds fleet truthing (trailing p95 per type), hydro availability, and the
  type-level truth-up — strictly historical windows only.

### `entsoe.actual_generation_output_per_generation_unit` — per-unit output (125.2M rows, the big one)

TP dataset: *Actual Generation per Generation Unit*.

- Grain: (`generation_unit_code`, `date_time_utc`); `actual_generation_output_mw`.
- Used for: generator parameter inference (ramps, p_min, up/down times),
  initial conditions, recent-generation liveness checks, and the
  stale-outage override.

### `entsoe.production_and_generation_units` — the unit registry (small)

TP dataset: *Production and Generation Units* (static registry).

- One row per (`generation_unit_code`, validity period): name, type
  (fuel), status, installed MW, `valid_from`/`valid_to`, plus the enclosing
  production unit.
- ⚠️ **Data quality, handled by the loader** (`src/generators/registry.jl`):
  overlapping validity periods for the same unit (dedup by most recent
  `valid_from`, then highest capacity); stale validity dates on live plants
  (a plant with recent actual output is kept even if its dates say expired);
  phantom COMMISSIONED capacity (fleet truthing derates it).

### `entsoe.unavailability_of_production_and_generation_units` — outages (v1.1: timestamps pre-cast)

TP dataset: *Unavailability of Production and Generation Units*.

- Grain: one row per outage message version; `asset_code` joins
  `generation_unit_code`.
- `status` ∈ `Active` / `Cancelled` / `Withdrawn` (only `Active` counts);
  `type` ∈ `Planned` / `Forced`; `available_capacity_mw` — 0 = full outage,
  >0 = partial (the loader takes the MIN across overlapping records).
- ⚠️ Stale `Active` 0-MW records exist (e.g. Romanian hydro): the loader
  overrides an outage when the unit demonstrably generated during it in the
  trailing 7 days.

### `entsoe.aggregated_hydro_storage_filling_rate` — weekly reservoirs (17k rows)

TP dataset: *Water Reservoirs and Hydro Storage Plants*. Weekly
`stored_energy_mwh` per zone — drives reservoir dryness and the seasonal
drawdown water-value signal. Kept at full history (the prior-year comparison
needs it).

### `yfinance.ttf_f` — TTF gas front-month (daily)

Yahoo Finance ticker `TTF=F` (€/MWh). The gas SRMC input: the model uses the
last close **strictly before** the market day (no lookahead). History starts
Feb 2023; before that the static `FUEL_SRMC_BASE` fallback applies.

### `yfinance.eua_co2` — EUA carbon proxy (daily)

Yahoo Finance ticker `CO2.L` (SparkChange Physical Carbon ETC, EUR). The
carbon-cost input, same strictly-before-the-day rule. History starts Nov
2021; before that a yearly lookup table applies.


Derived by this project from the per-unit output history: `ramp_up`/`ramp_down`
(95th-percentile observed ramps, fraction of p_max per hour), `p_min` (5th
percentile of stable non-zero operation, MW), `min_uptime`/`min_downtime`
(hours), with `data_points_used` for provenance.

### `simulations.unit_firms` — unit → firm ownership map

Curated by this project (used by the `strategist` scenario hook's
`ctx.firm_of`). `source` records the curation wave per row; coverage varies
by zone (GR/DE_LU/FR strong, ES/IT partial — see
`docs/experiments/firm-maps/`).

## Querying it directly

```sql
-- DuckDB, straight off the parquet dir (no materialization needed for ad-hoc):
SELECT date_time_utc, price_currency_mwh
FROM 'data/public/euphemia-data-v1.1/entsoe.energy_prices.parquet'
WHERE map_code = 'GR' AND contract_type = 'Day-ahead'
  AND date_time_utc >= '2026-01-26' AND date_time_utc < '2026-01-27'
ORDER BY date_time_utc;
```

For model runs, materialize the runtime DuckDB instead (`./setup.sh` does
both steps) — the library's SQL targets the `schema.table` names.


### `books/<market_date>.parquet` — the model's own order books (public bucket)

Produced by the daily forecast run (and any run that enables
`MeritOrderBook.BOOK_SINK`): the FULL tagged order book of every zone for the
market day, captured right before block-merging — the same view the
`strategist` scenario hook receives. One row per order:
`market_date, zone, ts, side (supply|demand), price (€/MWh), mw, owner,
code_version`. `owner` is the generation-unit code for unit ladders (join
`simulations.unit_firms` for firm attribution) or a mechanism tag: `RES`,
`IMPORT`, `DEMAND`, `BACKSTOP`, `EXTRA`, fleet-completion
aggregates (`AGG-<zone>-<type>`). ~150k rows / ~300 KB per 39-zone day
(~112 MB/yr). Two-pass clears keep the final (pass-2) book. These are MODEL
bids (the competitive counterfactual), not actual market orders.
