# Code map

A third-party reader's guide to the source tree: what lives where, what calls
what, and where to start reading for each task. The package is one Julia module
(`Euphemia`) plus three nested submodules (`MPCC`, `AlternativeOrderBook`,
`MeritOrderBook`); large concerns are split into per-topic files that the
parent file `include`s in definition order.

## The 10,000-ft picture

```
                    ┌────────────────────────────────────────────┐
   data access      │ dbutils.jl → src/db/                       │
                    │   postgres_core.jl   LibPQ pool, sql2df    │
                    │   duckdb_store.jl    offline extract       │
                    │   results_store.jl   simulations.* writers │
                    └───────────────┬────────────────────────────┘
                                    │
                    ┌───────────────▼────────────────────────────┐
   inputs           │ Generators.jl → src/generators/            │
                    │ Loads.jl · Renewables.jl · Network.jl      │
                    └───────────────┬────────────────────────────┘
                                    │
                    ┌───────────────▼────────────────────────────┐
   order books      │ MeritOrderBook.jl → src/merit_order/       │
                    │ AlternativeOrderBook.jl · BiddingStrategy  │
                    │ UnitCommitment.jl (for :uc_based books)    │
                    └───────────────┬────────────────────────────┘
                                    │
                    ┌───────────────▼────────────────────────────┐
   clearing         │ MPCC.jl (the solver)                       │
                    │ Euphemia.jl → src/clearing/ (orchestration)│
                    │ PipelinedBackfill.jl (throughput harness)  │
                    └────────────────────────────────────────────┘
```

A price is produced by: **load + RES forecast + unit registry → an order book
(one of three book builders) → the MPCC clearing solve → save/return**.

## Directory guide

### `src/Euphemia.jl` + `src/clearing/`

`Euphemia.jl` is now a thin spine: dependencies, solver-environment cache,
`__init__`, the export list, and `include`s. The clearing logic lives in
`src/clearing/`:

| File | Read this for |
|---|---|
| `single_zone.jl` | `generate_energy_prices` — one zone, one day; zone discovery |
| `multi_zone_books.jl` | building the combined footprint book: network enrichment (implicit+explicit ATC, aggregate remap, flow-based border drops), opportunity-anchor references, and the exposed `mz_*` pipeline stages |
| `multi_zone_run.jl` | `run_multi_zone_market_clearing` — one date, one footprint, one- or two-pass |
| `iterative.jl` | the UC↔MPCC feedback loop (`run_iterative_multi_zone_market_clearing`) |
| `batch_runners.jl` | date-range / all-zones orchestration and summaries |
| `batch_workers.jl` | the internal parallel/sequential worker helpers those runners use |

### `src/MeritOrderBook.jl` + `src/merit_order/`

The merit-order book is the calibrated ex-ante model (the `:merit_order`
`order_method` — what the EU counterfactual runs). `MeritOrderBook.jl` holds
the module header and `include`s:

| File | Read this for |
|---|---|
| `flows_imports.jl` | day-level physical-flow cache, `get_net_imports` (same-day `:d0` and fully ex-ante `:v2` modes), import ATC capacity, the cv17 import backstop, unit→firm map |
| `zone_profiles.jl` | `ZoneProfile` (every per-zone calibration knob, with field docstrings), all named profiles, the `ZONE_PROFILES` registry, and the `ZoneScenario` counterfactual hooks |
| `fleet_data.jl` | hydro availability, per-type output p95, installed capacity, reservoir dryness/drawdown queries |
| `book_build.jl` | `create_merit_order_book` — the book construction itself, decomposed into named stages (see the file header for the stage list) |

### `src/Generators.jl` + `src/generators/`

`Generators.jl` keeps the `Generator` struct, fuel-type constants and
name-based fuel inference, and `include`s:

| File | Read this for |
|---|---|
| `registry.jl` | the unit-registry query (`get_generators`): outage filtering via the day-level outage cache, dedup, stale-validity fallbacks, per-zone memoization |
| `fuel_costs.jl` | TTF gas / EUA carbon price lookups and the SRMC model (`get_marginal_cost`) |
| `parameter_inference.jl` | inferring ramp rates / p_min / up-down times from historical output |
| `inference_cache.jl` | persisting and applying inferred parameters (`get_generators_with_inferred_params`, `refresh_inference_cache`) |
| `initial_conditions.jl` | generator state at t=0 for unit commitment |

### `src/dbutils.jl` + `src/db/`

`dbutils.jl` keeps the backend overview comment and `include`s:

| File | Read this for |
|---|---|
| `postgres_core.jl` | the `ENERGY_PRICES_CODE_VERSION` ledger (every model version, documented), the LibPQ pool, `sql2df` / `sql2df_with_retry` (the single query entry point — dispatches per backend) |
| `duckdb_store.jl` | the offline DuckDB backend: dialect rewrite, prepared-statement cache, read-only guard, writable `results.duckdb` |
| `results_store.jl` | `simulations.*` DDL, the `save_*` writers, `ensure_indexes` |

### Standalone files (unchanged)

- `MPCC.jl` — the market-clearing solver (complementarity formulation, robustness retry ladder). One coherent module; read top-down.
- `UnitCommitment.jl` — the UC MILP (JuMP/HiGHS/Gurobi).
- `Network.jl` — topology, `TransferCapacity`, ATC queries.
- `MarketOrders.jl` — `SimpleOrder` / `BlockOrder` types.
- `AlternativeOrderBook.jl`, `BiddingStrategy.jl` — the `:alternative` and `:uc_based` book builders.
- `Loads.jl`, `Renewables.jl` — demand and RES-forecast queries.
- `FuelTypeParameters.jl` — per-fuel technical defaults.
- `TemporalResolutionUtilities.jl` — 15/30/60-min harmonization helpers.
- `PipelinedBackfill.jl` — producer/consumer backfill harness (book builders feed a small Gurobi pool).

## Where to start, by task

- **"How is a single day's EU price produced?"** — `clearing/multi_zone_run.jl`, then `merit_order/book_build.jl`, then `MPCC.jl`.
- **"What does zone X's calibration mean?"** — `merit_order/zone_profiles.jl` (field docstrings on `ZoneProfile`, then X's profile constant).
- **"Why is unit Y (not) in the fleet?"** — `generators/registry.jl`.
- **"What's in a model version?"** — the ledger comment in `db/postgres_core.jl` above `ENERGY_PRICES_CODE_VERSION`.
- **"Run a counterfactual"** — `ZoneScenario` in `merit_order/zone_profiles.jl` + `docs/scenario-api.md`.
- **"Run offline / reproduce"** — `db/duckdb_store.jl` + `docs/reproducibility.md`.

## Conventions

- Split files are plain `include`s into the parent module — no new modules, no
  namespace changes; every public name is exactly where it was.
- Caches follow one pattern (`TTF_PRICE_CACHE` is the reference): module-level
  `Dict` + `ReentrantLock`, day-keyed, errors never cached.
- All SQL goes through `sql2df` / `sql2df_with_retry`; never open connections
  directly.
- Model-behavior changes bump `ENERGY_PRICES_CODE_VERSION` and get a ledger
  entry; pure refactors (like this split) do not.
