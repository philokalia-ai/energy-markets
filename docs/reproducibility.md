# Reproducibility — run the Euphemia counterfactual end-to-end, no Postgres

The Euphemia market-clearing results are reproducible from a **single, self-contained
data extract** — no database access required. Download the extract, verify its
checksums, and run one command. Everything the model reads (ENTSO-E fundamentals,
TTF gas, EUA carbon) is bundled; the pipeline clears the market, saves prices to a
local file, and scores them against the bundled day-ahead actuals.

> **Frozen vs living.** This doc describes the *frozen, published* artifact.
> There is also a *living* extract kept current by a daily incremental refresh
> (`bin/refresh_duckdb_extract.jl` via `.github/workflows/refresh-extract.yml`,
> pulled/pushed with `bin/extract_store.sh`; canonical copy
> `/opt/euphemia/extracts/euphemia-live.duckdb`). Incremental appends slowly
> degrade the sorted extract's row-group zonemap pruning (correct results,
> gradually slower scans), so the living extract gets a monthly full rebuild —
> see the "Living extract" section of the README.

## What's in the artifact

- **Footprint:** 39 EU bidding zones (the calibrated footprint — SEE, Iberia,
  Italy's 7 sub-zones, the continental core, France, the Nordics, the Baltics,
  the Alpine hubs).
- **Clearing window:** 2023-01-01 … 2026-06-30 (3.5 years).
- **Format:** a canonical **parquet directory** (one zstd file per `schema.table`)
  plus a `MANIFEST.json` and `SHA256SUMS`. Parquet is the published, engine-version-
  durable format; you materialize a runtime **DuckDB** database from it locally.
- **Contents:** the ENTSO-E tables the merit-order and multi-zone paths read
  (day-ahead load & wind/solar forecasts, both offered-transfer-capacity tables,
  physical flows, per-type aggregate output, the ~125M-row per-unit output table,
  the weekly reservoir filling table at full history, the unit registry,
  unavailability), the ENTSO-E day-ahead **actuals** used for scoring, `yfinance`
  TTF & EUA daily closes at full history, and the `simulations` reference caches
  (inferred generator parameters, unit→firm map). Every timestamp is stored as
  naive UTC.

The 2026-04 SEE window is a subset; the full artifact is ~5 GB of parquet.

**Column-level documentation with explicit per-table provenance (ENTSO-E TP
datasets, Yahoo Finance tickers, project-derived tables) and the known data
quirks: [data-dictionary.md](data-dictionary.md)** (bundled inside future
artifacts as `DATA-DICTIONARY.md`).

### Artifact versions

- **v1** — the original published extract.
- **v1.1** — identical tables, rows and values as v1, but re-laid-out for query
  speed: every table is materialized `ORDER BY (zone, date)` (the per-unit output
  table by `(month, unit, date)`) so DuckDB row-group zonemaps actually prune
  per-zone / per-day scans, and the unavailability table's text
  `start/end_outage_utc` columns are cast to `TIMESTAMP` at build time. Row counts
  match v1 exactly (227,848,227 rows); the runtime `.duckdb` is *smaller* (~2.6 GB
  vs ~3.8 GB) because sorted data compresses better. Prices are unchanged to
  floating-point precision: **single-zone clears are bit-identical to v1**, and
  the 39-zone 2026-04-03 multi-zone clear matches v1 to **≤2e-12 €/MWh** (22 of
  936 price cells flip in the last ULP). The residual is the same one documented
  for the Postgres↔DuckDB multi-zone parity: re-ordering the rows changes the
  order in which DuckDB's `SUM`/`AVG`/`percentile_cont` reduce, reaching a price
  only through the scarcity factor of a marginal tranche — invisible in every
  reported metric. v1.1 is
  produced from the v1 parquet with `bin/build_duckdb_v11.jl` (no Postgres); the
  canonical builder `bin/build_duckdb_extract.jl` emits the same sorted layout
  directly from Postgres. **Combined with the query-path code changes
  (`perf/duckdb-query-paths`), a 39-zone day book build drops from ~14 s to
  ~1–3 s** (measured on this artifact; see the changelog / PR for the
  before/after table).

## 1. Download

The artifacts live on the project's public data bucket at
**<https://data.philokalia.ai>** (Cloudflare R2 behind a custom domain),
pushed by `.github/workflows/publish-public-artifact.yml` (frozen artifacts,
manual release act) and `.github/workflows/refresh-extract.yml` (the living
extract, daily). Maintainers can also fetch through the S3 API with
`bin/extract_store.sh pull <name> <dest>` (same env as CI).

Published objects:

