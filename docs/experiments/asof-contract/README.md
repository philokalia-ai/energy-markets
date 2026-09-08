# As-of input contract (issue #368) — source inventory and publication audit

**Status:** Phase 1 (this branch, `feat/asof-contract`). Inventory of every
market input the library reads, what publication/revision information the
data store actually holds for it, and a measured audit of how much of the
stored record post-dates the D-1 auction gate. Code changes in this phase are
listed in §5. Budget for the phase: one session (~3 h wall); what was skipped
is in §7.

Probe scripts are in `scripts/`, raw outputs in `output/`. Every number below
carries its window and row count. All DB access was read-only Postgres.

---

## 1. The gate, and how the code computes it today

The SDAC day-ahead auction closes at **12:00 CET/CEST** on D-1. In UTC that is
**10:00 in summer (CEST) and 11:00 in winter (CET)**.

The only vintage filter in the library today is the cv34 outage gate in
`src/generators/registry.jl` (the `vers` CTE): a version counts if
`version_publication_timestamp_utc::timestamp < $1::timestamp - INTERVAL '14 hours'`,
i.e. **D-1 10:00 as a naive timestamp**, applied to delivery days from
2025-10-01 (the seam; before it the column holds ETL ingestion time).

Two facts about that expression, both verified this session
(`output/05_post_gate_share_utc.txt`):

- `version_publication_timestamp_utc` is `timestamp with time zone`. The
  Postgres session (and server) time zone is **Europe/Berlin**, so `::timestamp`
  yields Berlin wall-clock time and the gate is effectively **08:00 UTC in
  summer / 09:00 UTC in winter** — one to two hours stricter than the auction.
  Conservative, not leaky.
- The DuckDB extract stores every timestamp as **naive UTC**
  (`src/db/CLAUDE.md` line 82; the dialect rewrite strips `AT TIME ZONE
  'UTC'`), so the same SQL evaluates the gate at **10:00 UTC** there. **The two
  backends admit a different set of outage versions.** Over delivery days
  2025-10-01..2026-08-31 (1,086,377 version rows): 174,928 versions pass the
  gate as evaluated on Postgres, 218,603 pass at an explicit 10:00 UTC. That
  is a backend-dependent input, hence a bit-identity hazard between a Postgres
  run and an extract run of the same day.

Everything else (load, RES, ATC, actual generation, hydro fill, fuels, JAO)
has **no** vintage filter: the reader takes whatever revision the table holds.

## 2. Source inventory

Column facts from `scripts/01_columns.py`; timing facts from
`scripts/02_update_time_semantics.py` and `05_post_gate_share_utc.py`
(window 2026-06-01..2026-08-31 unless stated).

