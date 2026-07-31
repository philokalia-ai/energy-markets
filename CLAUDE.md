# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Julia project implementing the **Euphemia** energy market clearing engine, focusing on electricity market simulation and optimization. The project models day-ahead electricity markets with support for unit commitment, bidding strategies, and network constraints.

## Methodology (standing rules, owner-ratified July 2026)

**Canonical, repo-committed working notes — read these first:**
[.claude/STRATEGY.md](.claude/STRATEGY.md) (what the program is, how progress
happens), [.claude/SCIENTIST.md](.claude/SCIENTIST.md) (the experimental
discipline), [.claude/CODE_STYLEGUIDE.md](.claude/CODE_STYLEGUIDE.md) (code
reads like the zone-strategies table; switches, guards, layout). The rules
below are the summary; the files are the authority.

1. **Theory → experiment → results.** Gates/windows/falsifiers are FROZEN
   (merged prereg doc) before any scored run; the owner reviews non-draft PRs
   carrying code AND measured results together, and decides on the numbers —
   never asked to pre-approve an unvalidated approach.
2. **Calibrate on Set A, hold out Set B** (scored once, on an A-pass only).
   Scored-cell counts beside every figure; conflicted ≠ pass; per-zone envelope
   (+3.0 MAE / −0.05 corr) and the no-new-cap-hours ceiling guard collateral
   damage; leave-one-out arms attribute every package's effect.
3. **Regime-conditional evaluation.** Mechanisms that only exist in a regime
   (solar surplus, nuclear outage, hydro state, mix anomaly) are gated and
   judged WITHIN their regime (per-zone axis + one threshold, simple and
   ex-ante) — never rejected on all-hours averages; outside-regime deltas must
   be ≈0 by construction.
4. **The collapse question.** Whether prices COLLAPSE (≤ €5, solar-surplus
   middays / negative hours) is a classification question that dominates
   continuous MAE near the RES-coverage threshold: small solar-forecast errors
   flip the answer, so input accuracy there defines whether the signal is
   useful at all. Collapse hit/false-alarm rates are first-class validation
   metrics alongside MAE/corr.
5. **Ex-ante always**: every input available before the auction gate (D-1
   vintages for weather, lagged public books for calibration, trailing
   observed capabilities for capacities); parameters are nameable market
   characteristics (the no-fit claim was retired for this sharper one).
6. **Bit-identity guards**: every switch-gated change proves all-off ==
   baseline (1032-row GR+EU harness) before any scored arm; fresh process per
   (arm, day) cell; measured NO-SHIPs are documented in
   docs/experiments/ and their branches stay unmerged.
7. **Conduct residuals are measured, not reproduced** (PL import premium,
   near-cap withheld tails) — the competitive counterfactual's boundary.

## Core Architecture

The main module `Euphemia` provides:

- **Market clearing optimization**: Implements the Euphemia algorithm for economic surplus maximization
- **Unit commitment solver**: Optimizes generator dispatch with technical constraints
- **Bidding strategy engine**: Converts unit commitment results to market orders
- **Network modeling**: Handles Available Transfer Capacity (ATC) constraints between bidding zones
- **Multi-zone market clearing**: Simultaneous clearing across multiple zones with cross-border transmission flows
- **Data access layer**: Database utilities for energy market data

### Key Modules

See **[docs/code-map.md](docs/code-map.md)** for the full third-party reader's
guide (what lives where, what calls what, where to start per task). Large
concerns are split into per-topic files `include`d by a thin parent in
definition order:

- `src/Euphemia.jl` + `src/clearing/` - Main module spine (deps, solver cache, exports) + the clearing orchestration: `single_zone.jl`, `multi_zone_books.jl`, `multi_zone_run.jl`, `batch_runners.jl`, `batch_workers.jl`
- `src/MeritOrderBook.jl` + `src/merit_order/` - The calibrated ex-ante book: `flows_imports.jl` (net imports, ex-ante flows, backstop), `zone_profiles.jl` (ZoneProfile + ZONE_PROFILES + ZoneScenario), `fleet_data.jl` (hydro/p95/reservoir queries), `book_build.jl` (create_merit_order_book)
- `src/Generators.jl` + `src/generators/` - Generator struct + `registry.jl` (get_generators), `fuel_costs.jl` (TTF/EUA/SRMC)
- `src/dbutils.jl` + `src/db/` - `postgres_core.jl` (code-version ledger, pool, sql2df), `duckdb_store.jl` (offline extract backend), `results_store.jl` (simulations.* DDL + writers)
- `src/MPCC.jl` + `src/mpcc/` - MPCC solver: `solver.jl` (clearing solve, robustness ladder, competitive price reconstruction), `coupling_metrics.jl`
- `src/Network.jl` - Network topology, TransferCapacity, and ATC constraints
- `src/MarketOrders.jl` - Order types (SimpleOrder, BlockOrder)
- `src/OrderBookResult.jl` - The shared order-book result type + the timeslot helper
- `src/Loads.jl`, `src/Renewables.jl` - Demand and RES-forecast queries

### Key Functions

**Single-zone market clearing:**
```julia
# Generate prices for a single zone
prices = generate_energy_prices("GR", Date(2024, 6, 15);
    order_method=:merit_order,
    save_to_db=true,
    force_rerun=false)     

# Process all zones for a single date
result = generate_energy_prices_for_all_zones(Date(2024, 6, 15);
    force_rerun=false)       # Propagates to all zone solves

# Process a date range
result = generate_energy_prices_for_date_range(Date(2024, 6, 1), Date(2024, 6, 7);
    force_rerun=false)       # Propagates to all date/zone solves
```

**Multi-zone market clearing with transmission flows:**
```julia
# Clear multiple zones simultaneously with cross-border ATC constraints
result = run_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "BG", "RO"],  # or empty for auto-discover
    order_method=:merit_order,
    save_to_db=true)

# Access results
result.market_prices["GR"]      # Zonal prices
result.transmission_flows       # Cross-border flows
result.solve_time              # Solver time
result.total_time              # Total processing time

# Process multiple dates with multi-zone clearing
result = run_multi_zone_for_date_range(Date(2024, 6, 1), Date(2024, 6, 7);
    order_method=:merit_order,
    save_to_db=true)

# Parallel UC execution (requires workers)
using Distributed
addprocs(4)
@everywhere using Euphemia

# Single date with parallel UC
result = run_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "BG", "RO", "HU"],
    order_method=:merit_order,
    parallel=true)  

# Date range with parallel UC
result = run_multi_zone_for_date_range(Date(2023, 1, 1), Date(2024, 12, 31);
    order_method=:merit_order,
    parallel=true,       # UC solves run in parallel per date
    force_rerun=false, 
    save_to_db=true)
```

