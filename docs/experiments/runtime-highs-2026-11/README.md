# Julia / HiGHS runtime comparison — 2026-11-14

**Recommended production choice: stable Julia 1.13.4 + HiGHS.jl 1.27.0 / native 1.16.0, with the cv43 JAO prerequisite below.**

The selected production runtime is stable Julia **1.13.4**, HiGHS.jl **1.27.0**, native HiGHS
**1.16.0**. Baseline: Julia **1.12.7**, HiGHS.jl **1.24.0**, native **1.15.0**;
the original manifest was generated with Julia 1.12.6. JuMP **1.30.1** and MOI
**1.51.1** stay unchanged. The release is the
[official HiGHS.jl v1.27.0 release](https://github.com/jump-dev/HiGHS.jl/releases/tag/v1.27.0).

Beta Julia 1.14.0-beta1 is a separate comparison, not the production default.

The fixed-source runtime gate passes: all **2,808/2,808 prices are bit-identical**
between Julia 1.12.7 and 1.13.4 with new HiGHS, all 144 period solves optimal
per arm, and all six capacity maps bit-identical. Per-day MAE/bias are identical
before rounding for both all-39 and non-Italian-32 scopes. The stable runtime
has direct canonical clearing and offline test evidence; beta remains optional
development metadata.

Old/new HiGHS parity on the fixed source is **inconclusive**: the old 1.15
reference was stopped after about 57 minutes without completing one day.
The sprint leader explicitly accepted new HiGHS on its own 144/144 optimal
period solves, no crashes on two 108-link dates, and three externally observed
old-HiGHS crashes in the blocks workstream (`HighsSplitDeque::publishWork`).
Those three crashes were not reproduced by ops. This is an explicit adoption
decision, not a claim of measured old/new price parity.

Both market workflows, `daily-forecast.yml` and
`generate-multi-zone-prices.yml`, now pin Julia **1.13.4**. Data ingestion/archive
workflows are outside this runtime change. No workflow was dispatched. The
licensed Gurobi path was not solved locally because no license was available.


`Manifest.toml` retains Julia 1.12 compatibility; version-specific manifests carry
each newer runtime's bundled-library versions (including Julia 1.14's manifest-2.2 metadata). Julia selects
the matching version-specific file automatically. Other external dependencies
were preserved. Beta was installed through juliaup for **aarch64**; stable 1.13.4 uses the official
aarch64 tarball, SHA-256 checked against Julia's versions.json, installed outside
the shared depot. Retained CI logs show ARM64 runners,
not an assumed x86_64 architecture.

## Measurement scope

Source: `f2ca0db` plus analyst fleet-rescue fix `ac0ab5bfe079` in **every arm**.
Three UTC days: **2026-09-20, 2026-11-04, 2026-11-13**; 39 zones × 24 hours,
enriched JAO/ATC network, canonical per-period decomposition, two opportunity
anchor passes, scoped v3 flows. Legacy record-path inputs with no explicit ForecastContext: a retrospective
controlled runtime comparison, not certified gate-time or pre-gate weather inputs. Source extract is read-only, `save_to_db=false`.
The November days have **108** canonical undirected links; September has **101**.

All canonical A/B arms use **exact production solver settings**: **900 s per
period**, relative gap **1e-6**, **no heuristic-effort override**, canonical EU
decomposition. `bin/daily_forecast.jl`'s `clear_utc_day!` leaves those keywords
unset; the benchmark does likewise and inherits `multi_zone_run.jl` defaults.
Native option probes confirm both HiGHS 1.15 and 1.16 default to heuristic
effort **0.05**, threads **0** (automatic), presolve/parallel **choose**, seed
**0**, MIP feasibility tolerance **1e-6**.
An earlier 60 s / heuristic-0.3 diagnostic is archived separately and excluded
from parity, timing recommendations and production scores. If production's own
limit returns an incumbent, nonoptimal periods/gaps still qualify comparisons.

