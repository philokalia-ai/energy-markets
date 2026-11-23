# src/db — data-store backends, DuckDB dialect, extract building, indexes

Loaded when working under `src/db/`. Moved from the root `CLAUDE.md` (August
2026). Root keeps the short "which backend / env vars / read-only extract"
summary; the internals live here.

### Data store: DuckDB (run-local fill or extract); Postgres only behind the fill

**Owner rule (2026-11-23): DuckDB always sits between Postgres and Julia.**
Postgres is for long-term storage. DuckDB is for sharing and calculating.
- Julia never queries Postgres, except the one step that fills DuckDB from Postgres (a bulk copy).
- Every Julia read (inputs, books, production pipelines, backfills, research) goes to DuckDB.
- Results go the same way back: Julia writes to DuckDB, and a bulk transfer moves them to Postgres.
- New code that opens a Postgres connection from Julia for anything else is wrong, whatever it saves.
- Existing direct Postgres reads in `src/` are debt to migrate, not a pattern to copy.

Production jobs read a **run-local DuckDB filled from Postgres** (see "Production
data path" below); offline and research work reads a **self-contained DuckDB
extract**. Both are single `.duckdb` files that mirror the same `schema.table`
names, so single-zone pricing, scenarios **and the full 39-zone multi-zone EU
clearing** run with no Postgres connection. The Postgres backend branch of
`sql2df` stays only for `EUPHEMIA_DATA_STORE=postgres` (legacy paths listed below).

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

### Production data path: fill → run → transfer

Every production job (daily-forecast, generate-multi-zone-prices, publish-web-data,
retro-backfill, rescore-hourly, rescore-q15) makes exactly one Postgres read (the fill)
and one Postgres write (the transfer), both through DuckDB's postgres extension:
`attach_postgres!(con, conn_str; alias="pg", read_only=true|false)` (src/db/pg_attach.jl;
extension dir `EUPHEMIA_DUCKDB_EXT_DIR`, default `<first depot>/duckdb-ext`). Rows move
engine to engine; Julia never holds them.

**Fill.** `bin/fill_run_duckdb.jl --profile P --out DIR` (needs `ENERGY_CONN_STR`;
pins Euphemia to the DuckDB backend before loading, so no LibPQ pool opens) writes
`DIR/inputs.duckdb` (read-only inputs), `DIR/results.duckdb` (read-back slices) and
`DIR/fill.json` (rows/seconds per table, `absent_in_source`, `source_timezone` / `pg_timezone` /
`scanner_timezone`, process wall and peak RSS); built under `DIR/.tmp-<pid>`, exit ≠ 0 on failure.

| profile | days | inputs | results seeds |
|---|---|---|---|
| `record` | `--start/--end` or `--days D1,D2,…` | `FILL_SPECS` + input_corrections [d−1, d+3) | energy_prices of the run days, input_corrections |
| `daily-forecast`, `export` | `--as-of` − 1 … + 8 | `FILL_SPECS` + actual prices 400 d, model_lines, tsfm_overlay, input_corrections [asof−5, asof+10) (`INPUTS_BACK_DAYS` widens the inputs-panel tables) | forecast_prices, forecast_scores, input_corrections, 120 d transmission_flows |
| `retro` | `--start S --end E` → UTC days S−1 … E | as daily-forecast, input_corrections [S−2, E+3) | forecasts/scores for market days S … E, input_corrections |
| `rescore` | `--start S` (or `auto`) `--end E [--zones]` | actual prices only | forecasts for the window, forecast_scores whole |

The record seed of `energy_prices` is intended: the run days' existing prices, so the job's
skip-existing (resume) behaves exactly as against Postgres. To recompute days that already
have prices, pass `--seed-skip energy_prices` (or run with resume off), not
`--seed-results false`: that drops every seed, and the first read-back then raises.

Options: `--zones` (default `ZONES` env, else the 39-zone footprint), `--seed-results false`
(no seeds at all), `--seed-skip T1,T2`, `--source duckdb:<path>` (offline proof: the same filter SQL
against a DuckDB extract), `RESULTS_SOURCE_CONN_STR` (seeds from another database).

**Memory.** DuckDB's buffer is bounded by `EUPHEMIA_FILL_MEMORY` (default 1GB; threads
`EUPHEMIA_FILL_THREADS`, default 4) and each table is CHECKPOINTed. Measured (d4d780e, 10–11
record days, ~0.6–1 GiB inputs): process peak RSS 2.2–2.75 GiB, flat in the day count (a 3-day
runner fill: 3.5 GiB; up to 4.55 GiB seen with more cores/memory available: allocator and GC
slack, not data). Page cache from writing the file fills the cgroup to whatever cap it has
(3.4–4.3 GiB seen); it is reclaimable and needs no request. Fewer threads only slow the fill.
Workflow memory request: 6Gi for the jobs that fill and clear (fill ≤ ~5 GiB worst case; the
DuckDB-path clear ~2.4 GiB, a 2-book-worker pipelined record ~5 GiB); 2Gi for rescore (one
table).

