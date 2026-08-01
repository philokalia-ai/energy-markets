# Reproduce: published-bids clearing validation (GME MGP + OMIE)

This is the full reproduction path for the experiment that feeds **real published
day-ahead auction bids** into the Euphemia clearing engine and checks whether we
recover the **official** clearing price. The question, sample and metrics are
frozen in [protocol.md](protocol.md); the measured findings are in
[results.md](results.md).

There are two entry points:

- **Path A — from source.** Download the raw GME/OMIE books from the exchanges
  yourself, convert them, clear, analyze. Full end-to-end.
- **Path B — from our derived artifacts (no exchange download).** Pull our
  converted order books + per-cell reference from R2 and re-run only the
  **clearing** and **analysis** stages. Enough to verify the headline without
  touching an exchange.

Everything runs with the open-source **HiGHS** solver and, where settled prices
are needed, the **public DuckDB extract** — no Postgres, no license.

---

## 0. Prerequisites

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'      # Euphemia + HiGHS
python3 -m pip install pandas pyarrow requests duckdb     # fetch/convert/analyze
```

The raw exchange downloads and all intermediates live in a **git-ignored** scratch
dir. Point `PUBBOOKS_DIR` at it (any location; `data/` is git-ignored):

```bash
export PUBBOOKS_DIR="$PWD/data/pubbooks"
mkdir -p "$PUBBOOKS_DIR"/{raw,intermediate}
```

The settled-price reads (OMIE conversion only) use the public extract:

```bash
export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_PATH="$PWD/data/extracts/euphemia-public.duckdb"   # see docs/reproducibility.md
export EUPHEMIA_DUCKDB_READONLY=true
```

---

## Path A — from source

### A1. Fetch the raw books (from the exchanges' own public endpoints)

```bash
# GME MGP "Offerte Pubbliche" — the 7 frozen protocol days (Italian zones)
python3 docs/experiments/pubbooks-clearing/fetch_gme.py  --out "$PUBBOOKS_DIR/raw"

# OMIE aggregate curves — the 6 frozen protocol months (Iberian pool)
python3 docs/experiments/pubbooks-clearing/fetch_omie.py --out "$PUBBOOKS_DIR/raw"
```

Both scripts document the exact endpoints, the GME terms-acceptance
(anti-forgery token + `GmePolicy` cookie) handshake, the 7-day GME embargo, and a
reference SHA256 of each file **as we downloaded it (2026-07-30)**. A checksum
mismatch prints a *warning*, not an error: the exchanges occasionally re-export a
day byte-differently. The authoritative integrity check is the R2 `SHA256SUMS`
over our **derived** converted books (§B1) — those are deterministic given the
source rows.

> **Licensing.** GME and OMIE make these books publicly downloadable, but their
> terms do **not** clearly permit redistribution (GME's "Condizioni di utilizzo"
> binds downstream users to the same terms; OMIE requires source attribution and
> consultation-only use). We therefore **never commit or mirror the raw files** —
> you fetch them from the source here. See [results.md](results.md) and the PR for
> the "raw mirror is possible if the owner accepts the terms question" note (their
> call, deliberately not taken).

### A2. Convert raw books → engine intermediate (our SimpleOrder form)

```bash
python3 test/scripts/pubbooks_prep.py both      # or: gme | omie
```

Writes, under `$PUBBOOKS_DIR/intermediate/`:
- `<ex>_orders.tsv` — per-cell `(zone, day, hour, side, price, mw)` order ladders
  (aggregated at identical `(cell, side, price)` — exact for a uniform-price
  clear, ~4× smaller MIP; disclosed in the protocol).
- `<ex>_cells.tsv` — per `(zone, day, hour)` reference row: official price
  `p_off`, net position `net_import_mw`, official awarded supply, ES=PT flag.

OMIE conversion reads settled ES/PT day-ahead prices and physical flows from the
extract (`entsoe.energy_prices`, `entsoe.physical_flows`); GME conversion is
self-contained from the parsed parquet.

Continue at **§Clear** below.

---

## Path B — from our derived artifacts (no exchange download)

### B1. Download the derived converted books + reference from R2

Our derived artifacts are published (owner-dispatched) to
`s3://euphemia-web-data/experiments/pubbooks/v1/` — **DERIVED only**, no raw
exchange rows. Layout (see `MANIFEST.json`):

```
experiments/pubbooks/v1/
  converted/gme/<YYYY-MM-DD>.parquet     our SimpleOrder-format order books
  converted/omie/<YYYY-MM-DD>.parquet
  converted/<ex>_cells.parquet           per-cell reference (official price, net pos)
  metrics/metrics_<ex>_<day>.tsv         our engine-vs-official metric rows
  outputs/analysis.txt                   the frozen metric tables
  MANIFEST.json  SHA256SUMS
```

