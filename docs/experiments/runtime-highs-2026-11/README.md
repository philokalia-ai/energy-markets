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

Benchmark CPU affinity 0–7; Julia threads 4, DuckDB threads 4, BLAS threads 1,
DuckDB memory limit 8 GB. Other ops tests run only on 8–15. Package caches exist;
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

Pending final fixed-source matrix. Full cell differences, per-zone scores, gaps and raw logs
are retained in the sprint results directory. The committed summarizer emits
portable CSV tables from benchmark JSON, including all-39 and non-Italian-32
coverage, MAE/bias/correlation, nonpositive-price hits and false alarms.

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

All four configurations passed **1,384** self-contained assertions (the
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
HTTP 410. No workflows were dispatched.

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
