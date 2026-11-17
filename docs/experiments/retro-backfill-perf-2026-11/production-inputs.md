# Completed production run: prioritize input reads

The completed run **43990408427** changes the recommendation. **Reduce repeated
production input work before enabling parallel chunks.** The 1.67× parallel
speed-up remains a valid fixed-extract result, but is not a production forecast.
The offline solver-heavy profile does not describe the production bottleneck.

## Production phases reconstructed from the log

`production-timings.json` is generated from the leader's saved GitHub Actions log
by `test/scripts/analyze_retro_run_log.py`. It records the log SHA-256, timestamps
and derived intervals. Book intervals run from the book-start marker to the
optimization-start marker, including network enrichment, zone construction and
assembly. Solver scopes include model/backend work, not just native HiGHS.

| Market day | Total s | Book construction s, both UTC clears and both passes | Solver scopes s | Book share | Outside both clears s |
|---|---:|---:|---:|---:|---:|
| 2026-10-18 | 4,380.8 | 3,947.6 | 432.1 | 90.1% | 1.1 |
| 2026-10-19 | 2,787.8 | 2,428.8 | 358.6 | 87.1% | 0.3 |
| 2026-10-20 | 2,832.9 | 2,437.5 | 395.0 | 86.0% | 0.4 |
| 2026-10-21 | 2,663.0 | 2,353.0 | 309.6 | 88.4% | 0.4 |

Across all four days, **88.2% of wall time is book construction**. Initial book
construction alone takes **1,087.8–2,145.6 s per UTC clear**. The two clear totals
cover essentially the whole market-day timer. The headline `Solve time` line
reports the accepted *second pass*; counting only that line would omit the first
pass. This analysis uses both pass scopes.

Weather preparation occurs before `t_day` in `run_retro`, and cannot explain the
45–73 minute **per-day** figures. The run did encounter three logged public API
429 retries (22.3, 23.0 and 18.9 seconds), and weather coverage caused skips; those
are separate from the repeated book bottleneck. The last clear-to-written-day
residual, including persistence, is only 0.3–1.1 seconds here. COPY and campaign
scoring should therefore move down the list. Scoring's log spans roughly
04:34:01–04:34:42, versus hours clearing; it is not the main target.

These are October production days; the previous offline replay was September
14–15. The 8–18× cross-range wall-time gap is diagnostic, not a matched-date
Postgres-versus-DuckDB benchmark. The extract is windowed, so query scan volume
also need not match the live database. No production query was issued for this work.

## Query-count × latency sensitivity

The original offline four-thread trace recorded **1,919 cold / 1,081 warm SQL
calls per market day**, taking **29.57 / 16.86 seconds** in local execution.
The following is aggregate extra elapsed query service for those counts,
assuming every call pays the stated cost. It is **not measured production RTT**,
and overlapping calls reduce its contribution to wall time.

| Added latency per call | 1,081 calls | 1,919 calls |
|---|---:|---:|
| 1 ms | 1.1 s | 1.9 s |
| 10 ms | 10.8 s | 19.2 s |
| 50 ms | 54.1 s | 96.0 s |
| 100 ms | 108.1 s | 191.9 s |
| 250 ms | 270.3 s | 479.8 s |
| 500 ms | 540.5 s | 959.5 s |
| 1 second | 1,081 s | 1,919 s |
| 2 seconds | 2,162 s | 3,838 s |

**Tens to hundreds of milliseconds of pure network RTT are insufficient to
explain the full gap.** Even 250 ms serialized adds at most eight minutes.
Relative to 241–334 second offline days, the 2,329–4,139 second production excess
would require roughly **1.2–3.8 seconds per call** if all the excess were
serialized query service and these counts applied. With effective overlap, the
required aggregate service is larger. Expensive server scans, server/storage
contention, pool acquisition and lock queues are plausible contributors. Low
Julia CPU says it is waiting; it does not measure CPU or I/O on the DB server.

The tiny observed persistence residual also argues against a uniform large
network RTT: the writer issues 936 row inserts per day, yet the whole non-clear
residual is about a second or less. We need execution/wait breakdowns, not a
claim that every PG call has a 100 ms network hop.

## Which queries and waits to target

`query-families.json` aggregates the existing offline query summaries, preserving
source hashes. Counts include both UTC clears and anchored rebuilds. Execution
seconds exclude waiting for the local DuckDB connection lock.

