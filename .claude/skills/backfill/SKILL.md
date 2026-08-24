---
name: backfill
description: Run, resume, benchmark or transfer a multi-zone EU backfill with the pipelined producer/consumer runner (run_pipelined_backfill, bin/reproduce.jl --pipeline, bin/eu_calibration_run.jl PIPELINE=true), including order-book capture (books_dir) and the DuckDB-to-Postgres transfer flow. Use whenever the user asks to backfill a date range, resume a backfill, capture order books, or move offline results into Postgres.
---

# Pipelined multi-zone backfill (`run_pipelined_backfill`)

Moved from the root `CLAUDE.md` (August 2026). Architecture reference:
`docs/backfill-architecture.md`; scenario/eval tasks: the `scenarios` skill.

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
price, mw, owner, strategy, code_version`; ~307 KB/day, ~400 MB for 1,301 days).
The `strategy` column is the honest source-side "WHY" of each block
(`must_run_deep`/`srmc_base`/`peak_tranche_<k>`/`water_value_*`/`import_backstop`/
… — the `STRATEGY_DESCRIPTIONS` table in `src/merit_order/book_build.jl`), carried
in a vector PARALLEL to the `(order, owner)` tuples so the strategist-hook contract
is untouched; it is price-inert (guarded bit-identical). Parquets captured before
the column existed still read everywhere (worker `has_strategy=false` → the SPA
hides the strategy/explanation columns). The
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