**Zone discovery:**
```julia
# Zones with generator data
zones = get_available_zones(date)

# Zones with transfer capacity data (for multi-zone clearing)
zones = get_zones_with_transfer_capacity(date)
```

**Generator unavailability filtering:**
```julia
# Get generators with outage filtering (default behavior)
generators = get_generators("GR", Date(2024, 6, 15))

# Disable filtering to get all commissioned generators
generators = get_generators("GR", Date(2024, 6, 15); exclude_unavailable=false)
```

The `exclude_unavailable` parameter (default: `true`) filters generators based on outage data:
- **Complete outages** (`available_capacity_mw = 0`): Generator excluded entirely
- **Partial outages** (`available_capacity_mw > 0`): Generator's `p_max` reduced to available capacity
- Only `status = 'Active'` outages are considered (ignores `Cancelled`/`Withdrawn`)
- Uses `MIN(available_capacity_mw)` when multiple outage records exist (conservative)

**Generator deduplication (overlapping validity periods):**
- ENTSO-E data can have multiple rows for the same generator with overlapping `valid_from`/`valid_to` periods
- This is a data quality issue where capacity changes create duplicate entries instead of properly versioned records
- The query uses `DISTINCT ON (generation_unit_code)` to deduplicate
- Priority: most recent `valid_from`, then highest capacity as tiebreaker
- Example: Poland's "Dolna Odra B7" had 5 overlapping entries with capacities 210-232 MW

**Date validity filter with recent generation fallback:**
- ENTSO-E data has stale `valid_from`/`valid_to` dates for some operating plants
- Example: Spain nuclear plants had `valid_from` in 2026 (future!) but were actively generating
- Example: German coal plants had `valid_to` in 2022-2024 but were still operating in 2025
- Solution: Include plants that EITHER pass the date validity filter OR have recent actual generation output
- Recent generation = output > 0 MW within the last 60 days (from `actual_generation_output_per_generation_unit`)
- This ensures operating plants are included regardless of stale validity dates
- Plants with neither valid dates NOR recent generation are correctly excluded (truly decommissioned)

**Day-level outage cache + per-zone memoization (`get_generators` performance):**
- The `active_outages` aggregation and the `stale_outage_override` set are
  **zone-independent day-level work**: a ~3 s seq-scan of the 9.4 GB
  `unavailability_of_production_and_generation_units` table (text timestamps cast
  per row). `get_day_outages(day)` computes this ONCE per market day across ALL
  zones and caches it in a module-level `Dict{Date,DataFrame}` (thread-safe, like
  `TTF_PRICE_CACHE`; never cached on DB error). Each zone's `get_generators` query
  consumes its slice as array parameters (`unnest($3,$4,$5)`) — same rows as the
  old per-zone CTEs (identity-tested for GR/DE_LU/NO1/FR + a 2022 crisis date in
  `test/test_get_generators_identity.jl`). A 39-zone EU build hit the table once
  instead of ~50 times (235 s → 145 s for the generator stage).
- `get_generators` also memoizes its result per `(zone, day, exclude_unavailable,
  exclude_variable_renewables, infer_ramp_rates_flag)` in a module-level `Dict`, so
  pass-2 anchored rebuilds and repeated builds in one process are free (they
  return a shallow copy — callers may mutate the returned vector, e.g. fleet
  completion). `Euphemia.clear_generator_caches!()` clears both caches.

The `exclude_variable_renewables` parameter (default: `true`) filters out wind and solar generators:
- **Variable renewables** (Wind Onshore, Wind Offshore, Solar) are excluded from UC
- These generators' output is non-dispatchable and handled via renewable forecasts
- Renewable generation is subtracted from load to calculate net demand for UC
- This prevents double-counting (generator in UC + forecast subtracted from load)

**Gas marginal costs from real TTF prices:**

Gas-fired generators ("Fossil Gas") use real TTF front-month futures prices from
`yfinance.ttf_f` (populated by the ceres yfinance ETL, updated Tue–Sat):

```julia
# Most recent TTF close at or before a date (€/MWh), nothing if no data within 10 days
ttf = Euphemia.get_ttf_price(Date(2024, 6, 15))

# Gas marginal cost = TTF/efficiency + carbon + O&M (no bid markup)
mc = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas")  # ≈ €97/MWh
```

Cost model constants (in `src/Generators.jl`): `GAS_PLANT_EFFICIENCY = 0.55`,
`GAS_EMISSION_FACTOR = 0.202` tCO₂/MWh gas, `GAS_VOM_COST = 2.0` €/MWh.

EUA carbon prices come from `yfinance.eua_co2` (daily EUR closes of the
SparkChange Physical Carbon ETC "CO2.L", populated by the ceres yfinance ETL
alongside TTF; the ETC physically holds EU Allowances so its close tracks
EUA spot ~1:1). `eua_price(day)` uses the close of the last trading day
strictly before the market date (no lookahead), cached in
`EUA_PRICE_CACHE`; before the feed's history starts (Nov 2021) or on DB
failure it falls back to the `EUA_PRICE_BY_YEAR` yearly lookup.