| Family | Cold calls / s | Warm calls / s | Priority and batching opportunity |
|---|---:|---:|---|
| Feed-anchor last-observation `MAX` | 78 / 6.11 | 78 / 5.70 | Largest warm execution family; **33.8% of warm local SQL**. Two bounds × 39 zones. Batch all zones for each bound: 78→2 calls/day, 1,092→28 per 14-day chunk, before any cross-bound optimization. |
| Generator registry/recent-generation | 156 / 5.05 | 156 / 4.41 | **26.2% of warm SQL**. Two UTC days × 39 zones × outage-on/off variants. Share recent-generation evidence and batch zones: target 156→4 result batches/day, 2,184→56/chunk. Date and outage semantics must remain intact. |
| Analogue historical flow-day relation | 753 / 5.75 | 20 / 0.38 | Dominates cold call count (39.2%). Already keyed by queried historical day across zones and market days, but misses can race. Preload the union of selected analogue dates once per chunk, grouped by date; do not multiply 753 by 14. |
| Fleet/hydro p95 batches | 41 / 2.76 | 22 / 1.52 | Already all-zone queries. Concurrent misses repeat expensive scans; coalesce work for the same (day, lookback, issuance, family). |
| Transmission outages | 4 / 1.15 | 4 / 0.81 | Versioned overlap scans; two dates/two passes. Snapshot complete required versions, or memo by exact delivery/issuance and flags. |
| Published D-1 load | 102 / 0.75 | 102 / 0.33 | 39 first-pass + 12 anchored zones per UTC day. Cache raw zone/date inputs across passes, or fetch the chunk range once. Preserve per-row issuance filtering. |
| Published D-1 RES | 106 / 0.41 | 104 / 0.35 | Same bulk-range opportunity; auxiliary calls make exact totals vary. |
| Reservoir queries | 214 / 0.76 | 214 / 0.64 | Small weekly table repeatedly queried for latest value and historical median. Fetch full required history once and preserve week/zone rules. |
| Registry quarantine warnings | 156 / 0.33 | 156 / 0.30 | Repeated diagnostics for outage-on/off generator variants. Share raw rows; two-date exact memo alone targets 156→78/day; batch whole chunk's eligible registry rows once. Preserve warning behavior if desired. |
| Offered ATC | 128 / 1.19 | 125 / 0.65 | Batch raw window/borders, preserve DA/fallback and publication gates. |
| JAO | 16 / 1.48 | 16 / 0.10 | Existing day cache is intended to help; investigate repeated misses before adding another cache layer. |

The first two families are **60.0% of warm local SQL execution** while making
only 234/1,081 calls. Their production share is **not measured**; a high-count
small query is not automatically the production slow query.

Source evidence explains why adding more zone tasks is insufficient:

- `src/clearing/multi_zone_books.jl` already spawns **one task per zone**. The live
  log shows zone tasks starting together, not a serial outer zone loop.
- `_rescue_window_lower` in `src/generators/registry.jl` holds one process-wide
  `_FEED_ANCHOR_LOCK` across `get!` **and the SQL call**, even for different zone
  keys. The `MAX` scans positive per-unit generation before a bound with **no
  lower time limit**. The 39 independent keys are therefore serialized at this
  stage. Batch them; do not simply increase Julia threads or the PG pool.
- `get_day_outages` similarly holds its lock while computing a shared result;
  this correctly prevents duplicate work for a key, but all zones wait behind
  that initial query. Fetch it once before spawning zones and time it explicitly.
- Fleet/hydro and physical-flow caches check under a lock, compute outside it,
  then publish. Distinct zone tasks can execute the **same cache miss** before
  the first finishes. Key-specific in-flight coordination or ordered prewarming
  reduces that work without serializing unrelated keys.
- `Network.jao_maxbex` has `return` inside a `lock() do` callback whose result is
  discarded by the outer function. That cache-hit path does not return from
  `jao_maxbex`; repeated SQL is visible in the trace. Treat this as a narrow
  cache correctness/performance follow-up with output parity.
- PG uses asynchronous execute/fetch through a default **five-connection pool**.
  The parallel launcher uses two connections per child, four total. It can
  duplicate cold scans while reducing each process's available overlap; there
  is **no evidence that its offline 1.67× gain transfers to PG**.

