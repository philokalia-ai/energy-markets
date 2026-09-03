# Record backfill — architecture

The canonical full-history EU-footprint record (`clearing_mode='multi_zone_eu'`,
current `code_version`) is produced offline against the DuckDB extract and then
transferred into live Postgres. Four steps, in order:

```
 ┌─ 1. NATIVE BACKFILL ─────────────────────────────────────────────────────┐
 │  run_pipelined_backfill(days, FOOTPRINT; …, books_dir=…)                   │
 │  reads the READ-ONLY DuckDB extract, clears every day (two-pass merit-     │
 │  order), and the coordinator (single writer) persists energy_prices +      │
 │  optimization_runs [+ transmission_flows] to the SEPARATE writable         │
 │  data/results.duckdb.  Order BOOKS for every day are captured to           │
 │  <books_dir>/<market_date>.parquet in the same pass (see step 4).          │
 └────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─ 2. TRANSFER → POSTGRES ──────────────────────────────────────────────────┐
 │  bin/transfer_results_to_postgres.jl                                       │
 │  lifts the (clearing_mode, code_version) slice of data/results.duckdb into │
 │  the live simulations.* tables: upserts optimization_runs first, remaps    │
 │  each price row's optimization_run_id, then delete-then-COPY the price and  │
 │  flow slices. Idempotent + resumable; a full year is minutes (COPY).       │
 └────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─ 3. EXTRACT REBUILD (coordinator, out of scope here) ─────────────────────┐
 │  rebuild / republish the public DuckDB extract + parquet artifact so the   │
 │  reproducibility path (bin/reproduce.jl) reflects the new record.          │
 └────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─ 4. BOOKS RETENTION ──────────────────────────────────────────────────────┐
 │  the per-day book parquets from step 1 are retained / pushed to the public │
 │  data bucket for the transparency + web layer (same schema as              │
 │  bin/daily_forecast.jl's flush_books!).                                    │
 └────────────────────────────────────────────────────────────────────────────┘
```

## 1. Native backfill (DuckDB, pipelined)

The backfill runs through `run_pipelined_backfill` (see `src/PipelinedBackfill.jl`
and the "Pipelined multi-zone backfill" section of `CLAUDE.md`). Under the DuckDB
backend the book-builder + solver workers open the extract **read-only** and the
coordinator is the **single writer** into `data/results.duckdb`
(`EUPHEMIA_RESULTS_DB` to relocate). Nothing touches Postgres in this step.

### Pipeline knobs, throughput and identity

`--pipeline` (on `bin/reproduce.jl`) and `run_pipelined_backfill` decouple the
slow 39-zone book build from the fast solve, which day-parallel runs cannot:
`--book-workers M` (default `min(10, CPU÷8)`) build complete per-day book sets
ahead of time, and `--solver-workers S` dedicated solver processes — each
holding one persistent solver environment — consume them back-to-back,
including the pass-2 opportunity-anchor re-clears (only the anchored zones are
rebuilt; every other zone's book is reused verbatim). Bounded queues (~8 days
in flight) keep RAM flat, the run is resumable per day, and it prints per-day
stage timings plus a final throughput / solver-utilization summary.

```bash
julia --project=. bin/reproduce.jl --range 2026-01-01 2026-06-30 --pipeline \
    --book-workers 10 --solver-workers 2
```

Measured on a 10-day window against a DuckDB extract (80-core box, Gurobi, 2
solver sessions, `test/scripts/pipeline_benchmark.jl`): day-parallel
`--workers 2` took 289 s, `--pipeline` 202 s — **1.43×**, at 73–78% solver
utilization. The pipeline also absorbs hard days gracefully: one day needing
two ~50 s MPCC solves did not stall the others.

