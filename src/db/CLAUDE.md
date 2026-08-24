# src/db — data-store backends, DuckDB dialect, extract building, indexes

Loaded when working under `src/db/`. Moved from the root `CLAUDE.md` (August
2026). Root keeps the short "which backend / env vars / read-only extract"
summary; the internals live here.

### Data store: Postgres or a DuckDB extract

By default the library reads from the live Postgres `energy` database. It can
instead read from a **self-contained DuckDB extract** — a single `.duckdb`
file that mirrors the same `schema.table` names, so both single-zone
merit-order pricing / scenario analysis **and the full 39-zone multi-zone EU
clearing** run fully offline with no Postgres available.

```julia
# Switch at runtime
configure_data_store!(backend=:duckdb, duckdb_path="data/extracts/euphemia_2026_see.duckdb")
generate_energy_prices("GR", Date(2026, 1, 26); order_method=:merit_order, save_to_db=false)
configure_data_store!(backend=:postgres)   # switch back
```

Or select DuckDB from the environment at module load (this also **skips** the
eager LibPQ pool entirely, so nothing needs Postgres):

```bash
EUPHEMIA_DATA_STORE=duckdb \
EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia_2026_see.duckdb \
  julia --project=. test/scripts/eval_pricing_accuracy.jl merit_order "2026-01-26" GR
```

**Backend auto-detection.** When `EUPHEMIA_DATA_STORE` is *unset*, the module
auto-selects at load (`_resolve_data_store`): DuckDB if the default public extract
`data/extracts/euphemia-public.duckdb` exists (override the path with
`EUPHEMIA_DUCKDB_PATH`), else Postgres if `ENERGY_CONN_STR` is set, else a clear
error telling you to download the extract. **Explicit env always wins**, and
configured environments (CI, the product) are unchanged — the extract file isn't
present there, so Postgres is selected exactly as before.

**Public reproducibility artifact.** A published 39-zone, 2023-01-01…2026-06-30
extract lets anyone reproduce the counterfactual with no Postgres. Download it,
verify `SHA256SUMS`, materialize a `.duckdb` from the canonical parquet dir, and
run `bin/reproduce.jl --quick|--range|--full`. See
[docs/reproducibility.md](docs/reproducibility.md).

**Writable offline results.** The published extract stays **read-only** (source
data can never be written), but the three market-result writers
(`save_energy_prices`, `save_optimization_run`, `save_transmission_flows`) persist
to a **separate** `data/results.duckdb` (override `EUPHEMIA_RESULTS_DB`) ATTACHed
as `results_db`; reads of `simulations.energy_prices` / `optimization_runs` /
`transmission_flows` are redirected there transparently. So the full pipeline with
`save_to_db=true` **and** the eval scripts run end-to-end offline. UC caching and
`ensure_indexes` remain read-only no-ops (Postgres-only).

**Limitations:**
- **Source data is read-only** under DuckDB (entsoe.*/yfinance.* never written).
  Market results persist to `data/results.duckdb` (see above); `ensure_indexes`
  still warns-and-no-ops.
- **Merit-order only.** The DuckDB path targets the `:merit_order` book
  (single-zone and multi-zone) — the only book there is since cv25.
- **Scenario hooks** thread through both the single-zone `:merit_order` path and
  the multi-zone footprint path (`run_multi_zone_market_clearing(...; scenario=)`).

**Multi-zone under DuckDB.** `run_multi_zone_market_clearing(..., order_method=`
`:merit_order, enrich_network=true, passes=2, save_to_db=false)` runs entirely
against the extract — the enriched network build (implicit + explicit ATC union,
aggregate remap, flow-based drops), `get_net_imports` with exclude/import-only
arrays, reservoir dryness, per-type p95, and the day-level-outage-cached
`get_generators` all dispatch through the DuckDB dialect. Prices match Postgres
to floating-point precision: on the 39-zone 2026-04-03 clear, **~98% of the 936
price rows are bit-identical** and the rest agree to **≤2e-12 €/MWh**
(`test/scripts/eu_duckdb_parity.jl`). The residual is
last-ULP non-determinism in SQL aggregate functions (`SUM`/`AVG` in
`get_net_imports`, `percentile_cont` in `get_type_output_p95` /
`get_hydro_availability`) — Postgres and DuckDB sum/interpolate in different
orders — reaching the price only through the scarcity factor of a marginal
tranche. Single-zone stays exactly bit-identical (its price never reads an
aggregated quantity). Cross-border **flows** are a degenerate primal (alternative
optima) and need not match; prices (the duals) are what the parity gate checks.

