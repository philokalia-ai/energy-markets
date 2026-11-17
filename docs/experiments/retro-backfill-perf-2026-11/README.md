# cv44 retro backfill: input bottleneck and bounded chunk parallelism

**Updated after production run 43990408427 completed:** input/book construction
accounts for **88.2% of production wall time** (2,353–3,948 seconds/day). Prioritize
per-chunk input snapshots/batched reads and existing cache misses before enabling
parallel chunks. The local 1.67× gain below is valid, but does not measure the
production Postgres bottleneck. See [production input analysis](production-inputs.md)
for actual phase timings, query-count × latency calculations, batching targets,
and the revised ranking. **Keep workers=1 until input/DB pressure is measured.**

The opt-in two-process replay took **353.71 s versus 591.75 s sequentially**
(**1.67× faster / 40.2% less wall time**, including process startup). All
**1,872 forecast prices are byte-identical**; all four UTC clears in each arm
returned optimal. See [timings](timings.json), [parity and hashes](parity.json),
and the two saved price CSVs.

The retro campaign clears two UTC days per Athens market day and processes market
days sequentially. In a four-Julia-thread, read-only-extract replay, the warm
market day took **241.43 s**: **214.41 s** in `optimize!`, **19.14 s** building
books (including **16.86 s** executing DuckDB queries), and **5.44 s** constructing
JuMP models. These are nested measurements: do not add SQL to book time or
optimization/model construction to the enclosing clearing scopes.

## Change and operational limits

`retro-backfill.yml` adds `workers: 1|2`, default **1**. One worker execs the
original Julia command with its original environment. Two workers run disjoint
contiguous chunks through the unchanged `run_retro` implementation:

- Four allowed CPUs, four Julia threads, and two Postgres connections per child;
  total eight CPUs/four connections. BLAS/OMP thread counts are bounded at one.
  The PG pool is constructed during runtime initialization, so a cache compiled
  with the default five cannot override each child's requested two.
  Postgres server work is additional to the worker CPU limit. The parallel path
  refuses fewer than eight allowed CPUs; no automatic full-machine fan-out.
- Original 14-day weather batching, lead-1 information cutoff, two-pass clearing,
  two UTC clears, same solver tolerances and cv44. Each chunk has its own process,
  caches and HiGHS scheduler; simultaneous days never share mutable Julia globals.
- Alongside mode, an explicit tag, weather lead 1 and a deadline are required;
  supersede is refused. The existing no-clobber and completed-day checks still run
  inside every child. No writer/scorer/table/model code changes.
- No new chunks after a worker failure or within the preparation/day allowance.
  A worker failure terminates all owned worker groups and fails the step.
  At the supplied deadline, remaining owned worker groups are terminated (10 s
  TERM grace, then KILL). Completed transactions remain; an interrupted day is
  retried by the existing idempotent campaign writer. Cleanup tracks groups after
  leaders exit, escalates TERM-resistant descendants to KILL, and finishes despite
  repeated cancellation or TERM/INT signals. Only owned groups are signalled.
- Scoring runs once after the children, with the existing bounded scoring step.
  The workflow's blackout/active-run guard and concurrency group are unchanged.
  `workers=1` is the rollback. Nothing affects an already-running workflow.

Two processes are the proposed initial ceiling, not a recommendation for 80
workers. They can increase shared weather-API pressure despite existing retry and
backoff; Postgres contention and live-source revision timing are not reproduced
by the fixed-extract experiment. Keep the default at one; the leader should use
an explicit off-hours canary only after input/DB pressure has been measured. No dispatch or production
DB access was performed for this PR.

## Measurement protocol

Source: `ddbeead` (model code unchanged by this PR); Julia 1.13.4, HiGHS.jl 1.27,
read-only `euphemia-live-20261115.duckdb`. Dates: 2026-09-14 and 2026-09-15,
39 zones, 24 Athens hours each; genuine `previous_day1` weather predictions and
ML winners, conservative reconstructed D−1 06:30 issuance, cv44 PS and two-pass
clearing. Both arms consume the same saved load/RES/solar dictionaries. No
Postgres connection, forecast write, scoring, or R2 publish is part of the replay;
“write” timing is a local sorted price CSV only. Production input/write latency
must not be inferred from local DuckDB/CSV timings.

All work was restricted to cores 60–67. Serial used four Julia threads, two
DuckDB threads, 4 GB DuckDB limit, and BLAS/OMP one. Parallel gives each child four
of those same eight cores and the same per-process database/memory limits. The
box was shared with the live job. “Cold” means first clearing call in a fresh
Julia process; OS/file caches were not flushed. This is one measured pair, not a throughput
SLA or an extrapolated production speed claim.

The first diagnostic with one Julia thread took 348.92/252.43 s for the two market
days. Its 1,872 prices are byte-identical to the four-thread sequential replay.
Four-thread measurements:

| Scope, seconds | Sep 14, cold clear | Sep 15, warm process |
|---|---:|---:|
| Market day (two clears, stitch, CSV) | 333.581 | 241.433 |
| Book builds, both passes | 39.404 | 19.141 |
| DuckDB execution, included in books | 29.573 | 16.857 |
| JuMP construction, inside clearing | 7.233 | 5.442 |
| `optimize!`, includes PS and all period calls | 246.157 | 214.414 |
| Clearing function scopes, both passes | 256.848 | 222.150 |
| CSV write | 0.000827 | 0.000756 |
| Process CPU seconds during the day | 482.495 | 348.826 |
| Peak RSS, GiB | 3.727 | 3.843 |

