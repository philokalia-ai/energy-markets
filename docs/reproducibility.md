# Reproducibility — run the Euphemia counterfactual end-to-end, no Postgres

Euphemia's clearing results are reproducible from a **single, self-contained
data extract** — no database access required. Download it, verify its
checksums, run one command. Everything the model reads (ENTSO-E fundamentals,
TTF gas, EUA carbon) is bundled; the pipeline clears the market, saves prices
to a local file, and scores them against the bundled day-ahead actuals.

> **Read this before you compare numbers.** The `jao.*` flow-based capacity
> tables that cv35 depends on entered the extract builder on **2026-08-26** —
> extracts built or refreshed since carry them, the published frozen artifact
> does not, and on a JAO-less extract the network build silently degrades to
> the pre-cv35 fallbacks. The committed reference metrics were also generated
> at cv24. Both gaps show up as differences against the published cv37 record,
> most visibly on the Core and Nordic zones. See
> [What to expect](#what-to-expect).

## What's in the artifact

- **Footprint:** 39 EU bidding zones.
- **Window:** 2023-01-01 … 2026-06-30 (3.5 years). The 2022 crisis year is
  deliberately out of scope.
- **Format:** a canonical parquet directory (one zstd file per `schema.table`)
  plus `MANIFEST.json` and `SHA256SUMS`; you materialize a runtime DuckDB
  database from it locally. ~5 GB of parquet.
- **Contents:** the ENTSO-E tables the merit-order and multi-zone paths read
  (day-ahead load and wind/solar forecasts, both offered-transfer-capacity
  tables, physical flows, per-type aggregate output, the ~125M-row per-unit
  output table, weekly reservoir filling, the unit registry, unavailability),
  the day-ahead **actuals** used for scoring, `yfinance` TTF and EUA closes,
  and the `simulations` reference caches. Every timestamp is naive UTC.
- **Not in the frozen v1.1 artifact:** `jao.max_exchanges` /
  `jao.hub_net_positions` and `entsoe.unavailability_in_the_transmission_grid`
  (cv35), `simulations.input_corrections` (cv32), `entsoe.actual_total_load`
  (read by the `:v3` flow rule) — all entered the builder after v1.1 was
  frozen. Extracts built or refreshed since carry them.

Column-level documentation with per-table provenance and the known data quirks:
[data-dictionary.md](data-dictionary.md).

**Frozen vs living.** This doc describes the frozen, published artifact. A
*living* extract is kept current by a daily incremental refresh
(`bin/refresh_duckdb_extract.jl` via `.github/workflows/refresh-extract.yml`,
canonical copy `/opt/euphemia/extracts/euphemia-live.duckdb`, pulled with
`bin/extract_store.sh`). Incremental appends gradually degrade the sorted
extract's row-group pruning — results stay correct, scans get slower — so it
gets a monthly full rebuild.

## 1. Download

Artifacts live on the project's public bucket at
**<https://data.philokalia.ai>** (Cloudflare R2), pushed by
`publish-public-artifact.yml` (frozen, manual release) and
`refresh-extract.yml` (living, daily).

| object | what | size |
|---|---|---|
| `euphemia-data-v1.1.tar.zst` | frozen parquet artifact v1.1 (39 zones, 2023-01-01…2026-06-30), sha256 `5b0e90154f21bd2649a060af60545fecf537eb562ac035fe3e687ceb3ebf0992` | ~623 MB |
| `euphemia-live.duckdb` | living extract, refreshed daily 02:00 UTC (`.sha256` sidecar) | ~3 GB |

> **v1.1 caveat:** the `:v3` ex-ante flow rule (default on the EU path since
> cv19) reads `entsoe.actual_total_load`, which entered the extract builder
> *after* v1.1 was frozen. Reproducing cv19+ results needs the **living
> extract**; on v1.1 the flow rule cannot find its load-analogue inputs. v1.1
> remains exact for the cv17-era pipeline it shipped with.

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

`data/extracts/euphemia-public.duckdb` is the **default auto-detect path**:
with the file present and `EUPHEMIA_DATA_STORE` unset, the library selects the
DuckDB backend automatically (Postgres is used only when this file is absent
and `ENERGY_CONN_STR` is set). To be explicit, set `EUPHEMIA_DATA_STORE=duckdb`
and `EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb`.

The extract stays **read-only**: results are written to a separate
`data/results.duckdb` (override with `EUPHEMIA_RESULTS_DB`), so the source data
can never be mutated.

## 4. Reproduce

```bash
# Quick: GR single-zone + the 39-zone EU multi-zone clear, 2026-04-01..05
julia --project=. bin/reproduce.jl --quick

# A custom window (add --single GR to also clear GR alone)
julia --project=. bin/reproduce.jl --range 2026-03-01 2026-03-07 --single GR

# Full: the 3.5-year GR single-zone backfill + monthly-sampled EU multi-zone weeks
julia --project=. bin/reproduce.jl --full --workers auto
```

Days are independent, so `--workers N` clears them in parallel: the coordinator
drops its extract handle to read-only, spawns N workers that each open the
extract read-only, `pmap`s the days with `save_to_db=false`, then persists all
returned prices itself — the results DB is only ever written by one process.
`auto` = half the machine's threads, capped at the day count. For long
multi-zone backfills use `--pipeline`, which decouples the slow book build from
the fast solve; see [backfill-architecture.md](backfill-architecture.md) for
its knobs, measured throughput and identity guarantees.

Each run writes `results/<tier>_report.md` (per-zone corr / MAE / bias) and
`results/<tier>_metrics.csv`.

### Solvers — what the open stack does and does not reproduce

`bin/reproduce.jl` defaults to **HiGHS**, which needs no license.

- **Single-zone** clearing on HiGHS produces metrics identical to Gurobi's.
- **The 39-zone coupled clear** runs in canonical **per-period-decomposed**
  mode since cv20 ([period-decomposition.md](period-decomposition.md)): the
  hourly clears are independent MILPs that HiGHS solves to optimality, and the
  prices are **bit-identical across HiGHS and Gurobi** at 60-minute resolution
  (~511 s/day HiGHS vs ~10 s Gurobi). The monolithic formulation genuinely
  needs Gurobi — HiGHS found no incumbent within an hour on an 80-core box.
- **The cv35 JAO network is the exception to the open-stack promise.** HiGHS
  segfaults on the 108-link problem, so the record path for cv35 and later runs
  on Gurobi. Offline reproduction on the extract does not hit this, because the
  extract carries no JAO data — it clears the smaller pre-cv35 network.

Two notes for HiGHS runs: the indicator-constraint retry rung is Gurobi-only
(the ladder detects the solver and skips it), and the per-day `:p95`-books
fallback is solver-agnostic and still fires.

### What to expect

`--quick` diffs its metrics against the committed reference at
`results/reference/quick_metrics.csv`. **That reference was generated at cv24
and has not been regenerated since**, while cv31, cv32, cv35, cv36 and cv37 all
changed EU-footprint prices — cv35 alone moved footprint MAE from 26.24 to
23.40. Expect the diff to flag drift, and read it as version distance, not as a
broken run. Regenerating the reference at the current version is an open item.

The gap has two separable parts, and it is worth knowing which you are looking
at: **version distance** (the reference is 13 versions old) and, on an extract
built before 2026-08-26, **missing JAO data** — the cv35 network cannot be
built at all and the code falls back silently. The second concentrates in the
Core and Nordic zones. If those zones look far worse than the published record,
check your extract's build date before suspecting the model.

The model is a **competitive counterfactual, not a forecast**: persistent
residuals are candidate findings, not bugs. Current per-zone numbers live in
[model-spec-exante.md](model-spec-exante.md) and the experiment record.

## Two honest caveats

1. **Numerical reproducibility.** Measured against live Postgres runs of the
   same days on the same solver: single-zone prices are **bit-identical**
   (480/480 rows, Δ = 0); the 39-zone clear is ~95% bit-identical with the
   remainder within **€0.01/MWh**. The cause is last-ULP non-determinism in SQL
   aggregates (`SUM`/`AVG`/`percentile_cont`): Postgres and DuckDB reduce in
   different orders, which can flip which of two near-degenerate marginal
   tranches sets a zone-hour's price — a discrete cent-level flip, invisible in
   every reported metric. Cross-border *flows* are a degenerate primal
   (alternative optima) and are not part of the equivalence claim; the prices
   are. Parallel and sequential runs are exactly identical.

   Separately and more seriously: **cv35–37 re-clears are not bit-reproducible
   even against themselves.** Re-clearing a record day drifts up to €23/MWh on
   85 of 936 zone-hours (cv31 passed at 1e-12). Suspects are the JAO /
   net-position path and graded-tranche iteration order. Until it is found,
   scenario studies pair a **fresh baseline arm in the same process**, so
   deltas remain valid even though absolute levels may not re-run identically.

2. **Data licensing.** The ENTSO-E fundamentals and day-ahead prices are
   **ENTSO-E Transparency Platform** data, redistributed with attribution under
   the Platform's terms (non-commercial reuse with attribution). TTF gas and
   EUA carbon are daily closes via `yfinance` (TTF front-month futures; the
   SparkChange Physical Carbon ETC as an EUA proxy). If you redistribute a
   derivative extract, preserve these attributions.

## For maintainers — building the artifact

```bash
# Build the parquet dir + runtime .duckdb + MANIFEST + SHA256SUMS from Postgres
ZONES="AT,BE,BG,CZ,DE_LU,DK1,DK2,EE,ES,FI,FR,GR,HU,LT,LV,NL,NO1,NO2,NO3,NO4,NO5,PL,PT,RO,RS,SE1,SE2,SE3,SE4,SI,SK,IT-NORTH,IT-CNORTH,IT-CSOUTH,IT-SOUTH,IT-Calabria,IT-Sicily,IT-Sardinia,CH" \
  START_DATE=2023-01-01 END_DATE=2026-06-30 AGEN_BACK_DAYS=400 \
  OUT=data/public/euphemia-public.duckdb PARQUET_DIR=data/public/euphemia-data-v1.1 \
  ARTIFACT_VERSION=v1 MAX_SIZE_GB=12 MIN_FREE_GB=60 \
  julia --project=. bin/build_duckdb_extract.jl

# Prove the parquet is content-identical to the Postgres-built DuckDB
PARITY_ONLY=true PARQUET_DIR=data/public/euphemia-data-v1.1 \
  VERIFY_AGAINST=data/public/euphemia-public.duckdb \
  julia --project=. bin/build_duckdb_from_parquet.jl
```

The builder materializes every table `ORDER BY (zone, date)` (the per-unit
table in monthly chunks by `(unit, date)`) so DuckDB row-group zonemaps prune
per-zone/per-day scans, and casts the unavailability table's text timestamps at
build time. It streams the ~125M-row per-unit table in monthly chunks, keeps
the spill workspace on the target filesystem, and aborts gracefully (removing
partial output) if free space would fall below `MIN_FREE_GB`.

Never commit `*.duckdb` / `*.parquet` — `data/` is git-ignored.