**How it works:** `sql2df` dispatches on `DATA_STORE[]`. The Postgres path is
unchanged; the DuckDB path applies a small dialect rewrite to our SQL — strips
` AT TIME ZONE 'UTC'` (the extract stores every timestamp as naive UTC),
maps `= ANY($n)` → `IN (SELECT unnest($n))`, `<> ALL($n)` →
`NOT IN (SELECT unnest($n))`, rewrites `get_generators`' Postgres multi-arg
table unnest of the day-outage arrays (`unnest($3::text[], $4::float8[]) AS
t(...)`) into DuckDB's lockstep-unnest subquery form (plus the single
`unnest($5::text[])`), and `to_char(x,'YYYYMMDD-HH24MI')` →
`strftime(x,'%Y%m%d-%H%M')` — then runs it against one lazily-opened,
lock-guarded DuckDB connection. Single-zone DuckDB prices are bit-identical to
Postgres; the multi-zone path matches to ≤2e-12 €/MWh (see the multi-zone note
above). DuckDB's `DATE()`/`EXTRACT(HOUR …)` on the naive-UTC extract match
Postgres because the DB session runs in UTC.

**DuckDB query-path performance.** The read path is tuned so a 39-zone day book
build runs in ~1–3 s (was ~14 s):
- **Sorted extract (artifact v1.1).** Tables are materialized `ORDER BY (zone,
  date)` so row-group zonemaps prune per-zone/per-day scans; the per-unit output
  table is `(month, unit, date)`-ordered so the 60-day recent-generation probe
  prunes. `Network.jl`'s ATC queries use the half-open day range
  (`date_time_utc >= $1::date AND < $1::date + 1`) instead of the non-sargable
  `DATE(date_time_utc) = $1`, so the sort is actually usable. See
  `docs/reproducibility.md` for v1 vs v1.1.
- **Day-level physical-flow cache.** `get_net_imports` / `get_dropped_border_exports`
  scan `entsoe.physical_flows` ONCE per day for all zones (cached in
  `MeritOrderBook._NET_IMPORTS_DAY_CACHE`, like `TTF_PRICE_CACHE`; never cached on
  error); per-zone calls slice + apply the exclude / import-only filters in Julia.
  Identity-tested against the original per-zone SQL in
  `test/test_duckdb_perf_paths.jl` (bit-identical on integer flows; the raw
  MW value can differ by ≤1e-12 on real data from last-ULP `SUM` reordering,
  invisible to prices). `clear_net_imports_cache!()` empties it.
- **Prepared-statement cache.** `_duckdb_sql2df` caches compiled statements per
  connection (keyed by rewritten SQL), so the ~300 small per-day queries skip
  re-parse/plan. Cleared when the connection is dropped/reopened.
- **Per-process engine sizing.** `_duckdb_connection` issues `SET threads /
  memory_limit / temp_directory` at open, sized for `EUPHEMIA_DUCKDB_NPROCS_HINT`
  (the number of concurrent DuckDB processes, wired from `bin/reproduce.jl`'s
  `--workers`) so N parallel workers don't each grab all cores / most of RAM.
  Overridable via `EUPHEMIA_DUCKDB_THREADS`, `EUPHEMIA_DUCKDB_MEMORY`,
  `EUPHEMIA_DUCKDB_TEMP`; `temp_directory` defaults to a dir next to the extract
  (on /home, never /tmp). `sql2df_with_retry` never touches the LibPQ pool under
  the DuckDB backend. `bin/reproduce.jl` persists each run segment in a single
  `Euphemia.results_write_transaction`, so the results DB commits once instead of
  per day.

### Building a DuckDB extract