## Measured per-zone and exact-key reuse

A second diagnostic used the same fixed two-day inputs with optional query and
zone tracing. **All 1,872 prices remain byte-identical** to the original
four-thread baseline. The trace recorded **1,965 / 1,087 calls**, versus the
original 1,919 / 1,081: concurrent cache-miss duplication depends on scheduling,
so query counts are not a fixed property of the model. Raw traces stay in the
private profiling directory; `input-trace-summary.json` contains per-zone totals,
source hashes and duplicate counts.

| Measure | Sep 14, cold | Sep 15, warm |
|---|---:|---:|
| SQL calls | 1,965 | 1,087 |
| Distinct (SQL, parameters, issuance) requests | 1,133 | 736 |
| Exact repeats within issuance | **832 (42.3%)** | **351 (32.3%)** |
| Calls attributed to each zone, across both clears/passes | 40–65 | 17–42 |
| Local execution seconds per zone, cumulative | 0.42–1.23 | 0.24–0.99 |
| Local DuckDB-lock wait seconds per zone, cumulative | 10.93–16.45 | 4.02–7.27 |
| Shared/network SQL outside zone tasks | 32 calls / 3.56 s | 30 calls / 1.16 s |

The lock-wait numbers are **overlapping per-task waits**, not additive wall time,
and are specific to the serialized local DuckDB connection, not measured PG pool
wait. Likewise a zone's cumulative execution covers several builds; it is not the
latency of one query. The trace separately records 102 zone builds/day (39+12
zones per UTC clear); longest individual tasks were 21.84 / 9.48 seconds.

Measured exact-call reductions available on frozen inputs, before broader batching:

| Family | Cold calls→distinct same-issuance requests | Warm calls→distinct same-issuance requests |
|---|---:|---:|
| Historical flow relations | **805→257** | **22→12** |
| Fleet/hydro batch queries | **38→6** | **28→6** |
| Registry warnings | **156→78** | **156→78** |
| D-1 load | **102→78** | **102→78** |
| D-1 RES, including auxiliary reads | **106→82** | **104→80** |
| Reservoir queries | **214→144** | **214→72** |
| JAO | **16→4** | **16→4** |
| Transmission outages | **4→2** | **4→2** |
| Feed anchors | **78→78** | **78→78** |
| Registry membership | **156→156** | **156→156** |

This distinction matters: generic exact-query caching can remove many round trips,
but **does not remove the two largest warm execution families**, whose requests
are already distinct. Batch their different zone keys, optimize their access
paths, or materialize their source inputs.

Across both days, 3,052 calls contain 1,869 distinct same-issuance requests:
**1,183 calls (38.8%)** are exact repeats. Ignoring issuance yields 1,635 distinct
raw SQL/parameter requests, but those extra 234 potential hits are not blanket
permission to reuse context-sensitive results. Freeze/version the source and
cache raw data with the correct cutoff semantics.

If the rest of a 14-day chunk resembled the warm diagnostic, same-issuance exact
caching would remove roughly **5,395 of 16,096 calls (33.5%)**. This is an
extrapolation, not a measured 14-day count: analogue sets, week boundaries and
miss races vary. Existing cross-day flow caching already cuts 805 cold reads to
22 warm reads, so multiplying the cold count by 14 would greatly overstate the
opportunity. The distinct feed-anchor/registry batching target remains another
3,192 calls/chunk, structurally separate from the exact-repeat counts; its
execution-time benefit still needs production measurement.

## Revised ranking and concrete next implementation

1. **Per-chunk immutable input snapshot / batched shared inputs.** Highest
   potential because this removes repeated server scans and query transport,
   while preserving the two issuance-specific clear computations. Start with
   feed-anchor bounds/recent-generation evidence, shared outages and existing
   cache misses, then bulk snapshot the remaining input tables. This is
   medium-to-large effort; exact input coverage and revisions are the risk.
2. **Targeted query batching and cache-miss coalescing** if a full snapshot is
   operationally expensive. Smaller, reviewable steps with phase measurements.
   The feed-anchor/recent-generation batch alone targets **3,192 fewer PG
   calls per 14-day chunk** (3,276→84), but the value is avoided scans as much as
   call count. No speed-up is claimed until measured against representative PG
   query plans or an authorized same-snapshot benchmark. Small-to-medium effort;
   risks are stale keys, duplicate in-flight work, and changed aggregate ordering.
