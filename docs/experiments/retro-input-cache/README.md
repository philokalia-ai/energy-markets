# Retro per-chunk input snapshot/cache (opt-in canary)

Independent of #452, based on main `461e6cf`. Enable the workflow's `input_cache`
boolean or set `EUPHEMIA_RETRO_INPUT_CACHE=true`; both default **off**. The ordinary
Julia entry point, single-process scheduling, model, solver, two UTC clears and
code_version remain unchanged. Snapshot mode requires alongside writes, a PG
state/write backend, and chunks of 1–14 market days.

## First-canary implementation

This is the bounded **query-result cache + PostgreSQL MVCC snapshot** stage of the
input-bundle design, not a full raw-table DuckDB export. It materializes input
results on demand from one frozen source view and batches the expensive per-zone
feed-anchor scans. It preserves the full historical input domain: it introduces
no 60/90-day extraction truncation or new model lookback.

At the start of each chunk, after weather preparation, two dedicated read-only
PG connections begin `REPEATABLE READ` transactions sharing one exported snapshot.
The exporting connection is also a reader: **two input connections total**, in
addition to the unchanged ordinary PG pool. The log states the chunk, server
capture time in UTC and precise MVCC revision cutoff/snapshot ID. This freezes
**source database revisions at chunk start**; it does not claim that the source
was captured on the reconstructed historical issuance date. Existing
ForecastContext publication cutoffs and latency policies still apply per day.