```bash
# SEE 5-zone (single-zone pricing)
ZONES="GR,BG,RO,RS,HU" START_DATE=2026-01-01 END_DATE=2026-06-30 \
  OUT=data/extracts/euphemia_2026_see.duckdb \
  julia --project=. bin/build_duckdb_extract.jl

# 39-zone EU footprint for offline multi-zone clearing (merit-order only, so the
# huge per-unit output table is windowed to 90 days — see AGEN_BACK_DAYS below)
ZONES="AT,BE,BG,CZ,DE_LU,DK1,DK2,EE,ES,FI,FR,GR,HU,LT,LV,NL,NO1,NO2,NO3,NO4,NO5,PL,PT,RO,RS,SE1,SE2,SE3,SE4,SI,SK,IT-NORTH,IT-CNORTH,IT-CSOUTH,IT-SOUTH,IT-Calabria,IT-Sicily,IT-Sardinia,CH" \
  START_DATE=2026-04-01 END_DATE=2026-04-05 AGEN_BACK_DAYS=90 \
  OUT=data/extracts/euphemia_2026_eu.duckdb \
  julia --project=. bin/build_duckdb_extract.jl
```

The builder reads Postgres (normal `.env`), converts every timestamptz column
to naive UTC, and writes the same `schema.table` names. It carries both offered
ATC tables (`_implicit` + `_explicit`, for the enriched network build),
`physical_flows`, the per-type aggregate, the (windowed) unavailability table,
and the unit registry. Per-type/output aggregate tables are windowed back 400
days (covers the 365-day hydro-availability, 60-day recent-generation, and
30-day p95 lookbacks); the tiny weekly reservoir table is kept at full history so
the prior-year reservoir-dryness comparison is exact. **`AGEN_BACK_DAYS`**
(default 400) windows only the huge per-unit `actual_generation_output` table —
`:merit_order` never runs UC, so it only needs the 60-day recent-generation and
7-day stale-override lookback; setting `AGEN_BACK_DAYS=90` keeps a short-window
39-zone EU extract small. It prints per-table row counts and aborts if the
projected size would exceed the cap. The 2026 SEE extract is ~96 MB (7.1M rows).
`data/` is git-ignored — never commit the `.duckdb`/`.parquet` files.

**Public artifact mode.** Set `PARQUET_DIR` to also emit a canonical parquet
directory (one zstd file per table) plus `MANIFEST.json` + `SHA256SUMS` — parquet
is the engine-version-durable published format; `bin/build_duckdb_from_parquet.jl`
rebuilds a bit-identical `.duckdb` from it (with `PARITY_ONLY=true` +
`VERIFY_AGAINST=<duckdb>` to prove equivalence without a second copy). Tables above
`CHUNK_THRESHOLD` (default 8M rows) are built in monthly chunks to bound memory
(the 39-zone 3.5-year per-unit table is ~125M rows). `MAX_SIZE_GB` (default 12) and
`EST_BYTES_PER_ROW` (default 40, reflecting on-disk compression) parameterize the
size guard; `MIN_FREE_GB` (default 60) aborts gracefully if free space on the
target filesystem would drop too low, and DuckDB's spill workspace is kept next to
`OUT`. See [docs/reproducibility.md](docs/reproducibility.md) for the full public
build + reproduce flow.


### Database Indexes

The ENTSOE tables are populated by an external ETL process and don't have indexes by default. For fast queries, run:

```julia
using Euphemia
Euphemia.ensure_indexes()
```

This creates indexes on frequently-queried tables:
- `actual_generation_output_per_generation_unit` (54 GB) - for parameter inference
- `unavailability_of_production_and_generation_units` (4.4 GB) - for outage filtering
- `production_and_generation_units` `(area_map_code)` and `(generation_unit_code)` -
  the unit registry had no indexes, so `get_generators`' per-zone `area_map_code`
  filter and the recent-generation subquery seq-scanned it 2-3× per zone
  (~280 ms each). The `area_map_code` index turns that into a bitmap index scan
  (EXPLAIN: cost 4697 → 395, ~0.1 ms).

First run takes 30-60 minutes for large tables. Subsequent runs are instant (`IF NOT EXISTS`). Add more indexes to `ensure_indexes()` in `src/dbutils.jl` as needed.