| object | what | size |
|---|---|---|
| `euphemia-data-v1.1.tar.zst` | frozen parquet artifact v1.1 (39 zones, 2023-01-01…2026-06-30), sha256 `5b0e90154f21bd2649a060af60545fecf537eb562ac035fe3e687ceb3ebf0992` | ~623 MB |
| `euphemia-live.duckdb` | living extract, refreshed daily 02:00 UTC (`.sha256` sidecar) | ~3 GB |

> **v1.1 + cv19 caveat:** the :v3 ex-ante flow rule (default on the EU path
> since cv19) reads `entsoe.actual_total_load`, which entered the extract
> builder on 2026-07-22 — **after** v1.1 was frozen. Reproducing cv19+/cv20
> results (including the committed `results/reference/quick_metrics.csv`)
> therefore needs the **living extract** (`bin/pull_live_extract.sh`,
> checksummed) or a ≥v1.2 frozen artifact; on v1.1 the flow rule cannot find
> its load-analogue inputs. v1.1 remains exact for the cv17-era pipeline it
> shipped with.

```bash
mkdir -p data/public
curl -L -o euphemia-data-v1.1.tar.zst https://data.philokalia.ai/euphemia-data-v1.1.tar.zst
tar --zstd -xf euphemia-data-v1.1.tar.zst -C data/public   # -> data/public/euphemia-data-v1.1/
```

## 2. Verify checksums

```bash
cd data/public/euphemia-data-v1.1
sha256sum -c SHA256SUMS      # every parquet file + MANIFEST.json -> "OK"
cat MANIFEST.json            # artifact version, window, zones, per-table rows/bytes
cd -
```

## 3. Materialize the runtime DuckDB

```bash
PARQUET_DIR=data/public/euphemia-data-v1.1 \
  OUT=data/extracts/euphemia-public.duckdb \
  julia --project=. bin/build_duckdb_from_parquet.jl
```

`data/extracts/euphemia-public.duckdb` is the **default auto-detect path**: with the
file present and `EUPHEMIA_DATA_STORE` unset, the library selects the DuckDB backend
automatically (Postgres is used only when this file is absent and `ENERGY_CONN_STR`
is set). To be explicit, set `EUPHEMIA_DATA_STORE=duckdb` and
`EUPHEMIA_DUCKDB_PATH=/path/to/euphemia-public.duckdb`.

The published extract stays **read-only**: model results are written to a separate
`data/results.duckdb` (override with `EUPHEMIA_RESULTS_DB`), so the source data can
never be mutated.

## 4. Reproduce

```bash
# Quick: GR single-zone + the 39-zone EU multi-zone clear, 2026-04-01..05
julia --project=. bin/reproduce.jl --quick

# A custom window (multi-zone over the footprint; add --single GR to also clear GR alone)
julia --project=. bin/reproduce.jl --range 2026-03-01 2026-03-07 --single GR

# Full: the 3.5-year GR single-zone backfill + monthly-sampled EU multi-zone weeks.
julia --project=. bin/reproduce.jl --full --workers auto
```

The default optimizer is `auto`, which since cv20 resolves to **HiGHS** — the
open default reproduces the published record exactly (see below). Pass
`optimizer="gurobi"` for the faster development path if licensed.

**Solver reality check (measured):** single-zone clearing works fine on HiGHS
(no license needed) and its metrics are identical to the Gurobi run's. The
**monolithic** 39-zone coupled MIP does need Gurobi — on our 80-core box HiGHS
found *no incumbent* within a 1-hour budget (re-confirmed on the cv15 iter8
books: 886 B&B nodes, primal bound `-inf` at 30 min), while Gurobi clears each
day in seconds. That is why, since cv20, the EU-footprint path runs in
canonical **per-period-decomposed** mode ([docs/period-decomposition.md](
period-decomposition.md)): the 24 hourly clears are independent MILPs that
HiGHS solves to optimality, and the prices are **bit-identical across
HiGHS and Gurobi** at 60-minute resolution (~511 s/day HiGHS vs ~10 s Gurobi)
— the record is solver-invariant, so the fully open stack (public extract +
HiGHS) reproduces it exactly. Two notes for HiGHS runs: (1) the iter8
*indicator-constraint* retry rung is **Gurobi-only** (HiGHS has no indicator
constraints through JuMP) — the retry ladder detects the solver and skips that
rung gracefully; (2) the per-day `:p95`-books fallback IS solver-agnostic and
still fires.

### Parallel reproduction (`--workers N|auto`)

Reproduction wall-time lives in the number of DAYS, and days are independent —
`--workers N` clears them in parallel. DuckDB is single-writer but supports any
number of read-only *processes* on one file, so the coordinator drops its
extract handle to read-only, spawns N workers that each open the extract
read-only (with no Postgres environment at all), `pmap`s the days with
`save_to_db=false`, then tears the pool down and persists all returned prices
itself — the results DB is only ever written by one process. `auto` = half the
machine's threads, capped at the day count.