[PostgreSQL's snapshot import contract](https://www.postgresql.org/docs/16/sql-set-transaction.html)
requires importing the snapshot before reading in a repeatable-read transaction;
the second reader does so. Connection loss or SQL errors never reconnect into a
new view. The sole explicit exception is the existing UKA→EUA fallback when the
optional UKA table/schema is absent: a savepoint restores the same read transaction.
Transient failures and missing required inputs remain fatal. A poisoned snapshot fails the chunk before its next forecast write,
even if a legacy loader catches the original SQL error and returns a fallback.

Only the clear installs the scoped input reader, inherited by zone tasks.
`DATA_STORE` is never switched. Resume/live-slice helpers explicitly bypass the
input scope; the unchanged writer uses the ordinary PG pool and its transaction
and live/no-clobber checks. A disposable local PG integration test exercises the
actual writer and discovery helpers while source revisions change.

Cache keys serialize full SQL, typed parameter contents, issuance and optional-read policy. Concurrent
misses for the same key share one computation. Results are copied for consumers;
completed entries are evicted FIFO at a **512 MiB retained DataFrame budget**.
Oversized individual results are returned without retention. This budget excludes
in-flight frames, copies and existing model state; it is not a process RSS cap.
Logged `source_query_seconds` sums callback durations (including pool waits and
materialization); it is not whole-chunk wall time.
Input-derived legacy memos are invalidated at both chunk boundaries; weather
thermometer overrides, profiles and solver state are retained.

Feed anchors batch all requested zone/unit relations at each exact bound. The
original per-zone `MAX` semantics, positive-output filter, upper cutoff and
unbounded historical search are preserved, including duplicated registry rows,
units assigned to multiple zones, and zones with no observations. On the measured
two-day structure this targets **156→4 source anchor queries**. Registry-membership
queries are still the existing SQL; broader registry batching is not part of this
first canary.

## Operational limits and rollback

- Keep one campaign worker for the first canary; this PR neither depends on nor
  enables #452's parallel launcher. Do not infer spare DB capacity from host cores.
- Snapshot readers use 10-minute statement and 15-minute idle-transaction timeouts.
  A timeout or lost connection poisons the chunk; it never silently switches to
  fresh reads. Successful completed-day writes remain resumable.
- Transactions stay open for the chunk, including clearing time. Long snapshots
  can retain dead row versions and impede vacuum cleanup; use a short date range
  for the first canary and measure DB load/transaction age. The existing deadline
  and blackout protections remain. Connections roll back and close in `finally`.
- Cache/snapshot state is in process memory. Restarting/resuming takes a **new**
  chunk snapshot with a newly logged cutoff. There is no durable DuckDB artifact
  to reuse, and no claim of cross-restart revision identity. Written days are
  discovered from current PG state and skipped under the existing campaign rules.
- Rollback is `input_cache=false` / unset `EUPHEMIA_RETRO_INPUT_CACHE`. No migration,
  schema change, model/version bump or production data rewrite is introduced.

## Validation and reproduction

Use Julia 1.13.4, a private writable `JULIA_DEPOT_PATH`, and cores 60–67. For offline
model replay select the shared extract with `EUPHEMIA_DATA_STORE=duckdb`,
`EUPHEMIA_DUCKDB_READONLY=true`, `EUPHEMIA_DUCKDB_THREADS=2`,
`EUPHEMIA_DUCKDB_MEMORY=4GB`, four Julia threads, and BLAS/OMP one. Set the private
DuckDB spill directory explicitly. Set `INPUT_MODE=weather`, `OPTIMIZER=highs`,
`MAX_LEAD_DAYS=1`, `RETRO_PERF_OUT` and `PERF_FIXTURE` to the saved two-day
weather/ML input fixture. The harness refuses production PG and refuses to fetch
weather without an additional explicit preparation flag.

```sh
RETRO_BENCH_CACHE=false PERF_LABEL=baseline julia --project=. test/scripts/benchmark_retro_input_cache.jl
RETRO_BENCH_CACHE=true PERF_LABEL=cached julia --project=. test/scripts/benchmark_retro_input_cache.jl
julia --project=. test/test_input_snapshot.jl
```

For a baseline from an unmodified checkout, use its `--project` plus
`RETRO_BENCH_ROOT` pointing to it, while invoking this harness by path. The cached
arm uses the read-only extract as its immutable source view and the same cache,
scoped dispatch and feed batching as production. This measures local input/cache
cost, not production PG network/server cost. The original input source is already
local, so whole-day gains are expected to be much smaller than in production.

A separate synthetic integration test creates and destroys its own Unix-socket
Postgres cluster with TCP disabled. It does not use production credentials or
connect to a configured service:

```sh
PG_TEST_BIN=/usr/lib/postgresql/16/bin JULIA_TEST_LAUNCHER=/path/to/private-julia-wrapper \
  test/scripts/test_input_snapshot_pg.sh
```

It proves both source readers retain the original view after external updates,
state queries see newly written rows, actual forecast writes use writable live PG,
and a newly inserted live cv44 slice blocks a retro overwrite. No real market
clear is run against the synthetic PG fixture.

## Measured result (2026-11-17)

Both arms use unmodified main `461e6cf` or this branch, respectively, the same
read-only extract and saved weather/ML fixture, cv44, all 39 zones, lead 1 and
four Julia threads on cores 60–67. Each market day runs both UTC clears. One
sequential two-day run per arm; timings are observations, not confidence bounds.

| Measurement | Main | Input cache | Ratio |
|---|---:|---:|---:|
| Two market days, wall | 559.465 s | 553.064 s | 1.012× |
| Book construction, both passes | 56.807 s | 49.713 s | 1.143× |
| Local backend SQL execution | 44.076 s | 33.996 s | 1.297× |
| Source SQL calls | 3,029 | 1,717 | 43.3% fewer |
| Feed-anchor queries | 156 | 4 | 97.4% fewer |
| Feed-anchor local SQL time | 11.986 s | 4.892 s | 2.450× |

The warm second day took 235.769→231.611 s; its books took 18.018→14.059 s
(1.282×) and source calls 1,076→660. Retained cache at chunk end was 136,950,157
bytes (130.6 MiB), below the 512 MiB budget. Peak RSS was 4.27 GB main / 4.23 GB
cached. Startup, public weather fetches, PG persistence and scoring are outside
these day timers. A short local PG integration check also ran during the start
of the cached replay; no parallel market replay ran.

**Identity:** `cmp` passed for both complete market-day CSVs (1,872 prices total)
and both full UTC-clear CSVs (3,744 prices total). The separate compressed outputs
from **both arms** are committed here. `results.json` records hashes, provenance,
per-day phases and counts; `queries-*.tsv` records each SQL family's source calls
and local backend execution time. Run:

```sh
python3 docs/experiments/retro-input-cache/verify_parity.py
```

The shared 2026-09-14 UTC day differs on 429/936 prices between the two baseline
issuances. This implementation preserves those separate contexts; it does not
reuse a solved UTC day across issuances.

**Production interpretation:** local whole-day speed-up is small because the
extract already removes remote I/O and solves dominate. This PR still sends
cache misses to PG; the draft's 4.9–8× full-materialization scenarios do **not**
apply to this implementation. No production speed-up is measured or promised.
Assuming the warm day repeats, a 14-day chunk avoids 6,304 of 15,941 source calls
(39.5%), including anchors 1,092→28. At a fixed 25/100/250 ms serial latency per
avoided call, that is 11.3/45.0/112.6 seconds per market day, before changes in
server scans or shared-cache waiting; actual concurrent waits are not additive.
Batching anchors also removes repeated server work, which a call-count-only model
cannot quantify. A leader-run short canary must measure book wall time, source
query durations and DB load before scaling to 14 days or combining with #452.
A durable DuckDB materialization remains a separate extension if remote misses
still dominate.

Validation: 40 cache/lifecycle assertions, 27 real disposable-PG assertions,
8 repository-hygiene tests; Julia lint 0 errors / 38 warnings. Required inputs
fail closed even if loaders swallow SQL exceptions; an optional missing UKA table
retains the documented EUA fallback without changing the source revision.