| Source (table) | Used for | Delivery time | Publication / revision info in store | Revisions kept? | Publication stamp is real from |
|---|---|---|---|---|---|
| `entsoe.day_ahead_total_load_forecast` | demand book | `date_time_utc` | `update_time_utc` (ENTSO-E UpdateTime of the stored revision) | **No** — one row per slot, latest wins | delivery ≈ **2025-11** (Jul–Oct 2025 rows carry the 2025-09-28/10 backfill stamp) |
| `entsoe.generation_forecasts_for_wind_and_solar` | RES ladder | `date_time_utc` | `update_time_utc`, but the row also holds `intraday_` and `current_` forecasts that keep updating on D | No | never usable for the D-1 column: 52.5 % of rows (704,049 BZN rows, D-1 value non-null) were last updated **after delivery start** |
| `entsoe.offered_transfer_capacities_implicit` | ATC (non-JAO borders) | `date_time_utc` | `update_time_utc`, `instance_code`, `sequence` | No | 2026 |
| `entsoe.unavailability_of_production_and_generation_units` | outages | `start/end_outage_utc` (text) | `version`, `version_publication_timestamp_utc`, `update_time_utc` | **Yes** (every version is a row) | 2025-09-28 (documented seam) |
| `entsoe.aggregated_generation_per_type` | p95 activity probes, fleet truth | `date_time_utc` | `update_time_utc` (median 45 min after the hour in 2026) | No (types share keys; single revision) | 2026-01 |
| `entsoe.actual_generation_output_per_generation_unit` | per-unit activity | `date_time_utc` | `update_time_utc` (median 5.3 days after delivery) | No | 2025-09 |
| `entsoe.aggregated_hydro_storage_filling_rate` | water value | ISO `year/week` | `update_time_utc` | No (per zone-week, latest) | 2026 |
| `entsoe.production_and_generation_units` | registry | `valid_from/valid_to` | `update_time_utc` | valid-range rows | — |
| `entsoe.physical_flows`, `entsoe.actual_total_load` | analogue flows, evals | `date_time_utc` | `update_time_utc` | No | 2026-02 |
| `jao.max_exchanges`, `jao.hub_net_positions` | Core MaxBEX / net-position bounds (cv35) | `date_time_utc` | `fetched_at`, `last_modified_utc` (populated only from delivery 2026-08-23) | No | 2026-08-23 |
| `jao.final_domain` | not read yet (#365) | `mtu` | `fetched_at` only | — | — |
| `yfinance.ttf_f`, `yfinance.eua_co2` | SRMC | `date` (close) | none needed: a close dated D-2 existed at the D-1 gate | n/a | by construction |

## 3. What the audit found, per source

### 3.1 D-1 load forecast: many TSOs publish it after the gate

Share of stored BZN rows whose `update_time_utc` is after D-1 10:00 UTC,
2026-06-01..2026-08-31 (325,490 rows, 47 zones), with the median time-of-day
(UTC, on D-1) at which the stored revision was written:

| Post-gate share | Zones (median D-1 publication time UTC) |
|---|---|
| ≥ 98 % | AL 14:10, XK 12:00, SK 12:55, LT 13:05, **ES 21:30**, **FI 20:35**, **GR 15:05**, PT 14:05, MK 14:10, ME 11:40, MD 17:10, RO 11:35, BE 12:50, DK1/DK2 09:55 (re-published on D), HU 12:40, HR 14:40, **DE_LU 13:35**, BA 11:25 |
| 74–94 % | AT 10:35, LV 12:45, **FR 14:00**, GE 12:50 |
| ≤ 21 % | CY 07:57, SI 09:55, SE1–4 07:50, EE 07:10, BG 07:05, CH 08:50, CZ 08:05, NO1–5 08:00, PL 07:30, RS 06:20, IT-* 04:05, NL 07:15 |

DE_LU has exactly one stored update per delivery day, at 13:35 UTC on D-1
(2026-08-22..29, `output/04_jao_and_per_day.txt`). With one revision kept we
cannot tell "first published at 13:35" from "revised at 13:35"; either way the
stored value is **not shown to have existed at the gate**. Monthly, the
post-gate share of all BZN rows is 46–55 % from 2025-12 onward; before
2025-11 it is 100 % because the stamp is the backfill time.

Consequence: for roughly half the footprint's load-weight (DE_LU, FR, ES, GR,
BE, HU, FI, …) the "ex-ante D-1 load forecast" in the record is a
**post-gate-published TSO forecast**. It is still a forecast, not an
observation — the leak is the TSO's extra hours of weather information, not
the outcome — but it fails rule 4 as written, and the pre-gate value is not
recoverable from this store. The weather-track load model
(`docs/experiments/pregate-7lead.md`, β1) is the pre-gate substitute; the
historical counterfactual needs the honest label instead.

### 3.2 RES D-1 forecast: publication time unknowable

The table keeps one row per slot holding D-1, intraday and current forecasts;
`update_time_utc` moves whenever any of them changes. 52.5 % of rows were last
updated after delivery start, 96.9 % after the gate (same window as above). The
D-1 column's own publication time is not stored. Status: **unverifiable**
(latest revision). Same remedy as 3.1.

### 3.3 Offered ATC (implicit): stored revision is the 13:00 UTC re-publication