Pull it into the intermediate dir and rebuild the TSVs the harness reads:

```bash
# maintainers (R2 read creds): aws s3 cp --recursive --endpoint-url "$WEB_S3_ENDPOINT" \
#   s3://euphemia-web-data/experiments/pubbooks/v1 "$PUBBOOKS_DIR/r2"
# (public HTTPS mirror base is recorded in the PR / README once published)
python3 - <<'PY'
import os, glob, pandas as pd
from pathlib import Path
r2 = Path(os.environ["PUBBOOKS_DIR"]) / "r2"
intr = Path(os.environ["PUBBOOKS_DIR"]) / "intermediate"; intr.mkdir(exist_ok=True)
for ex in ("gme", "omie"):
    books = sorted((r2/"converted"/ex).glob("*.parquet"))
    if books:
        pd.concat([pd.read_parquet(b) for b in books], ignore_index=True) \
          [["exchange","zone","day","hour","side","price","mw"]] \
          .to_csv(intr/f"{ex}_orders.tsv", sep="\t", index=False)
    cf = r2/"converted"/f"{ex}_cells.parquet"
    if cf.exists():
        pd.read_parquet(cf).to_csv(intr/f"{ex}_cells.tsv", sep="\t", index=False)
print("rebuilt intermediate/*_{orders,cells}.tsv from R2")
PY
```

You may also verify our published metrics directly (`metrics/metrics_<ex>_<day>.tsv`)
against `SHA256SUMS` without running anything.

Continue at **§Clear**.

---

## Clear — feed the real books into the Euphemia engine

One **fresh Julia process per market day** (protocol §3), HiGHS:

```bash
test/scripts/pubbooks_run.sh GME        # all GME days in *_cells.tsv
test/scripts/pubbooks_run.sh OMIE
# or a single day:  julia --project=. test/scripts/pubbooks_clear.jl GME 2025-01-15
```

Each writes `$PUBBOOKS_DIR/intermediate/metrics_<ex>_<day>.tsv`: per `(zone,hour)`
it records the engine price on the domestic book (`p_dom`), on the book **plus**
the injected net position (`p_net`), an **independent** merit-order crossing
bracket `[p_sup_marg, p_dem_marg]`, and the official price `p_off`.

## Analyze — the frozen metric tables

```bash
python3 test/scripts/pubbooks_analyze.py
```

---

## Expected headline

**GME (Italian zones) — 1,175 scored cells (7 days × 7 zones):**

- **Layer A (solver mechanics):** the engine price lands **inside the valid
  crossing bracket in 100.00% of cells**. On the 76 **well-determined** cells
  (bracket width ≤ €0.5, so the book pins a unique price) the engine hits it
  **exactly — max |Δ| = €0.00** (100% ≤ €0.01). The solver reproduces real
  published auctions exactly wherever the book alone determines the price.
- **Layer B (book → official price):** feeding only the **domestic** book leaves
  a median gap to the official price of **€95.17/MWh**; adding the published
  **net cross-border position** cuts that to **€8.35/MWh** (and to €4.52 on the
  book-determines-price cells). The residual is overwhelmingly attributed to
  **coupling / complex orders** — 77.7% of the >€0.5 cells have the official
  price *outside* the domestic crossing bracket, i.e. set by the coupled solve, not
  the local book — exactly what a single-zone clear of a domestic book cannot
  reproduce, and precisely the value cross-border coupling adds.

**OMIE (Iberian pool):** see the finalized tables in [results.md](results.md)
(headline restricted to uncongested ES = PT hours, per protocol §4).

The `outputs/analysis.txt` on R2 (and your local `pubbooks_analyze.py` run) prints
these tables verbatim.

---

## Files

| File | Role |
|------|------|
| [protocol.md](protocol.md) | frozen question / sample / metrics |
| [results.md](results.md) | measured findings (both exchanges) |
| `fetch_gme.py`, `fetch_omie.py` | download raw books from the exchanges (Path A) |
| `test/scripts/pubbooks_prep.py` | convert raw → SimpleOrder intermediate |
| `test/scripts/pubbooks_clear.jl` + `pubbooks_run.sh` | clear each day, fresh process |
| `test/scripts/pubbooks_analyze.py` | frozen metric tables |
| `stage_r2.py` | build the derived-artifact tree for R2 |
| `.github/workflows/upload-experiment-data.yml` | owner-dispatched R2 push (additive) |