Old-source references and the aborted old-solver arm use CPU affinity 0–7;
the fixed-source Julia 1.12/new-HiGHS and Julia 1.13.4/new-HiGHS pair run
sequentially on 8–15. All use 4 Julia threads, 4 DuckDB threads, BLAS threads 1,
8 GB DuckDB memory limit; native HiGHS threads stay automatic (8 available cores).
Supporting tests and monolithic runs use 8–15 after the timed runtime pair. Package caches exist;
one timed attempt/day/configuration; first date includes function compilation,
subsequent dates run in the same
process. Different dates prevent interpreting a cold/warm ratio as compilation
cost alone. Methods are instrumented in-process, with production files unchanged.
Native time comes from `MOI.SolveTimeSec`; library body time also includes model
construction; book time covers both builds. Per-day RSS is sampled every 0.2 s;
process high-water RSS and GNU-time totals are separate.

## Order-independent network prerequisite (cv43)

The first runtime comparison exposed a model-input defect: the JAO capacity
approximation reduced shared borders while walking a dictionary of hub limits.
Each directed border participates in its source's outgoing and sink's incoming
limits, so later limits saw already-reduced capacities. Julia dictionary
traversal changes altered 6,446 of 9,696 capacity values on September 20
(maximum 2,069.84 MW), confounding price and speed comparisons.

`Network._scale_jao_net_positions!` now calculates every applicable factor from
original capacities, then applies their minimum once to each border-hour.
Sorted directed keys stabilize summation. If a limit has factor f, every border
contributing to it receives a factor <= f, so the resulting total respects that
limit. The existing JAO-only scope and zero-bound opt-in are retained. The
regression reverses hub, border and row traversal and covers overlapping CCRs.
This is a separate model change for cv43; dependency changes do not belong in
its commit. The leader assembles the code-version bump.

New acceptance matrix: Julia 1.12.7/old HiGHS with old versus fixed source;
fixed-source 1.12.7/old versus new HiGHS; fixed-source 1.12.7 versus 1.13.4 with
matched new HiGHS. The latter two upgrades require capacities within 1e-6
relative, all-optimal solves, daily footprint MAE and bias identical to two
decimals, and explained per-cell differences. ULP-level book drift is reported
rather than rounded away. Both all-39 and non-Italian-32 scores are supplied.

## Timing and price comparisons

The source-fix price impact uses **matched Julia 1.12.7/new HiGHS** before
and after the network patch. Its old-source September result comes from the
original production-settings attempt; the November pair was completed in a
separate process after the old solver exhausted its useful reference budget.
Both sides have all 144 period solves optimal. There are two cold starts in
that composite old-source arm, so its wall times are observations rather than
a controlled source-fix speed ratio. Original old-HiGHS data remains a separate
old-source reference; **fixed-source old/new solver parity is inconclusive**.

The original baseline and original September new-solver attempt preceded the
full-book audit; subsequent attempts include it. Raw wall times therefore do
not isolate production performance across those cohorts. The full-book audit
contributes work outside timed book/native scopes. First
and warm Julia 1.12 days have a ~316–330 s residual; its cause is **unattributed
until the separately authorized post-22:42 profile**. Do not call this compilation,
book construction, a stall, or a production runtime speed improvement.
RSS in the table is sampled; [performance.csv](performance.csv) also provides
cumulative process high-water RSS, gaps, call counts, per-period median/maximum,
startup and residual values. Samples can miss peaks.

### Canonical timings

Native and library values sum **both passes**; residual = wall − books − library scope.

| Config | UTC day | Wall s | Books s | Native s | Library s | Residual s | RSS MiB | Nonoptimal / calls |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| old source / 1.12 / old HiGHS | 2026-09-20 | 1728.0 | 34.6 | 1637.5 | 1651.9 | 41.6 | 3455 | 0/48 |
| old source / 1.12 / old HiGHS | 2026-11-04 | 1348.5 | 15.6 | 1320.5 | 1331.2 | 1.7 | 3680 | 0/48 |
| old source / 1.12 / old HiGHS | 2026-11-13 | 1020.0 | 13.7 | 994.0 | 1004.9 | 1.4 | 3976 | 0/48 |
| old source / 1.12 / new HiGHS | 2026-09-20 | 225.4 | 35.1 | 142.5 | 151.1 | 39.2 | 3318 | 0/48 |
| old source / 1.12 / new HiGHS | 2026-11-04 | 518.0 | 33.8 | 125.0 | 133.5 | 350.6 | 3348 | 0/48 |
| old source / 1.12 / new HiGHS | 2026-11-13 | 446.5 | 14.0 | 122.6 | 127.9 | 304.7 | 3642 | 0/48 |
| fixed / 1.12 / new HiGHS | 2026-09-20 | 523.7 | 33.7 | 151.5 | 160.3 | 329.7 | 3365 | 0/48 |
| fixed / 1.12 / new HiGHS | 2026-11-04 | 520.7 | 15.2 | 181.0 | 187.1 | 318.3 | 3631 | 0/48 |
| fixed / 1.12 / new HiGHS | 2026-11-13 | 526.3 | 13.6 | 190.8 | 196.7 | 316.0 | 3935 | 0/48 |
| fixed / 1.13.4 / new HiGHS | 2026-09-20 | 229.6 | 27.9 | 144.6 | 157.7 | 44.0 | 3408 | 0/48 |
| fixed / 1.13.4 / new HiGHS | 2026-11-04 | 145.1 | 14.2 | 123.9 | 129.2 | 1.7 | 3649 | 0/48 |
| fixed / 1.13.4 / new HiGHS | 2026-11-13 | 327.5 | 15.2 | 304.8 | 310.2 | 2.0 | 4010 | 0/48 |