The sequential command including process startup took **591.75 s**, **143% of
one core**, maximum RSS **3.843 GiB**. Initial module load separately measured
18.57 s; daily helper inclusion was 8.46 s in the replay. First-call compilation
and other untimed work are visible in the cold residual; do not call all of that
residual “compilation.” SQL calls: 1,919/1,081, including repeated queries/cache
misses. Instrumentation serializes DuckDB access as the existing backend does,
and excludes lock-wait time from SQL execution totals.

Initial public weather preparation for this **two-day chunk** cost **302.91 s**:
load 28.43, RES 113.94, ML inputs 160.54. HTTP/retry scopes account for 214.98 s;
the code deliberately sleeps 70.2 s over three 39-zone loops at 0.6 s/zone.
Production already batches 14 days, so this is not a per-day production cost.
The experiment did not contact the production self-hosted weather endpoint.

The parallel workers took 336.45/321.24 s per market day (both start cold),
with peak RSS 3.669/3.698 GiB: conservative summed peaks **7.37 GiB**.
The complete two-worker command used **268% of one core** across the same eight
allowed CPUs. Extra cold starts account for some additional CPU work. Fourteen-day
production chunks amortize startup, but no production speed ratio is claimed.

**Do not reuse the UTC overlap across issuances.** On the shared UTC day Sep 14,
the two reconstructed information cutoffs produce different prices in 429/936
cells. Crucially, of the 117 tail cells actually needed by the next Athens market
day, 61 differ, with maximum **63.94 €/MWh** and mean absolute difference
**2.044 €/MWh**. Retaining the earlier clear would change forecasts. The full-day
PS energy budget also prevents safely clearing just the few tail hours.

## Reproduce without a production connection

Set `JULIA_DEPOT_PATH` to a private writable depot and select Julia 1.13.4. Set
`EUPHEMIA_DATA_STORE=duckdb`, `EUPHEMIA_DUCKDB_READONLY=true`,
`EUPHEMIA_DUCKDB_PATH` to an authorized read-only extract, and
`EUPHEMIA_DUCKDB_TEMP` to a private writable directory. Limit
`EUPHEMIA_DUCKDB_THREADS=2`, `EUPHEMIA_DUCKDB_MEMORY=4GB`,
`JULIA_NUM_THREADS=4`, `OPENBLAS_NUM_THREADS=1`, `OMP_NUM_THREADS=1`.
Set `INPUT_MODE=weather`, `OPTIMIZER=highs`, `MAX_LEAD_DAYS=1`.

`RETRO_PERF_OUT` is a private output directory. An explicit
`RETRO_PERF_PREPARE=1` permits public weather fetching and writes a Julia 1.13.4
serialized input fixture; omit it for saved-input-only runs. Use `PERF_FIXTURE`
to reuse exactly that fixture (never deserialize an untrusted file).

```sh
taskset -c 60-67 julia --startup-file=no --project=. \
  test/scripts/benchmark_retro_backfill.jl 2026-09-14 2026-09-15
```

Set `PERF_LABEL` for distinct CSV/query-trace names. For a parallel replay with the same saved `PERF_FIXTURE`:

```sh
taskset -c 60-67 python3 test/scripts/benchmark_retro_parallel.py \
  2026-09-14 2026-09-15 --julia /path/to/julia
```

This invokes the real chunk launcher with one-day benchmark chunks.
The benchmark reads each child's start/end environment. It never executes
`run_retro`'s DB guards/writer; it exercises its actual weather-scenario,
thermometer, ForecastContext, `clear_utc_day!` and stitching logic. Forecast row
identity is checked on the 1,872 sorted `(zone, UTC-hour, price)` rows; no changing
reconstruction timestamps are included. The launcher tests separately verify
partitioning, environment, failure, deadline and cancellation behavior.

```sh
python3 -m unittest discover -s test -p test_retro_parallel.py -v
```

Process tests use synthetic children and skip on hosts exposing fewer than eight
allowed CPUs. They ran on all eight assigned cores for this change. All model
clears are manual offline checks, not CI work.

### Review regressions: runtime pool and process groups

`test/test_retro_parallel.py` covers failed/successful exited leaders with
surviving descendants, inherited output pipes, TERM-resistant descendants,
repeated cancellation/signals, and cancellation during subprocess creation.
Failure now stops and cleans up peers immediately, rather than allowing them to
finish. Cleanup reaps direct children; orphaned descendants are reaped by their
adopter after their owned group is terminated.

With the same private depot and CPU affinity used for the offline benchmark:

```sh
taskset -c 60-67 julia --project=. test/scripts/test_pg_pool_runtime.jl
```

This creates a tiny synthetic DuckDB, warms the **actual Euphemia** package cache
with the default pool size five, then starts fresh processes using
`--compiled-modules=strict` with limits two, default five, three, and zero (clamped
to one). It checks the actual pool capacity and unchanged cache hashes. No PG
connection is opened. The serial launcher still passes argv/environment through
unchanged; the library now honors the caller's pool override at runtime.