Wall-times (80-core box; `--quick` measured, larger tiers extrapolated from the
measured per-day costs — GR single-zone ~5 s/day Gurobi / ~20 s/day HiGHS,
39-zone multi-zone ~30–40 s/day Gurobi):

| Tier | sequential | parallel |
|------|-----------:|---------:|
| `--quick` (5 days, single + multi, Gurobi) | **243 s (measured)** | day-cap ~1–2 min |
| `--full`, GR 3.5 y single-zone part (HiGHS) | ~7 h | ~20 min at 40 workers |
| `--full`, EU sampled weeks (~290 days, Gurobi) | ~3 h | ~1.5 h at 2 workers |
| full 3.5 y × 39 zones (1,277 days, Gurobi, via `--range`) | ~12 h | ~6 h at 2 workers |

Note the parallel cap depends on the solver: HiGHS has no license limit
(single-zone scales to any worker count), while Gurobi WLS typically allows
**2 concurrent sessions** — so multi-zone parallel runs cap at `--workers 2`.

### Pipelined multi-zone backfill (`--pipeline`)

`--workers 2` caps multi-zone throughput at 2 whole day-clears in flight, and
each of those interleaves a slow 39-zone book build with a fast Gurobi solve —
the two licensed solver sessions sit idle during every build. `--pipeline`
decouples the stages: `--book-workers M` (default `min(10, CPU÷8)`) processes
build complete per-day book sets in memory ahead of time, and
`--solver-workers S` (default 2 = the WLS session cap) dedicated solver
processes — each holding ONE persistent Gurobi env across all its solves —
consume them back-to-back, including the pass-2 opportunity-anchor re-clears
(only the ~12 anchored zones are rebuilt; every other zone's book is reused
verbatim, exactly as the sequential `passes=2` path). Bounded queues (~8 days
in flight) keep RAM flat; the run is resumable per day (already-saved days are
skipped) and prints per-day
`DAY d DONE status=… book=… waitq=… solve1=… rebuild=… solve2=…` lines plus a
final throughput / solver-utilization summary.

```bash
julia --project=. bin/reproduce.jl --range 2026-01-01 2026-06-30 --pipeline \
    --book-workers 10 --solver-workers 2
```

**Identity guarantee (measured).** The pipeline reuses the exact stage
functions of the sequential path (`mz_build_books` / `mz_solve_pass` /
`mz_extract_anchor_inputs` / `mz_rebuild_anchored`);
`test/scripts/pipeline_identity.jl` verifies 3 days (2026-04-01..03) × 39
zones end-to-end. Measured:

- **DuckDB extract:** pipeline vs sequential **bit-identical** — 2,808
  zone-hour prices, max |Δ| = 0.
- **Postgres, serialized DB access** (`book_workers=1, in_flight=1`):
  **bit-identical** (and sequential-vs-sequential re-runs are themselves
  bit-identical).
- **Postgres, concurrent book builds:** last-ULP noise (≤1e-12 €/MWh) with
  rare near-degenerate marginal-tranche flips (1 zone-hour in 2,808) — the
  same documented mechanism as the Postgres↔DuckDB residual (SQL aggregate
  summation order shifts under concurrent query load), inherent to any
  concurrent clearing against live Postgres (including `--workers 2`), not a
  pipeline artifact. For exactly reproducible backfills, run against the
  DuckDB extract.

Measured on the 10-day 2026-03-01..10 window against a DuckDB extract
(80-core box, Gurobi, 2 solver sessions; `test/scripts/pipeline_benchmark.jl`):

