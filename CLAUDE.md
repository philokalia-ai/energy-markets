# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Julia project implementing the **Euphemia** energy market clearing engine, focusing on electricity market simulation and optimization. The project models day-ahead electricity markets with support for unit commitment, bidding strategies, and network constraints.

## Working agreement (DRAFT 2026-08-24 — replaces the retired rule set; ≤ 8 rules, on one screen)

What this program is for: a **competitive counterfactual of the day-ahead
market whose job is to make market conduct visible**. Deviations of settled
prices from a physically right model are the finding. A better score is
evidence; it is not the goal and never the verdict.

1. **Disagree early, then commit.** Objections, doubts and "there's a cheaper
   way" are raised ONCE, at the prompt, with the cost stated. Once the owner
   decides, execute — never stop mid-task citing a rule, a gate, or a file.
   A surprise found mid-task is reported in the result, and work continues
   unless it is irreversible or unsafe.
2. **The owner sets the mode at the prompt.** *Explore*: work autonomously,
   come back with ideas AND the evidence for them. *Research this*: the idea is
   the owner's; come back with the numbers. If the mode is unclear, ask one
   question at the start — not later.
3. **Physics beats scores.** A mechanism that is physically right is not
   rejected because an aggregate metric moved. Evaluate it where it acts
   (the hours/zones/regime it touches), and state plainly what the evaluation
   covers — which days, hours, zones, how many cells — so the owner can judge
   what the number means. Ship/no-ship is the owner's call, on numbers they
   understand.
4. **Ex-ante inputs, always.** Every input is one that existed before the
   auction gate. This is the only invariant the conduct claim cannot survive
   without: with it a calibrated parameter is a market characteristic,
   without it it is leakage.
5. **No circles.** Every line of work carries a budget stated up front (wall
   time, cells, or attempts). When it is spent, stop and report what was
   learned — do not re-run with new knobs. A failed idea is written down in
   one paragraph and left.
6. **Report what actually ran.** What was measured, what was skipped, and
   why — short, with the counts. No numbers without their coverage.
7. **Everything saved is labelled, nothing live is overwritten.** Results
   carry a `clearing_mode` / `code_version`; live vintages are immutable; a
   refill is labelled as such.
8. **This list does not grow.** Adding a rule means removing or merging one.
   Lessons go to `docs/experiments/`, not here.

*Deliberately not re-added* (pull back what you want): preregistered gates and
Set A/Set B holdouts; the per-zone MAE/corr envelope; kill-switch gating and
bit-identity harnesses as a requirement; fresh-process-per-cell; the
long-running-pipeline supervision rules. Engineering conventions that survive
(file layout, switch style) belong in `docs/code-map.md`.

## Core Architecture

`Euphemia` implements the day-ahead clearing (economic surplus maximization,
MPCC solver), the calibrated ex-ante merit-order book, ATC network modeling,
multi-zone clearing with cross-border flows, and the data-access layer. Since
cv25 the `:merit_order` book is the only order method (the UC path was deleted).

**Where things live:** [docs/code-map.md](docs/code-map.md) — the third-party
reader's guide (what lives where, what calls what, where to start per task).
Large concerns are split into per-topic files `include`d by a thin parent in
definition order (`src/Euphemia.jl` + `src/clearing/`, `src/MeritOrderBook.jl`
+ `src/merit_order/`, `src/Generators.jl` + `src/generators/`, `src/dbutils.jl`
+ `src/db/`, `src/MPCC.jl` + `src/mpcc/`).

**Lazily-loaded notes** (read them when you work there — they hold the gotchas):
- `src/generators/CLAUDE.md` — ENTSO-E registry data-quality rules (stale
  `valid_from`/`valid_to`, overlapping duplicates, outage handling, the day-level
  outage cache + per-zone memoization) and the SRMC/TTF/EUA cost model.
- `src/db/CLAUDE.md` — Postgres vs DuckDB backends, the SQL dialect rewrite,
  DuckDB query-path performance, building an extract, `ensure_indexes`.
- `.claude/skills/backfill` — the pipelined multi-zone backfill runner
  (`run_pipelined_backfill`, order-book capture, DuckDB→Postgres transfer).