### Source fix on Julia 1.12 / matched new HiGHS

| UTC day | Zones | n | MAE € old→new | ΔMAE | Bias € old→new | Δbias | Cells >1e-8 | Max |Δprice| € |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-20 | all39 | 934 | 49.28 → 48.53 | -0.75 | -0.42 → -1.55 | -1.13 | 498 | 46.83 |
| 2026-09-20 | excluding_italy32 | 768 | 46.24 → 45.38 | -0.85 | 13.09 → 11.66 | -1.43 | 467 | 46.83 |
| 2026-11-04 | all39 | 936 | 89.82 → 88.19 | -1.62 | -76.96 → -74.88 | 2.08 | 463 | 120.68 |
| 2026-11-04 | excluding_italy32 | 768 | 96.64 → 94.62 | -2.02 | -80.97 → -78.39 | 2.58 | 460 | 120.68 |
| 2026-11-13 | all39 | 936 | 54.57 → 53.72 | -0.85 | -45.18 → -43.85 | 1.33 | 472 | 60.85 |
| 2026-11-13 | excluding_italy32 | 768 | 55.87 → 54.77 | -1.09 | -45.13 → -43.45 | 1.68 | 464 | 60.85 |

### Old-source HiGHS comparison (fixed-source parity inconclusive)

| UTC day | Zones | n | MAE € old→new | ΔMAE | Bias € old→new | Δbias | Cells >1e-8 | Max |Δprice| € |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-20 | all39 | 934 | 49.27 → 49.28 | 0.00 | -0.39 → -0.42 | -0.03 | 13 | 12.58 |
| 2026-09-20 | excluding_italy32 | 768 | 46.23 → 46.24 | 0.00 | 13.13 → 13.09 | -0.04 | 8 | 12.58 |
| 2026-11-04 | all39 | 936 | 89.77 → 89.82 | 0.05 | -76.91 → -76.96 | -0.05 | 5 | 21.75 |
| 2026-11-04 | excluding_italy32 | 768 | 96.58 → 96.64 | 0.06 | -80.91 → -80.97 | -0.06 | 5 | 21.75 |
| 2026-11-13 | all39 | 936 | 54.41 → 54.57 | 0.16 | -44.98 → -45.18 | -0.20 | 12 | 46.21 |
| 2026-11-13 | excluding_italy32 | 768 | 55.67 → 55.87 | 0.19 | -44.89 → -45.13 | -0.24 | 12 | 46.21 |

### Julia upgrade on fixed source / matched new HiGHS

| UTC day | Zones | n | MAE € old→new | ΔMAE | Bias € old→new | Δbias | Cells >1e-8 | Max |Δprice| € |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-20 | all39 | 934 | 48.53 → 48.53 | 0.00 | -1.55 → -1.55 | 0.00 | 0 | 0.00 |
| 2026-09-20 | excluding_italy32 | 768 | 45.38 → 45.38 | 0.00 | 11.66 → 11.66 | 0.00 | 0 | 0.00 |
| 2026-11-04 | all39 | 936 | 88.19 → 88.19 | 0.00 | -74.88 → -74.88 | 0.00 | 0 | 0.00 |
| 2026-11-04 | excluding_italy32 | 768 | 94.62 → 94.62 | 0.00 | -78.39 → -78.39 | 0.00 | 0 | 0.00 |
| 2026-11-13 | all39 | 936 | 53.72 → 53.72 | 0.00 | -43.85 → -43.85 | 0.00 | 0 | 0.00 |
| 2026-11-13 | excluding_italy32 | 768 | 54.77 → 54.77 | 0.00 | -43.45 → -43.45 | 0.00 | 0 | 0.00 |