| Mode | wall (10 d) | days/hour | speedup | solver utilization |
|------|-----------:|----------:|--------:|-------------------:|
| `--workers 2` (today's day-parallel) | 289 s | 124.6 | 1.00× | (interleaved) |
| `--pipeline` (2 solvers, 10 book workers) | **202 s** | **178.0** | **1.43×** | 78% / 73% |

The pipeline also absorbs hard days gracefully: 2026-03-01 needed 54 s + 41 s
MPCC solves and the other days kept flowing through the second solver. RAM
stayed flat (≥186 GB free of 256 GB) under the 8-day in-flight bound.

Projected from the measured per-day cost: H1-2026 (181 d) **1.0 h** pipelined
vs 1.5 h day-parallel; the full 3.5 y × 39 zones (1,277 d) **7.2 h** vs
10.2 h. Against live Postgres the absolute times are ~5-10× larger (book
builds dominate: ~200-380 s/day vs ~20 s on the extract), which makes the
pipeline's build-ahead overlap matter even more there — but the extract is the
recommended backfill substrate.

Each run writes `results/<tier>_report.md` (per-zone corr / MAE / bias tables) and
`results/<tier>_metrics.csv`. `--quick` additionally diffs against the committed
reference at `results/reference/quick_metrics.csv` and flags any drift.

### What to expect

- The `--quick` GR single-zone and 39-zone EU metrics should match
  `results/reference/quick_metrics.csv` to well within €0.5/MWh. The v0.2.0
  footprint sits at mean MAE ≈ 24 €/MWh, mean corr ≈ 0.79 on the 2026-04 window
  (per-zone spread documented in `docs/calibration-atlas.md`).
- The model is a **competitive counterfactual**, not a forecast: persistent
  residuals are candidate findings, not bugs. Read the numbers against
  `docs/calibration-atlas.md`.

## Two honest caveats

1. **Numerical reproducibility.** Measured on this artifact against our live
   Postgres runs of the same days (same solver): single-zone prices are
   **bit-identical** (480/480 rows over 5 GR days, Δ = 0); the 39-zone
   multi-zone clear is ~95% bit-identical with the remainder within
   **€0.01/MWh**. The root cause of the residual is last-ULP non-determinism in
   SQL aggregate functions (`SUM`/`AVG`/`percentile_cont`): Postgres and DuckDB
   sum and interpolate in different orders, which can flip which of two
   near-degenerate marginal tranches sets a zone-hour's price (a discrete,
   cent-level flip — invisible in every reported metric). Cross-border *flows*
   are a degenerate primal (alternative optima) and are not part of the
   equivalence claim — the prices are. Parallel (`--workers`) and sequential
   runs are exactly identical (Δ = 0, verified).

2. **Data licensing.** The ENTSO-E fundamentals and day-ahead prices are
   **ENTSO-E Transparency Platform** data, redistributed here with attribution under
   the Platform's terms of use (non-commercial reuse with attribution; see the
   ENTSO-E Transparency Platform terms). TTF gas and EUA carbon are **daily closes**
   sourced via `yfinance` (TTF front-month futures; the SparkChange Physical Carbon
   ETC as an EUA proxy) — attribute accordingly; each is ~1k rows. If you
   redistribute a derivative extract, preserve these attributions.

**Scope note:** the **2022 energy-crisis year is out of scope** of this artifact —
the window deliberately starts 2023-01-01. The model's crisis-year honesty fixes
(v10) are documented separately; per-year GR tables back to 2022 live in the
production Postgres history, not this public extract.

## For maintainers — building the artifact

```bash
# Build the parquet dir + runtime .duckdb + MANIFEST + SHA256SUMS from Postgres
ZONES="AT,BE,BG,CZ,DE_LU,DK1,DK2,EE,ES,FI,FR,GR,HU,LT,LV,NL,NO1,NO2,NO3,NO4,NO5,PL,PT,RO,RS,SE1,SE2,SE3,SE4,SI,SK,IT-NORTH,IT-CNORTH,IT-CSOUTH,IT-SOUTH,IT-Calabria,IT-Sicily,IT-Sardinia,CH" \
  START_DATE=2023-01-01 END_DATE=2026-06-30 AGEN_BACK_DAYS=400 \
  OUT=data/public/euphemia-public.duckdb PARQUET_DIR=data/public/euphemia-data-v1.1 \
  ARTIFACT_VERSION=v1 MAX_SIZE_GB=12 MIN_FREE_GB=60 \
  julia --project=. bin/build_duckdb_extract.jl

# Prove the parquet is content-identical to the Postgres-built DuckDB (no 2nd copy)
PARITY_ONLY=true PARQUET_DIR=data/public/euphemia-data-v1.1 \
  VERIFY_AGAINST=data/public/euphemia-public.duckdb \
  julia --project=. bin/build_duckdb_from_parquet.jl
```

The canonical builder now materializes every table `ORDER BY (zone, date)` (the
per-unit output table in monthly chunks sorted by `(unit, date)`), and casts the
unavailability table's text `start/end_outage_utc` to `TIMESTAMP` — so a fresh
Postgres build already produces the v1.1 layout.

To produce **v1.1 from an existing v1 parquet dir** (no Postgres — just re-sorts
and re-emits), run:

```bash
PARQUET_IN=data/public/euphemia-data-v1 \
  PARQUET_OUT=data/public/euphemia-data-v1.1 \
  OUT=data/public/euphemia-public-v1.1.duckdb \
  ARTIFACT_VERSION=v1.1 \
  julia --project=. bin/build_duckdb_v11.jl   # ~1 min; asserts row counts == v1
```

The builder streams the ~125M-row per-unit table in monthly chunks, keeps DuckDB's
spill workspace on the target filesystem, logs free space before/after each table,
and aborts gracefully (removing partial output) if free space would fall below
`MIN_FREE_GB`. Never commit `*.duckdb`/`*.parquet` — `data/` is git-ignored.