For every non-JAO border read from `offered_transfer_capacities_implicit`, the
median stored `update_time_utc` on D-1 is 13:00 UTC (IT/AT/DE_LU/FR/NL/…) or
19:55 UTC (NO/SE/DK2/SI/SK/CZ/HR/HU/BE), with 74–100 % of rows post-gate
(3,147,408 rows). ENTSO-E re-publishes the offered-capacity series after the
auction; whether the pre-gate figure differed is not knowable from one
revision. Status: **unverifiable**. On Core borders cv35 reads JAO instead
(3.6).

### 3.4 Outages: gated from the seam, backend-dependent gate, pre-seam leak

- Versions published between the gate and the outage start (the ones the gate
  must exclude): 5,600–11,700 per month from 2025-11 (`output/03_*.txt`).
  Version-1 messages first published *after* the outage started (forced
  outages reported ex post): 4,700–8,700 per month. Before the seam all of
  these are admitted — the pre-seam record knows forced outages before they
  happened. Magnitude on price not measured (no pre-seam timestamps exist to
  replay against).
- The `::timestamp` cast makes the gate 08:00/09:00 UTC on Postgres and 10:00
  UTC on the extract (§1). Fix: compare in explicit UTC in both dialects.

### 3.4b Outage queries are nondeterministic on main (found while verifying this branch)

Trying to show the legacy path bit-identical between this branch and main
failed — and main is not identical to **itself** either
(`output/07_main_self_reproducibility.txt`): two runs of unchanged main code
on unchanged data (2025-08-20, no row touched since May) give different
DE_LU books (8,380 → 8,378 order values, sums 12.699 M vs 12.625 M) and
different `tx_outage_caps` sums for 2026-08-20 (2.541 M vs 2.615 M MW·h).
GR/NO4 reproduce; DE_LU and the transmission caps do not.

Cause (`scripts/07_outage_duplicate_rows.py`): an ENTSO-E outage message
is stored as **one row per time-series interval** — the same
`(instance_code, version)` repeated with different `available_capacity_mw`
(example: message `0DJLlZnIqrsQN7lAOmDEbQ` v1, 368 / 90 / 20 / 87 MW over
its intervals, `start_time_series_utc` differing, `start_outage_utc` the
same). Both outage readers rank rows with
`ROW_NUMBER() OVER (PARTITION BY instance_code ORDER BY version DESC)` and
keep `rn = 1`: with ties, Postgres returns whichever row the scan produced.
Counts for messages overlapping the day:

| Delivery | (instance, version) groups | with > 1 row | rows disagree on capacity / NTC |
|---|---|---|---|
| 2026-08-20, generation | 9,634 | 6,388 | **1,445** |
| 2025-08-20, generation | 11,397 | 7,134 | **1,335** |
| 2026-08-20, transmission grid | 28,792 | 15,163 | **7,902** |

So the "available capacity of the latest version" is a random pick among
that message's intervals, once per process (the day cache pins it). This is
a legacy defect, independent of the context: the branch's queries keep the
same shape and inherit it. The physically right reading uses the interval
columns (`start_time_series_utc`/`end_time_series_utc`) per hour — which is
also what #366's "native MTU availability" and this issue's acceptance check
on short outages ask for. It changes the record (a code_version bump), so it
is not done here; it is filed as its own issue. Until it is fixed no
bit-identity harness on the book can pass for outage-heavy zones, and the
cv35–37 non-reproducibility note in the ledger has a simpler suspect than
the JAO or graded-tranche iteration order.

### 3.5 Actual generation used at D-1

`get_type_output_p95` and the per-unit activity probes read
`aggregated_generation_per_type` / `actual_generation_output_per_generation_unit`
with `date_time_utc < delivery-day 00:00 UTC`, i.e. **including D-1 evening**.
At the gate, aggregated generation is published through roughly D-1 09:00 UTC
(median 45 min latency), per-unit output through about D-6 (median 5.3 days).
A 30-day p95 barely moves for 15 hours of data; a same-day activity probe
does. Fix: end the window at `gate − source latency`.

