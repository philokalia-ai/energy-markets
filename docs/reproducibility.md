# Reproducibility — run the Euphemia counterfactual end-to-end, no Postgres

The Euphemia market-clearing results are reproducible from a **single, self-contained
data extract** — no database access required. Download the extract, verify its
checksums, and run one command. Everything the model reads (ENTSO-E fundamentals,
TTF gas, EUA carbon) is bundled; the pipeline clears the market, saves prices to a
local file, and scores them against the bundled day-ahead actuals.

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

## 1. Download

```bash
mkdir -p data/public
# Placeholder — replace with the published artifact URL:
curl -L -o euphemia-data-v1.tar.zst https://<published-url>/euphemia-data-v1.tar.zst
tar --zstd -xf euphemia-data-v1.tar.zst -C data/public   # -> data/public/euphemia-data-v1/
```

## 2. Verify checksums

```bash
cd data/public/euphemia-data-v1
sha256sum -c SHA256SUMS      # every parquet file + MANIFEST.json -> "OK"
cat MANIFEST.json            # artifact version, window, zones, per-table rows/bytes
cd -
```

## 3. Materialize the runtime DuckDB

```bash
PARQUET_DIR=data/public/euphemia-data-v1 \
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

Uses **HiGHS** by default (open-source, no license). Gurobi is optional
(`--optimizer gurobi`, needs a license) and typically a few times faster.

### Parallel reproduction (`--workers N|auto`)

Reproduction wall-time lives in the number of DAYS, and days are independent —
`--workers N` clears them in parallel. DuckDB is single-writer but supports any
number of read-only *processes* on one file, so the coordinator drops its
extract handle to read-only, spawns N workers that each open the extract
read-only (with no Postgres environment at all), `pmap`s the days with
`save_to_db=false`, then tears the pool down and persists all returned prices
itself — the results DB is only ever written by one process. `auto` = half the
machine's threads, capped at the day count. With HiGHS there is no license cap,
so day-level parallelism scales freely.

Indicative wall-times (80-core box, HiGHS; a 39-zone multi-zone day is
~10–15 min sequential — dominated by order-book scans of the 125M-row per-unit
table — and a GR single-zone day is ~20 s):

| Tier | 1 worker (sequential) | 8 workers | 40 workers |
|------|----------------------:|----------:|-----------:|
| `--quick` (5 days, single + multi) | ~1 h | ~15 min (5-day cap) | ~15 min (5-day cap) |
| `--range`, 1 week EU multi-zone | ~1.5 h | ~15 min | ~15 min (7-day cap) |
| `--full`, GR 3.5 y single-zone part | ~8 h | ~1 h | ~15 min |
| `--full`, EU sampled weeks (~290 days) | ~2–3 days | ~8 h | ~1.5–2 h |
| full 3.5 y × 39 zones (1,277 days, via `--range`) | ~10 days | ~1.5 days | ~7 h |

(Gurobi shortens the multi-zone solve further; book building is the floor.)

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

1. **Numerical reproducibility.** On the DuckDB path the results are **bit-identical**
   for single-zone clears and match our Postgres production runs to **~1e-12 €/MWh**
   for the multi-zone clear. The residual is last-ULP non-determinism in SQL
   aggregate functions (`SUM`/`AVG`/`percentile_cont`): Postgres and DuckDB sum and
   interpolate in different orders, and that reaches a price only through the
   scarcity factor of a marginal tranche. Cross-border *flows* are a degenerate
   primal (alternative optima) and are not part of the equivalence claim — the
   prices (the duals) are.

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
  OUT=data/public/euphemia-public.duckdb PARQUET_DIR=data/public/euphemia-data-v1 \
  ARTIFACT_VERSION=v1 MAX_SIZE_GB=12 MIN_FREE_GB=60 \
  julia --project=. bin/build_duckdb_extract.jl

# Prove the parquet is content-identical to the Postgres-built DuckDB (no 2nd copy)
PARITY_ONLY=true PARQUET_DIR=data/public/euphemia-data-v1 \
  VERIFY_AGAINST=data/public/euphemia-public.duckdb \
  julia --project=. bin/build_duckdb_from_parquet.jl
```

The builder streams the ~125M-row per-unit table in monthly chunks, keeps DuckDB's
spill workspace on the target filesystem, logs free space before/after each table,
and aborts gracefully (removing partial output) if free space would fall below
`MIN_FREE_GB`. Never commit `*.duckdb`/`*.parquet` — `data/` is git-ignored.