- `.claude/skills/scenarios` + [docs/scenario-api.md](docs/scenario-api.md) —
  the five scenario hooks (`ZoneScenario`), strategist/firm map, multi-zone
  scenarios, labelling and comparing runs, accuracy evals.
- [docs/code-version-ledger.md](docs/code-version-ledger.md) — the
  `simulations.*` schema notes and the full per-version `code_version` history.

## Data store (Postgres or a DuckDB extract)

By default the library reads the live Postgres `energy` database; it can instead
read a self-contained **DuckDB extract** mirroring the same `schema.table` names,
so single-zone pricing, scenarios AND the full 39-zone multi-zone EU clearing run
offline. Auto-detection at load (`EUPHEMIA_DATA_STORE` unset): DuckDB if
`data/extracts/euphemia-public.duckdb` exists (path override
`EUPHEMIA_DUCKDB_PATH`), else Postgres if `ENERGY_CONN_STR` is set, else a clear
error. Explicit env always wins; `configure_data_store!(backend=...)` switches at
runtime. The extract is **read-only** — market results persist to a separate
`data/results.duckdb` (`EUPHEMIA_RESULTS_DB`), ATTACHed as `results_db`.
`data/` is git-ignored — never commit `.duckdb`/`.parquet` files. Prefer the
extract for experiment work (faster, cannot disturb production); public build +
reproduce flow: [docs/reproducibility.md](docs/reproducibility.md).

**Postgres config:** the connection string is read from `ENERGY_CONN_STR` in
`.env` (`src/db/postgres_core.jl`) — not `DATABASE_URL`. The ENTSO-E tables are
populated by an external ETL and have no indexes by default; run
`Euphemia.ensure_indexes()` once (30–60 min first time, instant afterwards).

## Solvers and CI

`optimizer="highs"` is the default (open-source; canonical EU-footprint mode is
per-period decomposition, bit-identical across solvers since cv20); Gurobi is
the development option (`optimizer="gurobi"`, academic WLS license, ~50× faster
on the EU footprint). Workflows live in `.github/workflows/` — the two that
matter: `generate-multi-zone-prices.yml` (daily 3 AM UTC) and
`daily-forecast.yml` (06:30 UTC, pre-gate 7-lead ex-ante forecast, see
docs/experiments/pregate-7lead.md); all support `workflow_dispatch`.

## Tests

`julia --project=. test/runtests.jl` runs the core suite (~4 min; DB access
needed). `test/manual/` are DB-dependent long-running tests run by hand,
`test/scripts/` are diagnostics/benchmarks/identity guards (e.g. the
bit-identity harnesses referenced in the methodology), `test/archive/` is
deprecated. Format with JuliaFormatter (`format(".")`).

## Data Sources

- ENTSO-E Transparency Platform (`entsoe.*`: units, D-1 load and RES forecasts,
  offered ATC implicit/explicit, outages, physical flows, per-unit output).
  Column gotchas (`out_map_code` vs `out_area_code`, `area_type_code` combined
  values, `asset_code`, text outage timestamps) are in
  [docs/data-dictionary.md](docs/data-dictionary.md).
- `yfinance.ttf_f` / `yfinance.eua_co2` (TTF and EUA closes, ceres ETL, Tue–Sat).
- Weather DB (hourly temperature/wind/solar, 1,851 GR cities) — see
  [READING_WEATHER_DATA.md](READING_WEATHER_DATA.md).
- EnEx Group (Greek market participants).

## Simulations schema (`simulations.*`)

`energy_prices` is unique on `(date_time_utc, bidding_zone, contract_type,
order_method, clearing_mode, code_version)`; `clearing_mode` labels the run
(`single_zone`, `multi_zone`, `multi_zone_eu`, scenario labels…) and
`code_version` the model version — **current `ENERGY_PRICES_CODE_VERSION` = 32**
(`src/db/postgres_core.jl`; 4 for `optimization_runs`). Bump it for every model
iteration that gets a backfill (each version is one selectable "Run" in the
Metabase dashboard); scenario runs never bump it — they are labelled by
`clearing_mode`. `optimization_runs` uses `bidding_zone='MULTI_ZONE'` for
multi-zone runs. The `simulations.uc_*` tables still hold data but nothing writes
them since cv25. Per-version history, what shipped / measured NO-SHIPs, and the
kill-switch env vars: [docs/code-version-ledger.md](docs/code-version-ledger.md).