### Pooled retrospective scores

| Config | Zones | n | MAE € | Bias € | Correlation | ≤0 hits / actual | False alarms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| old source / 1.12 / old HiGHS | all39 | 2806 | 64.49 | -40.79 | 0.7933 | 0/140 | 0 |
| old source / 1.12 / old HiGHS | excluding_italy32 | 2304 | 66.16 | -37.56 | 0.7705 | 0/125 | 0 |
| old source / 1.12 / new HiGHS | all39 | 2806 | 64.57 | -40.88 | 0.7932 | 0/140 | 0 |
| old source / 1.12 / new HiGHS | excluding_italy32 | 2304 | 66.25 | -37.67 | 0.7703 | 0/125 | 0 |
| fixed / 1.12 / new HiGHS | all39 | 2806 | 63.49 | -40.12 | 0.7989 | 2/140 | 0 |
| fixed / 1.12 / new HiGHS | excluding_italy32 | 2304 | 64.93 | -36.73 | 0.7772 | 2/125 | 0 |
| fixed / 1.13.4 / new HiGHS | all39 | 2806 | 63.49 | -40.12 | 0.7989 | 2/140 | 0 |
| fixed / 1.13.4 / new HiGHS | excluding_italy32 | 2304 | 64.93 | -36.73 | 0.7772 | 2/125 | 0 |

Portable artifacts: [every native period/attempt timing](period_timings.csv), [cell differences](price_differences.csv),
[per-zone and pooled accuracy](accuracy.csv), [score deltas](score_deltas.csv),
[price parity](parity.csv), [exact book fingerprints](book_parity.csv),
[book value tolerances](book_value_deltas.csv),
[objective comparisons](objective_comparison.csv),
[mechanical two-decimal criteria](acceptance.csv).
The criteria CSV contains comparisons, not an assertion that source changes
should preserve prices. The intended JAO model change moves prices; the Julia
runtime comparison moves none. Old-source solver differences are not relabelled
as degenerate ties. New-solver acceptance follows the leader's stated stability
and optimality decision despite inconclusive fixed-source old-solver parity.

### Startup and precompile observations

Cache states differ: these are observations, not a controlled compiler speed
ratio. First clear includes additional method compilation. Full raw wall/RSS
records are retained with the sprint results.

| Process | Julia / native HiGHS | Startup to ready s | Euphemia load s |
|---|---|---:|---:|
| old-source baseline | 1.12.7 / 1.15.0 | 16.66 | 7.95 |
| fixed latest on1.12 | 1.12.7 / 1.16.0 | 63.72 | 54.99 |
| fixed latest on1.13.4 | 1.13.4 / 1.16.0 | 30.27 | 22.06 |
| old-source latest November process | 1.12.7 / 1.16.0 | 31.28 | 23.00 |

Pkg precompile calls during setup were approximately 168 s on 1.12, 170.99 s on
1.13.4 and 128.8 s on beta 1.14; package-cache states differ, so do not interpret
those as a benchmark ratio.

## Monolithic experiment

Two November dates on fixed source and stable Julia 1.13.4, same 39-zone books, explicit `decompose_periods=false`,
360 s per native solve and **900 s hard process ceiling/day**. These books have
no inter-temporal block orders yet; this is a size/solver viability test, not
validation of a future block-order formulation.

Both days return `time_limit` with **zero prices**. Each initial installed-fleet
attempt and its p95 fleet fallback returned no incumbent: four native attempts,
all `TIME_LIMIT`, actual native times **377.92 + 360.28 s** and
**362.83 + 360.27 s**. Clear wall was **826.00 s** (November 4) and **810.51 s**
(November 13), within each 900 s process ceiling. Relative gap is undefined
without an incumbent; the solver's textual “0%” is not a usable gap. Process
exit zero means the diagnostic produced a report, not a usable clear.

Retain canonical period decomposition. This experiment does not demonstrate
full-footprint monolithic viability within the stated budget or establish that
future inter-temporal block orders will be tractable.

## Tests