### 3.6 JAO: pre-gate by construction; verifiable only from 2026-08-23

`last_modified_utc` is NULL for every row before delivery 2026-08-23. Where
present (Aug 23..Sep 8, 94,736 rows) it sits at ~07:45 UTC on D-1, 0 % after
the gate. The live ETL now fetches at ~08:07 UTC on D-1 (`fetched_at`), i.e.
before the gate; the 2025-07..2026-08 history was fetched in one backfill on
2026-08-25. Status: **verified from 2026-08-23**, unverifiable-but-plausible
before (JAO publishes the final domain before the auction as a rule).

### 3.7 Hydro reservoir fill: weekly, published 1.4–2.9 days after the week

Median lag from ISO-week end to first appearance, 2026 weeks 1–35: FR 1.4 d,
ES 2.4 d, PT 2.5 d, NO4 2.6 d, CH 2.9 d; AT 95 d and SE1 122 d (published in
bulk, months late). Whatever week the reader picks, the as-of rule must be
"latest week whose first publication ≤ issuance", not "latest week ≤ delivery".
Which rule the reader applies today: see §5 (reader map).

### 3.8 Fuels

TTF/EUA closes are date-stamped; the D-2-close rule is ex-ante for lead 1. For
leads > 1 the issue's step 5 applies (use the close available at issuance, not
target-relative). Where the forecast driver does this today: §5.

## 4. Classification policy (what a run can honestly claim)

Per source × zone × delivery day, the context computes one status:

| Status | Meaning |
|---|---|
| `verified` | publication timestamp present, real, and ≤ as_of |
| `post_gate` | stamp present and real, > as_of (the stored revision post-dates issuance) |
| `unverifiable` | stamp absent or not meaningful for this field (RES D-1 column; JAO before 2026-08-23; ATC single revision) |
| `legacy_stamp` | stamp is a backfill/ingestion time (load before 2025-11, outages before 2025-10-01) |
| `latency_policy` | no stamp; window truncated by a documented source latency (actual generation, hydro fill) |

A run's manifest carries the count of each status per source. "Verified
as-of replay" is claimable only for a (source, zone, day) cell with status
`verified` or `latency_policy`; everything else stays labelled.

## 5. Code in this phase

Design rule: **outside a context nothing changes** — same SQL text, same
cache keys, same values — so the cv37 record and every scenario label stay
reproducible. Inside a context the readers below change only what §3 showed
they can honestly change, and everything records its status in the audit.

### 5.1 `src/ForecastContext.jl` (new, included right after `dbutils.jl`)

- `ForecastContext(delivery, as_of_utc, lead, gate_rule, label)`;
  `gate_context(day; rule)` (lead 1, issuance = the gate) and
  `issuance_context(day, lead; issue_time=06:30)` (issuance = D-lead at the
  daily run time, the `retro_of_utc` convention of `bin/daily_forecast.jl`).
- `auction_gate_utc(day; rule=:fixed_10utc | :auction_local)`: the record's
  fixed D-1 10:00 UTC, or 12:00 Europe/Brussels with the EU DST rule (10:00
  UTC CEST / 11:00 UTC CET; the regime in force at the gate instant, so a
  transition-Sunday D-1 is already in the new regime by noon). No
  TimeZones.jl — the same pure rule `bin/forecast_common.jl` uses for Athens.
- Dynamic scope: `with_context(f, ctx)` installs the context as a
  `Base.ScopedValues.ScopedValue`; `current_context()` is `nothing` outside;
  spawned tasks inherit it; it is gone when `f` returns. `ctx_key()` is what
  readers add to cache keys (the issuance instant).
- Classification: `SOURCE_STAMP_REAL_FROM` (from §2), `stamp_status`,
  `classify_stamps!`, `record_asof_status!`, `asof_audit()`,
  `asof_audit_table()`, `reset_asof_audit!()`.

### 5.2 Readers