**Identity.** The pipeline calls the same stage functions as the sequential
path (`mz_build_books` / `mz_solve_pass` / `mz_extract_anchor_inputs` /
`mz_rebuild_anchored`), and `test/scripts/pipeline_identity.jl` checks 3 days ×
39 zones end-to-end. Against the DuckDB extract, pipelined and sequential are
bit-identical. Against Postgres they are bit-identical only with serialized DB
access (`book_workers=1, in_flight=1`); with concurrent book builds you get
last-ULP noise (≤1e-12 €/MWh, rare near-degenerate marginal-tranche flips)
because SQL aggregate summation order shifts under concurrent query load — a
property of clearing against live Postgres, not of the pipeline. **For exactly
reproducible backfills, run against the extract.**

Note the pipelined path is also where the not-ex-ante-flow record defect lived
(the book workers used same-day `:d0` flows instead of the scoped `:v3`); cv25
closed it, and both arms have resolved the scoped default since.

## 2. Transfer to Postgres

```bash
# default slice: multi_zone_eu / current code_version, whole history
julia --project=. bin/transfer_results_to_postgres.jl

# explicit slice / source / window
RESULTS_DUCKDB=data/results.duckdb \
  julia --project=. bin/transfer_results_to_postgres.jl \
    --clearing-mode multi_zone_eu --code-version 23 \
    --start 2023-01-01 --end 2026-07-24

# verify only — per-year row counts + per zone-month price checksums, both sides
julia --project=. bin/transfer_results_to_postgres.jl --verify
```

- **Idempotent + resumable**: the destination slice is delete-then-insert (the
  same replace semantics as the normal save path), so a re-run replaces the slice
  wholesale and an interrupted transfer is fixed by re-running.
- **optimization_runs linkage preserved**: run rows are upserted first (via the
  same `ON CONFLICT` key the writer uses, `RETURNING id`), then every price row's
  `optimization_run_id` is remapped to the new Postgres id before COPY. When the
  backfill ran `save_prices_only` (null run ids), the price rows transfer with
  null linkage unchanged.
- **transmission_flows** transfer too (scoped by `code_version`) unless
  `--no-flows`.
- **Speed**: bulk rows go in via Postgres `COPY … FROM STDIN` (streamed), so the
  ~1.2M-row cv22-sized year moves in minutes, not hours.
- Never prints connection strings; reads `ENERGY_CONN_STR` from the environment
  (`.env`).

## 4. Order-book capture

Book capture is an **opt-in, observational** feature of the pipelined backfill:
pass `books_dir=` to `run_pipelined_backfill`. Each book-builder worker installs
the `MeritOrderBook.BOOK_SINK` and captures every zone-day's FULL **tagged** book
(per-unit bid ladders plus the `RES` / `IMPORT` / `DEMAND` / `BACKSTOP` / owner
tags — the pre-merge strategist view). Because the two-pass rebuild only re-fires
the sink for the **anchored** zones, the day's complete book is pass-1 (all
zones) with the anchored zones **overwritten by pass-2** — exactly the
overwrite-per-`(zone,day)` semantics of `bin/daily_forecast.jl`'s sink.

In the pipeline a day's pass-1 and pass-2 books can be built by **different**
worker processes, so capture is staged and merged:

1. each worker flushes its captured zones to a **pass-tagged** staging parquet
   `<books_dir>/.staging/<day>_pass{1,2}.parquet` **synchronously before**
   forwarding the job to the solver — so the staging file is on disk before any
   result for that day can reach the coordinator;
2. the coordinator, when it finalizes the day, merges pass-1 ∪ pass-2 with
   **pass-2 winning per zone** into `<books_dir>/<day>.parquet` (zstd; columns
   `market_date, zone, ts, side, price, mw, owner, code_version`) and deletes the
   staging files. A failed (unusable) day's staging is cleaned up instead.

Sizing (measured, 39-zone two-pass day): ~150k tagged orders, ~307 KB zstd per
day, ~400 MB for the full 1,301-day history.

**Identity guard (non-negotiable):** with `books_dir` set the sink only *reads*
(copies) the tagged list — prices are **bit-identical** to `books_dir=nothing`.
Proven offline on 2026-04-03 (39 zones, HiGHS): max |Δ| = 0 over all 936 prices.
When `books_dir` is `nothing` the sink is never installed and the whole path is
inert. The merge semantics have a DB-free unit test in
`test/test_pipeline_book_merge.jl`.