Before the JAO source fix, all four configurations passed **1,384** self-contained assertions (the
1.12 arms ran 1,378 core + 6 fleet-rescue checks separately; beta and stable
also passed the combined 17-file runner). Both newer runtimes passed the
39-zone weather-forecast entrypoint load with autorun disabled.
The new 40-assertion JAO regression passed on Julia 1.12; the fixed stable
18-file combined runner passed **1,424/1,424 assertions in 200.4 s**. Mixed historical DB files are outside this selection. A broad pilot failed
because synthetic database fixtures leaked into later files; the committed
runner restores the original read-only backend after every file. Those pilot
failures are not presented as passing tests.

## Gurobi evidence

No local licensed Gurobi solve was run. Retained Actions logs provided **21**
39-zone two-pass HiGHS forecast clears and **11** five-zone HiGHS price clears,
all ARM64; no retained verified Gurobi run. Four older dispatch candidates return
HTTP 410. No workflows were dispatched. Per-day observations and run links
are in [ci-timings.csv](ci-timings.csv).

| Retained Actions run | Scope / n | Median final-pass s | Median both-pass s | Median total wall s |
|---|---|---:|---:|---:|
| 33058024670 | 39-zone forecast / 7 | 42.96 | 121.46 | 451.53 |
| 33151450276 | 39-zone forecast / 7 | 54.45 | 115.99 | 481.85 |
| 43566629499 | 39-zone forecast / 7 | 43.85 | 96.31 | 462.58 |

These HiGHS CI jobs use different dates/inputs and runner allocation from the
local experiment. The additional 11 five-zone clears are a separate scope;
there is **no verified retained Gurobi observation (n=0)** for a current paired
ratio. Final-pass time alone omits pass 1 and any discarded attempt.

The historical [period-decomposition experiment](../../period-decomposition.md)
uses `@elapsed mz_solve_pass` over one prebuilt 39-zone book, 2026-04-03,
**one pass**, n=1 day per resolution: hourly HiGHS 511 s / Gurobi 7.0 s (~73×);
15-minute HiGHS 1500 s / Gurobi 28.9 s (~52×). Hardware and version details are
not recorded there. This supports a historical comparison, not a current speed
claim for HiGHS 1.16. Production wall and one-pass historical solve times must
not be pooled into a new speed ratio.

## Reproduce

Use an isolated depot and an unchanged read-only extract. In particular,
`EUPHEMIA_DUCKDB_READONLY` must be **`true`**, not `1` (the current library only
recognizes the literal string `true`). Build separate baseline and treatment
environments from their manifests, pointing at the same patched source.

```bash
export JULIA_DEPOT_PATH=/path/to/private-depot
export JULIA_NUM_THREADS=4 OPENBLAS_NUM_THREADS=1
export EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true
export EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb
export EUPHEMIA_RESULTS_DB=/path/to/own-results.duckdb
export EUPHEMIA_DUCKDB_THREADS=4 EUPHEMIA_DUCKDB_MEMORY=8GB
export EUPHEMIA_DUCKDB_TEMP=/path/to/own-spill-directory
export OPS_SOURCE_REVISION=f2ca0db+ac0ab5bfe079+order-independent-JAO
ops_julia=/path/to/julia-1.13.4/bin/julia

taskset -c 0-7 "$ops_julia" --project=. test/scripts/benchmark_runtime_upgrade.jl \
  results/stable13.json decomposed 2026-09-20 2026-11-04 2026-11-13
"$ops_julia" --project=. test/scripts/runtime_upgrade_core.jl
python3 test/scripts/summarize_runtime_upgrade.py results /path/to/extract.duckdb
python3 test/scripts/compare_runtime_books.py results
```

The optional scoring command needs Python's `duckdb` package and opens the
extract read-only. Settlement scoring follows the existing revision-deduplicated
hourly-average methodology, with UTC dates and explicit coverage counts.

Full-book audit dumps can be enabled with `OPS_BOOK_DUMP_PREFIX=/path/to/config`.
Use names `old12`, `new12`, and `stable13` for the fixed-source three-arm matrix;
retain the old-source reference as `baseline.json`. `compare_runtime_books.py`
reports exact differences and maximum absolute MW and relative capacity error.
Book fingerprints and full dumps add audit/compilation overhead; report the
residual outside timed books and native/library solves separately. In
particular, first-call wall differences are not pure compiler or solver gains.