| Reader | Legacy (no context) | Inside a context |
|---|---|---|
| `get_day_outages` (`src/generators/registry.jl`) | unchanged SQL (session-TZ `::timestamp` gate) | gate = `(version_publication_timestamp_utc AT TIME ZONE 'UTC') < as_of` bound as `$2` — backend-independent; pre-seam/NULL branches unchanged; audit `:verified` from the seam, `:legacy_stamp` before |
| `get_generators` memo | key `(zone, day, flags)` | key gains `ctx_key()` |
| `tx_outage_caps` (`src/Network.jl`) | unchanged | same explicit-UTC gate; cache key gains the issuance; audit as above |
| `jao_maxbex` | unchanged | audit only: `:post_gate` when issuance is before D-1 08:00 UTC (leads > 1 — the table did not exist yet), `:verified` from 2026-08-23, `:unverifiable` before |
| `_type_p95_all_zones`, `_hydro_avail_all_zones` (`src/merit_order/fleet_data.jl`) | window `[D-lookback, D)` | upper bound `min(D 00:00, as_of − 1 h)` (aggregated-generation latency); cache key gains the issuance; audit `:latency_policy` |
| `get_ttf_price`, `get_daily_eua_price` (`src/generators/fuel_costs.jl`) | D-2 close via `_gate_lag_days()` | last close dated `< Date(as_of)`: identical to legacy for lead 1, D-L-1's close for lead L (was target-relative D-2); separate `*_CACHE_ASOF` dictionaries keyed by cutoff |
| `get_loads` (`src/Loads.jl`) | unchanged | SELECT adds `update_time_utc AT TIME ZONE 'UTC'`; every row classified (`:verified`/`:post_gate`/`:legacy_stamp`); **values unchanged** — there is no pre-gate revision to fall back to |
| `get_generation_forecast_for_wind_and_solar` (`src/Renewables.jl`) | unchanged | audit `:unverifiable` per row |

Not touched in this phase (they read whatever the store holds, in and out of
a context; listed so the audit's silence about them is not mistaken for a
verdict): offered ATC in `flows_imports.jl` and `Network.jl` (the opt-in
`EUPHEMIA_ATC_ASOF` remains the only knob), `jao_net_positions`, physical
flows / analogue days, reservoir fill (week-lag rule only), installed
capacity, `input_corrections`, `unit_firms`, UKA, and all of `bin/` (the
forecast driver still derives its own leads/vintages; wiring
`issuance_context` into `run_retro` is phase 2). Their caches stay keyed on
the delivery day only, which is safe precisely because they do not consult
the context yet.

### 5.3 Tests

`test/test_forecast_context.jl` (registered in `test/runtests.jl`): gate
rule at the 2026 DST transitions incl. the 23/25-hour D-1 days, context
scoping incl. `Threads.@spawn` inheritance, classification and audit; then
against the DB: a lead-1 gate context returns the legacy TTF/EUA close, a
lead-3 context returns the close the legacy path reads for delivery D-2, the
outage table under a context has the legacy schema and both cache entries
coexist, and the load reader records only inside a context.

### 5.4 Measured: what a lead-1 gate context changes on one day

`scripts/06_context_smoke.jl` → `output/06_context_smoke.txt`, delivery
2026-08-20, Postgres backend, zones DE_LU / GR / NO4 (three books, one day —
a smoke, not an evaluation):

- **Books are not identical** to the legacy build for any of the three
  zones (DE_LU 9,644 → 9,646 order values; GR same count, different sum;
  NO4 2,686 → 2,688). Two causes, both by design:
  - *Outage gate at explicit 10:00 UTC instead of the session's 08:00 UTC*:
    same 472 assets on the day table, **23 with a different available
    capacity** (versions published 08:00–10:00 UTC on D-1 that the record
    excluded).
  - *Trailing p95 window ending D-1 09:00 instead of D 00:00*: every DE_LU
    type moves by 0.0–1.6 % (Fossil Gas 6,737 → 6,662 MW, Hydro Water
    Reservoir 452 → 430, Solar 50,499 → 50,566).