**Manifest** (`FILL_SPECS`, src/db/fill_manifest.jl): per table the zone filter, the time
column and the readers' lookback/lookahead per delivery day; a run's window is the union over
its days of `[d − back, d + ahead + 1)`. Exactness extras: outage tables copy every version of
each message with a version overlapping a day window (the readers pick the gate version);
offered implicit ATC adds the earliest Day-ahead row per border (`_da_ever_borders` reads all
history); per-unit output extends below the window for stale-feed zones (rescue window);
offered ATC is filtered on the readers' code list (`_atc_codes`: the footprint plus the
aggregates it remaps, e.g. `IT` → `IT-NORTH`), not the footprint alone. `carbon.uka_price`
(the GB boundary book's anchor, read by every clear) is in `FILL_SPECS`.

**Time zones.** Every libpq session is pinned to UTC (`PGTZ=UTC`, the TimeZone startup
parameter, which outranks the server default; LibPQ connections also `SET TimeZone`;
`attach_postgres!` refuses a scanner session that is not UTC). The fill's projections do not
depend on it anyway: timestamptz columns `AT TIME ZONE 'UTC'`, text timestamps (production's
outage start/end) `::timestamp`. Before d4d780e a listed `::TIMESTAMP` cast of a timestamptz
ran in the source session's zone.

**Absent in the source.** A `FILL_OPTIONAL` table (`carbon.uka_price`, `simulations.model_lines`,
`simulations.tsfm_overlay`) missing from the source is recorded (`_fill.windows` kind `absent`,
`fill.json` `absent_in_source`); a read of it then fails with DuckDB's Catalog Error and the
reader's documented fallback runs (uka → EUA), exactly as against that source. Any other
Catalog Error under a fill is a `FillGuardError`.

**Strict guard.** A DuckDB carrying `_fill.windows` is a run-local fill: `_duckdb_sql2df`
raises `FillGuardError` on a read of a table outside the manifest and on any Date/DateTime
parameter or `TIMESTAMP` literal outside a filled window. The same error is raised on a
failed results attach and on a read-back of a table the results DB holds no seed of
(`results_db._fill.seeds`, written by `seed_run_results!`; input_corrections is also
window-checked). `FillGuardError` is never retried (`sql2df_with_retry`) and every soft
fallback rethrows it (`_rethrow_fill_guard(e)` in the `catch`, which also unwraps
TaskFailedException / CompositeException / RemoteException): the book path, and the outer
catches of bin/daily_forecast.jl (UTC-day clear, cv32 emission, ML overlays) and
src/clearing/batch_runners.jl. `multi_zone_main` exits 1 on any failed date under a fill. Add
that line to any new `catch` around a read: a guard hit must fail the job, never drop a day. Hand-built files (tests, tools) mark themselves with
`mark_run_local_fill!(path; windows=[(schema, table, lo, hi), …])` (`lo = 1900-01-01` = whole
table) and `mark_results_seeded!(tables)`.

**Read-back redirect.** `energy_prices` / `optimization_runs` / `transmission_flows` always
resolve to `results_db`. `forecast_prices*`, `forecast_scores` and `input_corrections` resolve
to `results_db` only for a run-local fill (the fill seeded them there); on a plain extract they
read the extract's own tables, exactly as main. Write statements always go to `results_db`.

**Who reads input_corrections where (cv32).** Decided per process, explicitly, by
`EUPHEMIA_RESULTS_READBACK` (read in `__init__`; nothing is attached there):
- `results` (default): single-process jobs and the pipeline coordinator read `results_db`, so
  the daily forecast's clear sees the corrections it emitted earlier in the same process.
- `inputs`: the pipelined book/solver workers (`run_pipelined_backfill` sets it). The
  coordinator holds the results DB read-write, and DuckDB's file lock keeps a second process
  from attaching it, so the workers read the fill-time copy in `inputs.duckdb` (same window as
  the seed). Record and backfill runs emit no corrections, so that copy equals the seed.
Before this split (d497e41…f4948e6) the workers' attach failed and the cv32 reader kept the
raw forecasts: 80 IT-Sardinia cells on cb-harness's tranche 2. No workflow was affected,
because no workflow runs the pipelined backfill (reproduce.jl and eu_calibration_run.jl do),
and generate-multi-zone-prices builds its books in the coordinator. Research runs and
record-on-extract runs were affected.

**Results and transfer.** Under `EUPHEMIA_DATA_STORE=duckdb` every forecast-side write
(`write_forecast!` plans, cv32 corrections, scores incl. rescore and restore) goes to the
results DuckDB (src/db/run_results.jl) and logs one op. `bin/transfer_run_results.jl` stages
the rows through the extension and applies all ops in one server-side transaction (guards and
plans re-decided in Postgres; a changed plan aborts with nothing written;
`simulations.transfer_log` makes it exactly once). The record path saves to the results
DuckDB and `bin/transfer_results_to_postgres.jl` (also `transfer-record.yml`) upserts runs,
replaces price/flow slices and verifies checksums inside the transaction (`--written-since`).

**Nightly refresh.** `bin/refresh_duckdb_extract.jl` attaches the energy DB (`pg`) and the
weather DB (`wx`) on the extract connection and copies inside DuckDB (scanner mode in
bin/extract_common.jl).

**Adding a reader.** A new `sql2df` read of a table/window the manifest does not cover fails
the guard. Add the table (or widen its `back`/`ahead`) in `FILL_SPECS`, or add a seed for a
results-side table in `fill_profile`; prove it with `--source duckdb:<extract>` + a clear with
the guard on (prices must equal the extract run). Never open Postgres from the reader.

**Legacy (only with `EUPHEMIA_DATA_STORE=postgres`).** The Postgres branch of `sql2df`,
`withdb`/`preinit_pool`, the LibPQ bodies of the writers, and `bin/build_duckdb_extract.jl`
(manual full rebuild; the scanner mode is available via `SCAN[]`). Non-Julia emitters
(`emit_tsfm_overlay.py`, `emit_model_lines.py`) are outside the rule and listed in the PR.

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