TTF lookups use the close of the last trading day strictly before the market
date (no lookahead) and are cached per date in `TTF_PRICE_CACHE` (transient DB
errors are never cached). If no TTF price exists within 10 days before the
requested date (e.g., before the table's history starts in Feb 2023), the
`FUEL_SRMC_BASE` fallback is used. All other fuel types use the `FUEL_SRMC_BASE`
table in `src/Generators.jl` — true short-run marginal costs: non-carbon base
plus `FUEL_EMISSION_FACTOR_EL × eua_price(day)` (e.g., lignite ≈ €112/MWh at
EUA 70), with no bid markup: bidding strategy belongs to the order-book
layer, not the cost model.

**Fuel type inference from generator names:**

Generators classified as "Other" in the ENTSO-E database may actually be known technology types. The `infer_fuel_type_from_name()` function attempts to reclassify them based on naming patterns:

```julia
# Automatic inference happens when loading generators
generators = get_generators("FR", Date(2024, 6, 15))
# Logs: "Inferred fuel type for BESS_AFD7_BARBAN: Other → Energy storage"
```

Currently recognized patterns:
- **BESS/Battery** → `Symbol("Energy storage")`: Matches "BESS", "BATTERY", "BATTERIE", "BATTERI"

Generators that cannot be inferred remain as "Other" with flexible parameters (see FuelTypeParameters below). Unknown "Other" generators are documented in `docs/unknown-other-generators.md` for future research.

**Flexible fuel types:**

The constant `FLEXIBLE_FUEL_TYPES` defines technologies that can operate at any output level (no minimum load factor):
```julia
FLEXIBLE_FUEL_TYPES = [
    Symbol("Hydro Water Reservoir"),
    Symbol("Hydro Run-of-river and pondage"),
    Symbol("Hydro Pumped Storage"),
    Symbol("Energy storage"),
    Symbol("Other")
]
```

These fuel types:
- Have `min_load_factor = 0` (can operate at any level down to 0 MW)
- Are excluded from thermal minimum generation constraints in UC
- Include "Other" since the actual technology is unknown

### Pipelined multi-zone backfill (`run_pipelined_backfill`)

For long multi-zone EU backfills the bottleneck is that the two-pass merit-order
clear alternates a **slow book build** (39 zones of DB-heavy order construction)
with a **fast Gurobi solve**, so the scarce solver sits idle during every build.
`run_pipelined_backfill` (in `src/PipelinedBackfill.jl`) is a producer/consumer
pipeline that keeps the solver saturated: book-builder workers build complete
per-day 39-zone book sets **in memory, ahead of time**, and hand them to a small
pool of solver workers that "never sit".

```julia
using Distributed  # the coordinator manages the worker pool internally
result = run_pipelined_backfill(Date(2026,1,1):Day(1):Date(2026,6,30), FOOTPRINT;
    solver_workers=2,           # concurrent Gurobi solves (== WLS session cap)
    book_workers=10,            # default min(10, CPU_THREADS ÷ 8)
    in_flight=8,                # bounded days-in-flight (RAM + backpressure)
    optimizer="gurobi",
    clearing_mode="multi_zone_eu",
    books_dir="data/web/v1/books",  # optional: capture per-day order books (off = nothing)
    save_to_db=true, resume=true)   # resumable: already-saved days are skipped
result.days_per_hour            # throughput
result.solver_utilization       # solve-busy / wall, per solver worker
```

Architecture (one flow per market day, with the pass-2 anchor feedback edge):
`feeder → BOOK WORKERS build pass-1 → SOLVER pass-1 MPCC → extract anchor refs →
BOOK WORKERS rebuild only the ~12 anchored zones (others reused verbatim) →
SOLVER pass-2 → single WRITER on the coordinator saves`. Stages are wired with
bounded `RemoteChannel`s; a counting-token semaphore caps days-in-flight at
`in_flight` and every internal channel has that capacity, so no internal `put!`
ever blocks (this breaks the pass-2 feedback cycle's deadlock potential) — only
the feeder blocks, which is the intended backpressure.

**Correctness (measured):** every model/book step reuses the exact functions the
sequential `run_multi_zone_market_clearing(...; passes=2)` path uses — the
exposed stages `mz_build_books`, `mz_solve_pass`, `mz_extract_anchor_inputs`,
`mz_rebuild_anchored`. Acceptance test `test/scripts/pipeline_identity.jl`
(3 days × 39 zones both ways): **bit-identical on the DuckDB extract** (2,808
prices, max |Δ| = 0) and bit-identical on Postgres with serialized DB access.
With *concurrent* book builds against live Postgres, SQL aggregate summation
order can shift at the last ULP (≤1e-12 €/MWh; rarely flips a near-degenerate
marginal tranche) — the same documented mechanism as the Postgres↔DuckDB
residual, inherent to concurrent Postgres querying (also affects `--workers 2`),
not a pipeline artifact. Benchmark (10 days, 2026-03): **1.43×** over the
day-parallel 2-worker mode (202 s vs 289 s; solver utilization 73–78%).

**Gurobi safety:** exactly `solver_workers` solver *processes* exist, each solving
one problem at a time, so at most `solver_workers` Gurobi solves run at once — set
it to the WLS concurrent-session cap (2 here), or **1 to coordinate with another
running backfill**. Each solver process creates ONE persistent Gurobi env on its
first solve (`SOLVER_ENV_CACHE`) and reuses it for every subsequent solve.

Wired into the runners: `bin/reproduce.jl --pipeline [--book-workers M]
[--solver-workers S]` (multi-zone jobs go through the pipeline; single-zone jobs
still run sequentially), and `bin/eu_calibration_run.jl` via `PIPELINE=true`
(with `BOOK_WORKERS` / `SOLVER_WORKERS`; saves energy_prices only under
`CLEARING_MODE`). Under the DuckDB extract the workers open it read-only and the
coordinator is the single writer, exactly like `--workers`.

**Order-book capture (`books_dir`).** Pass `books_dir=` to capture every
backfilled day's FULL tagged order book (per-unit ladders + `RES`/`IMPORT`/
`DEMAND`/`BACKSTOP`/owner tags — the pre-merge strategist view) to
`<books_dir>/<market_date>.parquet` (zstd; columns `market_date, zone, ts, side,
price, mw, owner, code_version`; ~307 KB/day, ~400 MB for 1,301 days). The
`BOOK_SINK` fires on the BOOK WORKERS, so capture is worker-side: each worker
flushes its captured zones to a pass-tagged staging parquet
(`<books_dir>/.staging/<day>_pass{1,2}.parquet`) **before** forwarding the job to
the solver, and the single coordinator merges pass-1 ∪ pass-2 with **pass-2
winning per zone** into the per-day parquet at save time (a day's pass-1 and
pass-2 books can land on different workers; the merge is the only cross-process
step, done serially by the coordinator). Books are captured for every *usable*
day independent of `save_to_db`; a failed day's staging is cleaned up. The sink
is **observational** — with `books_dir` set prices are **bit-identical** to
`books_dir=nothing` (guarded on 2026-04-03 × 39 zones, max |Δ| = 0; merge
semantics unit-tested DB-free in `test/test_pipeline_book_merge.jl`).

**cv23 record backfill flow** (see [docs/backfill-architecture.md](docs/backfill-architecture.md)):
(1) native pipelined backfill on the read-only DuckDB extract → results land in
the writable `data/results.duckdb`, books captured via `books_dir`; (2) transfer
that slice into live Postgres with `bin/transfer_results_to_postgres.jl`
(`--clearing-mode multi_zone_eu --code-version N`; upserts optimization_runs +
remaps `optimization_run_id`, delete-then-COPY the price/flow slices — idempotent,
resumable, minutes via `COPY`; `--verify` prints per-year counts + per zone-month
price checksums both sides); (3) coordinator rebuilds the extract; (4) the per-day
book parquets are retained/published.

## Data stores and scenario hooks

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

### Scenario hooks on `create_merit_order_book` / `generate_energy_prices`

Five optional `Function` kwargs let you run counterfactual scenarios. When all
are `nothing` the code path is byte-identical to today (verified by the
benchmark). All five thread through `generate_energy_prices` on the
`:merit_order` path **and** through the multi-zone footprint path (see
"Multi-zone scenarios" below and [docs/scenario-api.md](docs/scenario-api.md)).

- `load_modifier(timeslot::String, load_mw::Float64) -> Float64` — applied to
  every `load_by_time` entry at the source, so it propagates to net demand,
  scarcity margin, water value and demand orders.
- `renewable_modifier(timeslot::String, mw::Float64) -> Float64` — same, on
  `renewable_by_time`.
- `extra_orders(ctx) -> Vector{SimpleOrder}` — appended before merging; `ctx =
  (zone, day, timeslots, resolution_minutes, load_by_time, renewable_by_time)`.
  Both `:supply` and `:demand` allowed (a new plant / ships requesting power).
- `strategist(ctx) -> Vector{Tuple{SimpleOrder,String}}` — see below.
- `fleet_modifier(zone::String, gens::Vector{Generator}) -> Vector{Generator}`
  — first-class capacity primitive: add / remove / derate physical units as
  DATA. Runs AFTER fleet completion/truthing, so a removed unit is not silently
  re-added by the `:installed`/p95 truth-up (scenario edits are physical reality
  changes; truthing runs on the pre-scenario registry).

```julia
# "+300 MW of solar": add 300 MW to renewables during daylight slots
solar = (ts, v) -> (8 <= parse(Int, ts[10:11]) <= 17) ? v + 300.0 : v
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, renewable_modifier=solar)

# "ships request 200 MW more power": extra inelastic demand at the cap
ships = ctx -> [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
                    DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                for ts in ctx.timeslots]
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, extra_orders=ships)
```

### Strategist hook (tagged orders + firm map)

Every order in the merit book is tagged with an owner: the generator code for
unit orders (including fleet-completion aggregates), `"RES"` for the renewable
forecast, `"IMPORT"` for net-import injections, `"DEMAND"` for demand, `"EXTRA"`
for `extra_orders`. The `strategist` hook runs after `extra_orders` and before
merging; its returned set **replaces** the tagged order list. It receives
`ctx = (tagged_orders, zone, day, timeslots, load_by_time, renewable_by_time,
firm_of)` where `firm_of` is a `Dict{String,String}` unit_code→firm loaded from
`simulations.unit_firms` (empty + warn if the table is missing). A plain
`Vector{SimpleOrder}` return is also accepted and re-tagged `"STRATEGIST"`.

```julia
# "What would prices be if the incumbent PPC marked up its units 20%?"
ppc_markup = ctx -> [
    (o.type == :supply && get(ctx.firm_of, tag, "") == "PPC" ?
        SimpleOrder(o.type, o.price * 1.2, o.quantity, o.zone, o.date_time, o.resolution_code) : o,
     tag)
    for (o, tag) in ctx.tagged_orders]

prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, strategist=ppc_markup)
```

### Multi-zone scenarios (EU footprint)

The same hooks thread through the multi-zone path, bundled into a `ZoneScenario`
(`Base.@kwdef` struct: `load_modifier`, `renewable_modifier`, `extra_orders`,
`strategist`, `fleet_modifier`). Pass `scenario=` to
`run_multi_zone_market_clearing`: either **one** `ZoneScenario` applied to every
zone (the `ctx.zone` in `extra_orders`/`strategist` lets one function target
zones), or a `Dict{String,ZoneScenario}` for per-zone targeting. `nothing`
(default) is byte-identical to the no-scenario run (guarded on the single-zone
GR book, the SEE 5-zone book, and the full 39-zone EU book).

```julia
# "Ships request 200 MW more power in GR" on the EU footprint
ships = ctx -> ctx.zone == "GR" ?
    [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
     for ts in ctx.timeslots] : SimpleOrder[]
result = run_multi_zone_market_clearing(Date(2026,4,3); zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2,
    scenario=ZoneScenario(extra_orders=ships))
```

**Two-pass propagation (emergent).** The footprint clears in two passes;
opportunity-anchored zones (`:hydro`/`:nuclear`) re-bid against the pass-1
coupled price. Because a scenario applies on both passes, a change to one zone's
pass-1 price flows through the anchor references into every anchored zone's
pass-2 opportunity cost — scenario-consistent across the footprint. Measured:
+4,000 MW demand in DE_LU lifts NO2's anchored water value +€3.6/MWh though the
scenario never touched NO2. See [docs/scenario-api.md](docs/scenario-api.md) for
the three worked examples (ships / PPC markup / unit retirement) and measured
deltas.

**Analyzing scenario outputs:** label each run with a distinct `clearing_mode`
(kwarg on `generate_energy_prices`), then compare two labels with
`queries/load_weighted_price_delta.sql` via `bin/scenario_delta.jl` (load-weighted
price delta in €/MWh + annualized extra cost in €m). Full workflow and two
committed exercises (GR data center / cold ironing): "Analyzing scenario
outputs" in docs/scenario-api.md and docs/experiments/scenario-exercises/.

## GitHub Actions / CI

The project includes several GitHub workflows for automated price generation:

### Workflows

| Workflow | Schedule | Description |
|----------|----------|-------------|
| `generate-multi-zone-prices.yml` | Daily 3 AM UTC | Multi-zone clearing with transmission |
| `daily-forecast.yml` | Dispatch only | The ex-ante forecast (scheduled from ceres) |

The single-zone, iterative and inference-refresh workflows were deleted in cv25
along with the UC path they drove.

All workflows support `workflow_dispatch` for manual triggering with custom parameters.

### Bin Scripts

The workflows invoke Julia scripts in the `bin/` directory:

- **`bin/multi_zone_main.jl`** - Multi-zone clearing for date ranges

**Running locally:**
```bash
# Set required environment variables
export START_DATE="2025-01-01"
export END_DATE="2025-01-07"
export PARALLEL="true"
export OPTIMIZER="highs"
export MAX_WORKERS="0"  # 0 = auto-detect

# Run
julia --project=. bin/multi_zone_main.jl
```

## Development Commands

### Julia Package Management

```bash
# Activate the project environment
julia --project=.

# Install dependencies
julia -e "using Pkg; Pkg.instantiate()"

# Update dependencies
julia -e "using Pkg; Pkg.update()"
```

### Running Tests

```bash
# Run all core tests (211 tests, ~4 minutes)
julia --project=. test/runtests.jl

# Run specific test files
julia --project=. -e "using Test, Euphemia; include(\"test/test_mpcc.jl\")"
julia --project=. -e "using Test, Euphemia; include(\"test/test_network_module.jl\")"
julia --project=. -e "using Test, Euphemia; include(\"test/test_multi_zone_mpcc.jl\")"
```

### Test Organization

```
test/
├── runtests.jl                  # Main test runner (includes core tests)
├── test_data_fetching.jl        # DB integration for loads/renewables/etc (23 tests)
├── test_mpcc.jl                 # MPCC solver tests (50 tests)
├── test_multi_zone_mpcc.jl      # Multi-zone transmission tests (21 tests)
├── test_network_module.jl       # Network/ATC tests (140 tests)
│
├── manual/                      # DB-dependent, long-running tests (run manually)
│   ├── test_database_integration.jl
│   ├── test_date_range_processing.jl
│   ├── test_*_all_zones.jl
│   └── ...
│
├── scripts/                 # Debug, benchmarks, infrastructure scripts
│   ├── diagnose_fr_infeasibility.jl  # UC infeasibility diagnosis for any zone
│   ├── benchmark_gurobi_vs_highs.jl  # Compare Gurobi (2 workers) vs HiGHS (50 workers)
│   ├── test_gurobi.jl
│   ├── test_optimizer_comparison.jl
│   ├── test_parallel_*.jl
│   └── ...
│
└── archive/                 # Deprecated/broken tests
```

### Optimization Solvers

The project supports multiple optimization solvers:
- **HiGHS** (default): Open-source linear/mixed-integer solver
- **Gurobi**: Commercial solver (requires license)

Configure solver selection via the `optimizer` parameter:
```julia
result = run_multi_zone_market_clearing(date; optimizer="highs")  # or "gurobi"
```

### Database Configuration

The project uses PostgreSQL with LibPQ.jl for data access. Create a `.env` file with:
```
DATABASE_URL=postgresql://user:password@host:port/database
```

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

## Code Formatting

Use JuliaFormatter for consistent code style:
```bash
julia -e "using JuliaFormatter; format(\".\")"
```

## Thesis Integration

The `thesis/` directory contains LaTeX documentation:
```bash
cd thesis
make              # Build thesis.pdf
make clean        # Clean auxiliary files
make distclean    # Clean all generated files
```

## Project Dependencies

Key Julia packages:
- **JuMP.jl**: Mathematical optimization modeling
- **HiGHS.jl**, **Gurobi.jl**: Optimization solvers
- **DataFrames.jl**, **CSV.jl**: Data manipulation
- **LibPQ.jl**: PostgreSQL database access
- **Dates.jl**: Date/time handling
- **DotEnv.jl**: Environment configuration

## Data Sources

Market data is sourced from:
- ENTSO-e Transparency Platform (installed capacity, load)
- EnEx Group (Greek market participants)
- Weather data (renewable generation forecasts) — hourly temperature/wind/solar
  for 1,851 GR cities in a separate weather DB; see
  [READING_WEATHER_DATA.md](READING_WEATHER_DATA.md) for how to query it
- TTFS (natural gas prices)

## Database Schema

The project uses PostgreSQL with two main schemas:

### ENTSO-E Schema (`entsoe.*`)
- `entsoe.production_and_generation_units` - Production unit data with commissioning status and bidding zone mapping
- `entsoe.day_ahead_total_load_forecast` - Day-ahead load forecast used for UC planning (consistent with renewable forecast horizon)
- `entsoe.actual_total_load` - Historical electricity demand (for backtesting/validation, not used in UC)
- `entsoe.generation_forecasts_for_wind_and_solar` - Renewable generation forecasts (filtered by same area_type_code values)
- `entsoe.offered_transfer_capacities_implicit` - Cross-border transfer capacity data between bidding zones
- `entsoe.unavailability_of_production_and_generation_units` - Generator outage data (planned/forced)
- `entsoe.actual_generation_output_per_generation_unit` - Historical generation output (used for parameter inference)

**Important column notes for transfer capacities:**
- Use `out_map_code` and `in_map_code` for short zone codes (e.g., "GR", "BG")
- Use `out_area_code` and `in_area_code` for EIC codes (e.g., "10YGR-HTSO-----Y")
- The short codes (`map_code`) match the generator/load data zone codes

**Note on area_type_code filtering**: The combined codes like 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY' capture cases where bidding zones overlap with control areas (CTA) or countries (CTY). These combined values are present in the database and necessary for comprehensive data retrieval.

**Unavailability table columns:**
- `asset_code`: Matches `generation_unit_code` in production_and_generation_units table
- `start_outage_utc`, `end_outage_utc`: Outage period (text, parsed as timestamp)
- `status`: `'Active'` (confirmed), `'Cancelled'`, or `'Withdrawn'`
- `type`: `'Planned'` (maintenance) or `'Forced'` (unexpected)
- `available_capacity_mw`: Remaining capacity during outage (0 = complete outage)

**Actual generation output table columns:**
- `generation_unit_code`: Matches generator code in production_and_generation_units
- `date_time_utc`: Timestamp of the measurement
- `resolution_code`: Temporal resolution (PT15M, PT30M, PT60M)
- `actual_generation_output_mw`: Output in MW at each timestamp

### Simulations Schema (`simulations.*`)

**`simulations.energy_prices`** - Generated energy price results by bidding zone, date, and time period
- `clearing_mode`: Distinguishes between `'single_zone'` (independent zone clearing), `'multi_zone'` (joint clearing with transmission), and `'multi_zone_iterative'` (iterative UC-MPCC feedback loop)
- `optimization_run_id`: Foreign key to `optimization_runs` table for traceability
- `code_version`: Model version (current: 24 for energy_prices, 4 for optimization_runs/uc_results). energy_prices v3 = SRMC/TTF cost model (July 2026); v7 = multi-zone artifact fixes (tight MIP gap, component-wise price reconstruction, border-aware import exclusion, July 2026; 4–6 were taken by legacy uc_based experiment rows); v8 = daily EUA carbon prices from `yfinance.eua_co2` (July 2026); v9 = multi-zone nodal-balance flow signs fixed (flows were physically mirrored, capping each border by the opposite direction's ATC — July 2026); v10 = crisis-year honesty (fleet-truthing derate of baseload types to trailing p95, absolute must-run below-cost discount — July 2026; 2022 GR bias −141 → +1); v14 = the calibrated 39-zone EU-footprint model, i.e. v0.2.0 (network enrichment incl. explicit ATC + aggregate remap + flow-based border drops, ZoneProfiles, two-pass opportunity anchors — July 2026; 11–13 are reserved for the intermediate calibration iterations, whose 5-day records live under `clearing_mode='multi_zone_eu_cal*'` at cv10; the cv14 full-year `multi_zone_eu` backfill 2025-07..2026-07 is the v0.2.0 record); v15 = iterations 6–8 (July 2026): SK Core-FBMC border drop + :hydro anchor (SK winter MAE 956→~40), seasonal reservoir-drawdown water value (SE1/SE2), import-ATC scarcity credit, installed-capacity fleet truth (`fleet_truth_mode=:installed` on the continental core DE_LU/NL/PL/CZ and the Baltics — DE_LU corr 0.62→0.80), and MPCC robustness (exact indicator-form complementarity retry rung + per-day :p95-books fallback — no missing days). v7 and v8 multi_zone rows carried that bug and were deleted; v8 single_zone rows are flow-free (bit-identical to v9 output) and were relabeled to 9. The SEE single_zone/multi_zone product is byte-identical across v10/v14/v15 code — v14/v15 matter for the EU footprint (`multi_zone_eu`). Earlier rows keep their old version and are not mixed with new results. Each version is one selectable "Run" in the Metabase counterfactual dashboard — bump it for every model iteration that gets a backfill. **Ex-ante flow default (cv16 onward):** the EU-footprint multi-zone path (`enrich_network=true` + `:merit_order`) now defaults to the fully ex-ante `:v2` flow rule (flow climatology + D-7 Norwegian recency, `docs/ex-ante-flows.md`) instead of same-day observed flows — this applies to EU-footprint saves from **cv16** onward; the cv15 full-year backfill was produced with `:d0` same-day flows. SEE legacy paths (single-zone, 5-zone multi_zone with `enrich_network=false`) keep `:d0` and their byte-identity. Explicit `EUPHEMIA_FLOW_ASOF_MODE` or the `ex_ante_mode` kwarg always wins over the scoped default. **v17 = weak-zone import fixes** (July 2026, `docs/experiments/weak-zone-diagnosis` + `docs/experiments/cv17-import-fixes.md`): the cv16 EU footprint's low-correlation zones were a handful of phantom-scarcity cap days from import starvation. Shipped: (1) AT–CZ / AT–DE_LU / AT–SI Core-FBMC border drops + SI on the Slovakia treatment (continental temperament + `:hydro` anchor — `SLOVENIA_PROFILE`); (2) profile-gated **ex-ante elastic import backstop** (`ZoneProfile.import_backstop`, quantity = trailing-8-same-weekday demonstrated import headroom beyond the `:v2` climatology minus offered endogenous ATC, priced 1.8×gas SRMC; on for AT/BE/CH/DK1/DK2/SE3/IT-CNORTH/SI/RO/RS/HU; RO/RS/HU also credit the demonstrated headroom in the scarcity margin via `backstop_scarcity_credit`); (3) ref-priced retained-border exports (`ref_priced_exports`: SI–HR, BE–GB). A fourth mechanism — anchor refs over dropped borders (`anchor_include_dropped`, SE3, SE2-flow-weighted) — was built, measured against its gate and switched OFF (it pinned SE3 at SE2's level: corr 0.55→0.31). The SEE single-zone/5-zone products stay byte-identical (measured: full books + GR prices bit-identical cv16↔cv17 code). **v18 = RESERVED (shape levers, activation held back July 2026; the fields and their kill-switch were REMOVED in cv25's subtraction phase — a revival needs re-implementation, not a flag flip)**: `ZoneProfile.unit_srmc_spread` and `export_absorption_steps` are BUILT (default-inert, with the `EUPHEMIA_DISABLE_CV18` worker-safe kill-switch for lever A/Bs) but NOT activated: the 36-day attribution showed strong non-local coupled interactions (DK1 ladder: NO1 caps 15→0 but IT-CSOUTH corr 0.66→0.39, SE3 0.56→0.10, and DK1 itself regime-dependent; spread: continentally benign but NO1 caps 15→44; FI/FR full-year regressions) — 2-zone/20-day pilot gates are structurally insufficient for coupled mechanisms. The cv18 full-year record was measured, documented (PR #162) and deleted from Postgres; activation waits for the border-scoped redesign (export-backstop mirror) validated on the coupled footprint. cv stays 17 until then. **v19 = anad2 ex-ante flows (July 2026, docs/experiments/analogue-flows):** the EU-footprint scoped flow default moves :v2 → :v3 — per-border mean of the load-analogue median (16 trailing-365 days nearest to the delivery day's D-1 load-forecast vector, the ex-ante thermometer) and the D-2 observed flow (fastest admissible signal — catches a new regime in 48 h). Measured on the 39-day coupled A/B: MAE better/flat in all four windows, GR July-flip evening bias +57→+43, corr 0.85→0.87, footprint net-import MAE −15%. A 3-year analogue pool and pure-D-2 were measured and rejected. SEE legacy paths keep :d0 byte-identity. **v20 = solver-invariant canonical mode (July 2026, `docs/period-decomposition.md`):** the per-period-DECOMPOSED clear becomes the canonical mode on the EU-footprint path for every solver, and the `auto` solver default flips to HiGHS (open-source; the Gurobi license is academic — Gurobi stays the development option via `optimizer="gurobi"`). Decomposed is bit-identical across Gurobi/HiGHS; it differs from the legacy monolithic clear only on degenerate pass-2 anchor ties (10/29,679 hourly cells over the 39-day mode A/B, aggregate scores identical to 2 decimals in all four windows). The pipelined backfill applies the same policy. SEE legacy paths (single-zone, 5-zone multi_zone) stay monolithic and keep their byte-identity. **v21 = DK1/Viking virtual boundary book (July 2026, `docs/experiments/cv21-dk1-viking.md`, item 2 of the virtual-boundary-zone program):** the out-of-footprint GB counterparty on the DK1–GB Viking Link is modeled as an ELASTIC neighbor — import-supply + export-demand ladders anchored on GB's OWN CCGT SRMC (TTF/0.52 + EUA-proxied UK carbon/0.52 + O&M) laddered over the border's demonstrated interconnector capability (a runtime Day-ahead-ATC-capped-at-demonstrated-max query with a trailing-365d p95-block floor on ATC gaps — the wave-2 `capability.json` recipe, generalized to every day) — replacing GB's fixed flow injection AND its import-backstop headroom. First-class and profile-gated: `BoundaryBook`/`VIKING_GB_BOOK` on `DK1_PROFILE` (only DK1; DK2 unchanged), default-inert everywhere else, `EUPHEMIA_DISABLE_CV21` kill-switch. Byte-identity guards (GR single-zone, SEE 5-zone, 39-zone EU with the book disabled) all bit-identical vs cv20. Src-implementation confirm A/B (HiGHS, offline extract): March (stable guard, 8/8 days) DK1 MAE 27.9→24.6 / corr 0.55→0.81 — matches the measured reference (27.6→25.2 / 0.55→0.80); July (10/16 days — the extract lacks Day-ahead ATC for 2026-07-16..21, which fail the enriched-network build for both arms) DK1 MAE 29.5→26.6 / corr 0.88→0.90; no FR/NL/NO2 leakage. GB the zone stays PARKED (no broader GB behavioural book until an Elexon/BMRS + UKA feed); UA (boundary item 1) is a separate decision. SEE single-zone / 5-zone products stay byte-identical (guarded); cv21 matters for the EU footprint (`multi_zone_eu`). No backfill shipped with the code change. The remaining SEE evening residual is form/conduct territory (docs/experiments/fit-scarcity: hyperbolic scarcity candidate + BG conduct signature). **v22 = UA firm-slice boundary book + four confirmed price bug-fixes (July 2026, `docs/experiments/cv22.md`): **The cv22 full record (2023-01-01..2026-07-24, 1,301 days, backfilled 2026-07-26) is the canonical published record: comparable full-year corr 0.67 / MAE 27.4 (cv19: 0.64/27.2 — the largest single-version corr step), full 2023+ 0.62/28.1; per-year energy-weighted corr>=0.75 share 50/58/66% for 2023/24/25, GR 0.72->0.87.**** (A) **ua2** (roadmap item 1) ported to src as a first-class, profile-gated `BoundaryBook` like cv21 Viking — UA is a **war-constrained scarcity buyer** on the HU/SK/RO/PL–UA borders: import supply anchored `0.55 × zone gas SRMC` (no UA fundamentals feed — the documented generic-anchor compromise), export demand = a **FIRM cap-priced base slice** (its demonstrated persistent import need, which does not curtail on price — the mechanism that killed the wave-2 HU March breach) plus an elastic tail. `UA_BOOK_DEFAULT`/`UA_BOOK_PL` (PL adds the UA_DobTPP radial); capability = trailing-366d p95 gross flow per 4h block (`:p95_block`), firm = trailing-28d p10 of the daily block-mean export flow — both computed at RUNTIME (no committed JSON; they reproduce the experiment's `firm_ua.json`/`capability_w2.json` exactly on the confirm days, so the book generalizes to every backfill day). Reference confirm (24-day A/B): HU July MAE 72.3→57.1 / corr 0.69→0.79, March breach dead (28.24→28.29); accepted residuals HU March evening 29.2→33.0, RO/BG March ~+1. (B) `flows_imports` `:v2` border map — a Nordic-side border missing its D-7 observation was DELETED (silently zeroed) instead of falling back to climatology; fixed to fall back. (C) `Network.jl` legacy ATC build — took the LAST duplicate capacity row per border-hour (order-dependent); fixed to hourly AVG matching the enriched path — **this deliberately ENDS the SEE 5-zone byte-identity chain (unbroken since cv10)**; measured SEE delta small and within gate (single-zone unaffected). (D) `get_reservoir_drawdown` window `year>$2-2` widened 52→52-104 weeks; fixed to `$2-1` (Nordic only). (E) `get_reservoir_dryness` ±2-ISO-week neighbourhood didn't wrap the year boundary; fixed with a mod-52 wrapped set (only differs Dec/Jan). All five gated behind `EUPHEMIA_DISABLE_CV22` (byte-identity guard: GR single-zone / SEE 5-zone / 39-zone EU bit-identical to cv21 main with the switch set — Viking stays ON via its own CV21 switch), ON by default. NOT shipped (measured NO-SHIP, deferred to cv23): the GB pair (FR-nuclear root cause; the FR–GB double-count stays known-compensated so it does not ship alone) and iter9/43-zones. Plus #182 runner hardening: the pipelined backfill coordinator now resubmits a solver/book worker's orphaned day (retry-once) and respawns the worker on a HiGHS SIGSEGV, so a segfault no longer deadlocks the run; sequential runners rely on the resume flag. cv22 matters for the EU footprint (`multi_zone_eu`). **v23 = FR nuclear opportunity cost + FR–GB re-pair + interior-Norway backstop (July 2026, `docs/experiments/cv23-fr-nuclear.md`, `docs/experiments/norwegian-hydro/`):** (1) availability-scaled `:nuclear` anchor share for FR (trailing-30d fleet p95/installed — ex-ante, no-fit; March confirm FR MAE 38.2→16.2, evening bias −77%); (2) the FR↔GB border re-paired — double-count fix shipping WITH an elastic GB CCGT boundary book (TTF/0.52 + UKA carbon; the cv22 no-ship prescription); (3) interior-Norway import backstop NO1/NO3 + FR cap fix (`import_backstop` + scarcity credit + `nuclear_bid_ref_ceiling`) — kills the dry-spring phantom-scarcity caps (NO1 MAE 62.7→25.8, bias +36.9→−0.1 on the record). Kill-switches `EUPHEMIA_DISABLE_CV23`/`EUPHEMIA_DISABLE_FRCAP`. The cv23 full record (2023-01-01..2026-07-26, 1,303 days) superseded cv22 as canonical: comparable year corr 0.68 / MAE 26.4, full 2023+ 0.63/26.5, FR 0.78, GR 0.85. **CORRECTION (July 2026, docs/experiments/exante-audit-2026-07.md): every pipelined record — cv16, cv17, cv19, cv22, cv23, cv24 — is NOT ex-ante with respect to cross-border flows.** `run_pipelined_backfill`'s book workers call `mz_build_books`, which has no `ex_ante_mode`, so they used the process-wide `:d0` — same-day OBSERVED flows — not the `:v2`/`:v3` scoped default this ledger documents from cv16 onward. Verified by re-clearing record days both ways against the stored prices (`:d0` 93.8–100% bit-identical, `:v3` ~47%). The choice of `:v3` (the cv19 analogue-flows A/B) is not in question — it never reached the record. The live forecast path is unaffected (it resolves `:v3`). Also: 65 of 1,304 cv24 days (5.0% of days, 2.52% of zone-hours) hold fewer than 24 UTC hours because those days are MISSING D-1 load-forecast hours at source for one zone (SI on 48 of them, BE 8, BG 4) and a zone's book takes its timeslots from the load forecast, so a one-hour zone collapses the coupled intersection for all 39. cv25 corrects both (docs/cv25-plan.md). **v24 = registry sanity bound (July 2026, #205): record-consistency bump.** `MAX_PLAUSIBLE_UNIT_MW = 25 GW` drops corrupt ENTSO-E capacity rows (IT-CSOUTH unit `26WUUUUUUBUSSI19` carried 13,068,005 MW → NaN correlation there via the fleet-truthing denominators). No other mechanism content (the IT must-run floor was measured NO-SHIP twice — `docs/experiments/cv24-it-book.md`); prices change only where a corrupt unit was in the fleet (IT-CSOUTH), every other zone byte-identical to cv23 code. Bumped so post-#205 daily forecasts and the refilled record never mix with cv23 rows. **v25 = the cv25 program (July 2026, #228): canonical ATC physics (single flow variable per border), scoped :v3 ex-ante flows in the PIPELINE entries (closing the not-ex-ante record defect), ISO-year + delivery-day fleet-probe fixes, Phase-4 recalibration (T1 BG/GR demonstrated-headroom backstop + T3 IT-NORTH with the aggregate-in-code sizing fix; T2 structural no-op), per-treatment switches EUPHEMIA_DISABLE_CV25_RECAL/_T1/_T3. Ratified ablation record docs/experiments/cv25-phase2-ablation.md + cv25-phase4-recal.md; the 1,238-day cv25 backfill (2026-07-30) was the first truly ex-ante record (hyperbolic-scarcity cv26 candidate measured NO-SHIP the same day — docs/experiments/cv26-scarcity-noship.md; that experimental label never shipped).** **v26 = ATC Day-ahead preference (July 2026, #233):** the implicit offered-capacity table mixes Intraday rows (often 0 MW) into Day-ahead border-hours — contamination grows 34→138→134 borders across 2023→2025 — and since the Nordic FBMC go-live (late 2024) most Nordic/Core borders carry NO Day-ahead rows at all, so 2025 ran on intraday leftovers (NO3→NO1 "23 MW"; EE Aug-Sep 2025: 122 phantom-cap hours). Per border-hour: AVG FILTER (contract_type='Day-ahead') when DA rows exist, else the previous all-rows AVG (FBMC borders unchanged pending their capacity-source redesign — the next prereg's first question). Applied at all four implicit-ATC consumers + the daily-forecast ATC readiness gate counts DA rows; kill-switch EUPHEMIA_DISABLE_ATC_DAPREF (forwarded to pipeline workers). Measured: EE 2025-08-22 20 cap hours → 0 (max 147.5 vs settled 467); NO1 2025-06-15 caps → 0. CHANGES SEE legacy prices too (38,664 mixed border-hours) — deliberate, ledgered like cv22-C. Mid-day source flips exist on 0.23% of border-days (partial-day DA coverage) — accepted; a day-level preference would drop those borders entirely on non-DA hours. **v27 = the bordered demonstrated-capability program (July 2026, docs/experiments/cv27-borders/, ship decision 2026-07-31):** Day-ahead-free (FBMC) border-hours on SEVEN accepted physical borders — DE_LU~FR, CH~FR, CZ~PL, SE1~SE2, IT-CNORTH~IT-NORTH, DK1~SE3, IT-Calabria~IT-Sicily (both directions each, `CV27_SHIPPED_BORDERS` default; `EUPHEMIA_CV27_T1_BORDERS` overrides for A/Bs, present-and-empty = off) — size by demonstrated capability: trailing-366d p95 gross observed flow per 4h block (`_fbmc_capability`, day-cached), replacing the intraday-blend fallback. Accepted per border by a frozen screening protocol (both directions tied — the measured DK2 asymmetry lesson); 5 rejected, isolating the DE_LU pathology (every DE_LU import border except FR degrades DE_LU). Measured: Set A 31.58/0.692 → 31.14/0.701 (−0.44/+0.009), held-out Set B 28.58/0.454 → 28.17/0.450 (−0.41/−0.004, corr at the gate margin), ZERO new cap hours and ZERO envelope breaches in every arm; the four capacity-REDUCING directions manufactured no scarcity. Self-gating: fires only where no Day-ahead rows exist (2024-07 days fire 192/336 border-hours — correct ex-ante behaviour), so live-vs-extract DA-coverage differences degrade to no-op, never to lookahead (live parity measured Jun 2026+: DE_LU~FR/CZ~PL/SE1~SE2/DK1~SE3 fire fully, IT internals ~71% of hours, CH~FR has no recent implicit rows). The cv27-prereg T2 (spill valley) and T3 (deep-surplus floor) did NOT ship (EUPHEMIA_ENABLE_CV27_T2/_T3 opt-ins only; the floor family measured NO-SHIP in cv28/cv29 — docs/experiments/cv28-results.md, cv29-results.md; demand elasticity likewise NO-SHIP, feat/demand-elasticity inert). Ship guard: the default is bit-identical to the campaign's measured combo arm.
- Unique on `(date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version)` - allows storing results from different clearing modes side by side

**`simulations.optimization_runs`** - Optimization run metadata including status, solver info, and performance metrics
- For single-zone runs: `bidding_zone` contains the zone code (e.g., "GR")
- For multi-zone runs: `bidding_zone` is set to "MULTI_ZONE"
- For iterative runs: `bidding_zone` is set to "MULTI_ZONE_ITERATIVE"
- Contains `optimizer`, `solve_time_seconds`, `objective_value`, etc.
- Unique on `(bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)` - allows comparing different solvers
- **Iterative optimization metadata** (for UC-MPCC iterative runs):
  - `is_iterative`: Boolean flag indicating iterative optimization
  - `total_time_seconds`: Total time for all iterations including UC solves
  - `iterations`: Number of iterations performed
  - `converged`: Whether the algorithm achieved convergence
  - `final_price_change`: Final max price change in €/MWh at termination
  - `final_flow_change_pct`: Final flow change percentage at termination

**`simulations.transmission_flows`** - Cross-border transmission flow results from multi-zone clearing

> The `simulations.uc_*` and `generator_inferred_parameters` tables still exist
> with their data, but nothing writes them since cv25 deleted the UC path.

**Joining prices with optimization metadata:**
```sql
SELECT ep.*, opr.optimizer, opr.solve_time_seconds
FROM simulations.energy_prices ep
JOIN simulations.optimization_runs opr ON ep.optimization_run_id = opr.id
```

## Testing Strategy

Tests focus on:
- Network topology and ATC constraint handling
- Multi-zone market clearing with transmission flows
- MPCC solver correctness and UC comparison
- Unit commitment optimization correctness
- Bidding strategy validation
- Data integrity and consistency