- **Audit of the DE_LU book (gate context):** load forecast 94 of 96 rows
  `post_gate` (the 13:35 UTC publication of §3.1), 2 `verified`; RES 288 rows
  `unverifiable`; outages, TTF, EUA `verified`; aggregated generation
  `latency_policy`. The same day at lead 3: all 96 load rows `post_gate`,
  fuel closes `verified` (D-4's close, not D-2's).
- `tx_outage_caps` returns 2,700 border-hours in both modes with different
  values under the context; both cache entries coexist.

So a "verified as-of" label on a 2026 summer day currently covers the
outage set, the transmission caps, the fuel closes and the trailing
windows — and explicitly **not** the load and RES forecasts, which is the
honest statement of where the record stands.

### 5.5 Phase 2 (branch `feat/asof-phase2-368`): the drivers clear under a context

- `bin/daily_forecast.jl`: the live run takes **one issuance instant per run**
  (`RUN_ISSUED = now(UTC)`) and clears every market day under
  `ForecastContext(day, RUN_ISSUED, lead)`; `run_retro` clears under the
  reconstructed **D−lead 06:30 UTC** instant — the same `retro_of_utc` it
  stamps on the rows — so a lead-7 retro reads the outage versions, the fuel
  close and the trailing generation windows that existed at D−7, not the
  delivery-relative ones. The UTC-day clear cache remembers the issuance it
  was cleared under and re-clears under a different one (`_CLEAR_VINTAGE`),
  which is what makes the "later-then-earlier issuance in one process" check
  hold on the forecast path. The per-source audit prints one line per market
  day and lead (`🔎 as-of audit …`).
- `run_pipelined_backfill(...; as_of=:none|:gate)`: dynamic scopes do not
  cross process boundaries, so the rule travels in the worker `cfg` and each
  book stage installs `gate_context(day)` itself (`_with_job_context`).
  `:none` is byte-identical. A record backfill under `:gate` is the paired
  measurement of §5.4 at scale — a separate, budgeted run and a code_version
  of its own.
- Still legacy: `run_multi_zone_market_clearing` called directly (no
  `as_of` kwarg yet; wrap the call in `with_context` from the caller), the
  `bin/ml_inputs.jl` cap95 / AR-lag readers (fixed D-2 / D-1 horizon
  regardless of lead — the residual `pregate-7lead.md` §2 declares), and the
  weather-track weather vintages (already lead-aware by their own rule).

### 5.6 Not done, deliberately

- No `data_policy` column on `simulations.energy_prices` /
  `forecast_prices` yet: an additive migration on the live schema is the
  owner's call; the `is_retro`/`reset_tag`/`retro_of_utc` pattern in
  `src/db/results_store.jl` is the template.
- No behaviour change on the legacy path, including the session-time-zone
  outage gate. Fixing it in place would move the Postgres record by the
  43,675 versions that sit between 08:00 and 10:00 UTC (§1) and needs a
  code_version bump; a context run measures that first.

## 6. What cannot be repaired retroactively

- Pre-gate values of the D-1 load and RES forecasts and offered ATC before
  the store starts keeping revisions. Only forward capture fixes this: an
  ETL snapshot taken at ~09:30 UTC on D-1 (before the gate) in addition to the
  00:00 UTC run, or an append-only revision table. That is a ceres change and
  is out of scope here; it is the prerequisite for a verified record to start
  accumulating.
- Outage vintages before 2025-09-28.
- JAO vintages before 2026-08-23.

## 7. Coverage and what was skipped

- Windows: timing tables 2026-06-01..2026-08-31; monthly series 2025-07..2026-08;
  outage gate comparison 2025-10-01..2026-08-31; hydro 2026 weeks 1–35.
- Not done in this phase: price impact of any of the above (needs a re-clear
  under the strict context on a matched window — a separate, budgeted run);
  the DuckDB extract was not opened (another session held it).