3. **Improve effective zone concurrency after shared waits are removed.** Zone
   tasks already exist; measure pool wait and independent-key contention before
   changing limits. Medium effort/risk: extra server load can make every query slower.
4. **Parallel chunks (#452), still opt-in and off by default.** 1.67× measured
   only with local reads. Useful after input materialization; until then it is
   a secondary experiment, not the recommended remedy for this run. Existing
   implementation is complete; main risks are DB contention and API rate limits.
5. **Weather reuse**, especially repeated campaigns. Already chunk-batched;
   cache exact vintage/coordinates/variables/model responses. Does not remove
   the observed book-construction bottleneck; 429s warn against extra fan-out.
   Small-to-medium effort; vintage/key mistakes can change inputs.
6. **Solver/precompilation**, then writes/scoring. Production solve scopes are
   about 12% of total. Eliminating them entirely would yield only about **1.13×**;
   real improvements are smaller. Writes/scoring are already minor here. Solver
   work is medium-to-large effort with numerical/parity risk; writer batching is
   smaller but has transaction/resume risks and little benefit in this run.

Do not reuse an overlapping UTC clear across issuances: the existing proof shows
61/117 required tail prices change, by as much as €63.94/MWh.

**Potential, not measured snapshot speed:** if production book construction fell
to 20 seconds/day (near the warm local replay), preserving each production day's
actual remaining work gives **6.8–9.7×**, excluding snapshot construction.
At the four-day average, reducing book time by 50% gives **1.79×**, by 90% gives
**4.84×**. Even partial input improvements can exceed parallel-chunk gains.
For a 14-day chunk, use
`T_new = T_nonbook + T_local_book + snapshot_build_seconds / 14`.
At the measured averages, a 20-second local book plus the existing non-book
work is about 394 seconds/day; the snapshot's amortized cost must be included.
These projections mix local September book cost with October production work;
they are planning bounds, not a backend parity/performance result.

A production implementation needs explicit input/read and result/write routing:

- Use an opt-in input snapshot path/manifest, loaded once per chunk; retain PG
  for current resume discovery, live-slice protection and transactional writes.
  `EUPHEMIA_DATA_STORE=duckdb` alone reroutes those reads too and is insufficient.
- Freeze/version the source view, record zone/date coverage, source revisions
  and hashes, publish the completed snapshot atomically, open it read-only.
  Chunk cache keys include the snapshot ID, SQL/parameters or equivalent
  function arguments, issuance, relevant flags, and model/thermometer identity.
- Fetch raw history broad enough for 365-day analogue selection, hydro lookbacks,
  reservoir comparisons, outage version chains and feed-anchored rescue windows.
  A generic 60/90-day per-unit window can silently omit the stale feed's last
  observation or its older 60-day rescue interval. The unbounded anchor probe
  needs complete relevant history or proven equivalent precomputed anchors.
- Preserve stored publication/version timestamps and apply the existing
  ForecastContext per day; freezing source revisions does **not** justify
  sharing results across issuance cutoffs. Do not mutate cached shared frames.
- Benchmark snapshot construction plus two **same** market days against a frozen
  PG source, compare input rows/books and all 1,872 forecast prices. The current
  saved-extract parity proves parallel orchestration, not PG→DuckDB equivalence.
- Record PG pool acquisition, execute/fetch/materialization, row counts, retry
  time and cache/lock waits separately by safe query-family ID and zone. Avoid
  logging credentials or literal parameter payloads in production. A leader
  can then obtain plans for the dominant families; no production EXPLAIN,
  index creation, connection or canary was attempted in this task.

## Reproduction

```sh
python3 test/scripts/analyze_retro_run_log.py SAVED_ACTIONS_LOG production-timings.json
python3 test/scripts/analyze_retro_inputs.py OFFLINE_RESULTS serial4 query-families.json 2026-09-14 2026-09-15
```

The offline harness additionally accepts `RETRO_PERF_TRACE_INPUTS=1`. With the
same saved fixture and read-only settings documented in the main README, it
writes per-query zone, issuance, DuckDB-lock wait, execution time, SQL/argument
hashes, and per-zone build durations. Raw parameters remain local profiling
artifacts. This is diagnostic instrumentation, not a production logging flag;
its extra tracing/compilation overhead must not replace the original benchmark
as the speed measurement.
