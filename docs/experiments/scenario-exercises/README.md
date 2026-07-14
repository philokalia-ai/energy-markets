# GR scenario exercises — data center & cold ironing

Two counterfactual exercises on **Greece**, expressed through the first-class
scenario API (`docs/scenario-api.md`) and run fully **offline** against the
living DuckDB extract. They are also the reference walk-through of the
**counterfactual-on-the-counterfactual workflow**: define a scenario with the
hooks → run it labeled with `clearing_mode` → analyze it with
`queries/load_weighted_price_delta.sql`.

All runs: single-zone `generate_energy_prices("GR", day; order_method=:merit_order,
optimizer="highs", save_to_db=true, clearing_mode=<label>)`, source data
read-only from `data/extracts/euphemia-live.duckdb`, results persisted to
`data/results.duckdb`. Loops are resumable (already-saved `(day, clearing_mode)`
pairs are skipped) — see `common.jl`.

| run | script | clearing_mode | window | scenario hook |
|---|---|---|---|---|
| baseline | `baseline.jl` | `gr_scn_base` | 2024-07-01..2026-06-30 (730 d) | none |
| data center | `datacenter_574mw.jl` | `gr_scn_dc574` | 2025-07-01..2026-06-30 (365 d) | `load_modifier`: +574 MW constant |
| cold ironing | `cold_ironing_ops.jl` | `gr_scn_ops` | 2024-07-01..2025-06-30 (365 d) | `extra_orders`: hourly OPS profile at the cap |

The baseline is shared: its 730-day window is the union of the two scenario
windows, so each exercise compares against baseline days of its own window.

## Exercise 1 — 574 MW always-on data center

A hyperscale data center connects in GR and draws a constant 574 MW in every
timeslot of the year 2025-07-01..2026-06-30.

**Hook choice (`load_modifier`, not `extra_orders`).** Firm always-on baseload
demand shows up in the system load forecast, so the faithful representation
edits the load series at the source: `load_modifier` propagates the +574 MW
into everything derived from load — net demand, the scarcity margin (and hence
scarcity-priced tranches) and hydro water values. `extra_orders` would be a
pure demand-curve addition: the order clears, but the book's scarcity /
water-value machinery would still price against the unmodified load. The
`extra_orders` variant is the natural cheap sensitivity if you want to bracket
how much of the delta comes from the demand curve alone (not run here).

```julia
dc_load = (ts, load_mw) -> load_mw + 574.0
generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=true,
    clearing_mode="gr_scn_dc574", load_modifier=dc_load)
```

## Exercise 2 — cold ironing (onshore power supply) at Greek ports

Every in-scope passenger ship (ro-pax / high-speed / cruise) berthed at one of
the 21 monitored Greek ports connects to shore power. This is the **real-data
incarnation of the documented "ships request power" example** in
`docs/scenario-api.md` — the same `extra_orders` hook, but sized by a measured
hourly demand profile instead of a flat 200 MW.

**Hook choice (`extra_orders`).** OPS demand is new price-inelastic demand bid
at the cap (ships connect regardless of the day-ahead price); unlike the data
center there is no claim that TSO load forecasts would carry it, so the pure
demand-curve addition is the faithful modelling.

```julia
ops_orders = ctx -> [SimpleOrder(:demand, 3000.0, OPS_MW[ts[1:11]], Symbol(ctx.zone),
                         DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                     for ts in ctx.timeslots if get(OPS_MW, ts[1:11], 0.0) > 0]
generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=true,
    clearing_mode="gr_scn_ops", extra_orders=ops_orders)
```

### Profile provenance

`ops_hourly_gr_central_2024H2_2025H1.csv` (committed here, 8,760 rows,
`datetime_utc, ops_mw`) is derived from the ceres ships pipeline
(`ceres` repo, branch `ships-cold-ironing`, `ships/outputs/ops_load_15min.csv`,
commits "ships: commit output datasets + data dictionary" /
"add central (imputed) scenario to 15-min OPS demand export"):

- **Source**: Global Fishing Watch port-visit AIS data over 21 Greek ports,
  2023-07-01..2025-06-30; at-berth load from GT-binned EMSA figures
  (2.5 / 5 / 12 MW for medium ferry / large ferry / cruise-scale).
- **Scenario**: `power_total_central_mw` — the **central** (imputed) scenario,
  **all-21-ports** scope. Central = confirmed >5000 GT ships (floor) plus
  imputed demand of scheduled ships whose tonnage GFW never matched; it leans
  high — the floor series is ~3.3× smaller. Full-uptake (all in-scope ships
  connect).
- **Aggregation**: the four 15-min UTC slots of each hour averaged to a mean
  hourly MW.
- **Window/mapping**: the exercise window 2024-07-01..2025-06-30 lies entirely
  inside the AIS coverage, so the profile uses **actual same-date values** —
  no calendar tiling or extrapolation. (The exercise was deliberately limited
  to one year to match the data; the earlier plan to tile a second year was
  dropped.) Timestamps are UTC on both sides (Euphemia timeslots are UTC), so
  the mapping is a direct datetime join.
- **Shape**: mean 126 MW, max 369 MW, strongly seasonal — ~205–250 MW mean in
  summer months (cruise/ferry season), ~27–32 MW in winter.

## Running

```bash
julia --project=. docs/experiments/scenario-exercises/baseline.jl
julia --project=. docs/experiments/scenario-exercises/datacenter_574mw.jl
julia --project=. docs/experiments/scenario-exercises/cold_ironing_ops.jl
```

Run them sequentially (the results DB is single-writer). Each is resumable —
rerun after an interruption and it continues where it left off. Analysis
(read-only, safe anytime):

```bash
julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_ops   GR 2024-07-01 2025-07-01
```

## Results

Runs completed 2026-07-13 against the living extract (source data
2023-01-01..2026-07-12; HiGHS; ~2.6 days/s per solve loop). Day counts:
baseline 729/730, data center 364/365, cold ironing 365/365, **0 solver
failures**. The one missing day, **2025-10-08**, is an upstream data gap — the
GR day-ahead wind/solar forecast has NULL values for that day (48 of 120 rows
populated), so the book build aborts identically in baseline and scenario; it
is simply absent from both runs and drops out of the comparison. 2024-10-26/27
saved partially (21 + 2 hours, the October DST changeover gap in the source
load series), again identically in both runs; the delta query joins on hours
present in both runs, so all of this is handled.

All numbers below from `bin/scenario_delta.jl` — load-weighted by the hourly
day-ahead load forecast (the model's own demand series, unmodified baseline
load), per calendar year and total.

### Data center (+574 MW, 2025-07-01..2026-06-30, Δ = gr_scn_dc574 − gr_scn_base)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|
| 2025 H2 | 4,392 | 90.77 | 106.79 | **+16.02** | 419.7 | 837.1 |
| 2026 H1 | 4,344 | 105.31 | 128.47 | **+23.16** | 563.3 | 1,135.9 |
| **TOTAL** | 8,736 | 97.77 | 117.23 | **+19.46** | **982.9** | **985.6** |

The +574 MW is ~9% of GR average load, so a double-digit delta is expected —
the GR merit curve is steep between the RES/lignite shoulder and the gas SRMC
band. Decomposition: **+15.46 €/MWh** of the total comes from ordinary
merit-order steepening across 8,720 normal hours (€781m); **+4.00 €/MWh**
comes from just 16 hours (47 quarter-hour periods) where the added demand
exhausts the offered supply and the price hits the €3,000 cap (€202m). The
scarcity tail is real signal (the extra baseload eats the reserve margin in
tight hours) but is also the first thing that import relief would shave — see
the caveat below.

#### The other side of the ledger: the data center's power bill

What the data center itself pays for its energy (wholesale day-ahead only):
574 MW flat priced at the scenario's hourly prices.

| | value |
|---|---|
| energy | 5,014 GWh over the window (574 MW × 8,736 h) |
| bill at scenario prices | **€580.0m** (time-average **€115.67/MWh**) |
| bill at baseline prices | €487.4m (€97.21/MWh) — €92.6m of the bill is the price increase it causes itself |

The flat profile's time-average price (€115.67) sits slightly below the zone's
load-weighted €117.23 (flat weighting includes the cheap off-peak hours that
load weighting de-emphasizes). Ledger comparison: the data center buys €580m
of electricity while everyone else pays €986m extra — every €1 it buys raises
other consumers' bills by ~€1.70.

Reproduce (DuckDB on `data/results.duckdb`, after the runs):

```sql
SET TimeZone='UTC';
WITH px AS (
  SELECT date_trunc('hour', date_time_utc) AS h, clearing_mode, AVG(price_eur_mwh) AS p
  FROM simulations.energy_prices
  WHERE bidding_zone = 'GR' AND clearing_mode IN ('gr_scn_dc574', 'gr_scn_base')
    AND date_time_utc >= TIMESTAMP '2025-07-01' AND date_time_utc < TIMESTAMP '2026-07-01'
  GROUP BY 1, 2)
SELECT 574.0 * COUNT(*) / 1e6        AS twh,
       574.0 * SUM(s.p) / 1e6        AS bill_scenario_meur,
       574.0 * SUM(b.p) / 1e6        AS bill_baseline_meur,
       AVG(s.p)                      AS avg_price_scenario,
       AVG(b.p)                      AS avg_price_baseline
FROM px s
JOIN px b ON b.h = s.h AND b.clearing_mode = 'gr_scn_base'
WHERE s.clearing_mode = 'gr_scn_dc574';
```

### Cold ironing (OPS profile, 2024-07-01..2025-06-30, Δ = gr_scn_ops − gr_scn_base)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|
| 2024 H2 | 4,391 | 106.65 | 110.26 | **+3.62** | 97.3 | 194.1 |
| 2025 H1 | 4,344 | 97.16 | 99.26 | **+2.11** | 50.8 | 102.4 |
| **TOTAL** | 8,735 | 102.16 | 105.06 | **+2.90** | **148.1** | **148.5** |

Mean OPS demand is 126 MW but strongly summer-peaked (~205–250 MW mean in
summer, ~30 MW in winter), which lands on the season when GR prices are set by
gas and A/C load — hence the 2024 H2 (Jul–Dec) delta is ~1.7× the 2025 H1
(Jan–Jun) one. No scenario hour reaches the cap. Per MW of average added load,
cold ironing costs ~€1.18m/yr/MW vs the data center's ~€1.72m/yr/MW — the
seasonal concentration into already-tight hours makes OPS MW *more* expensive
than flat MW on that margin (the DC's higher figure is partly its scarcity
tail).

#### The other side of the ledger: the ship owners' power bill

What the ships themselves pay for the OPS energy (wholesale day-ahead only —
no grid fees, taxes, or port infrastructure): the OPS profile priced at the
scenario's hourly prices.

| | value |
|---|---|
| OPS energy | 1,101 GWh over the window (8,735 h) |
| bill at scenario prices | **€100.0m** (OPS-weighted avg **€90.78/MWh**) |
| bill at baseline prices | €95.7m (€86.89/MWh) — €4.3m of the bill is the price increase the ships themselves cause |

The OPS-weighted price (€90.78) is *below* the zone's load-weighted average
(€105.06): the berth profile lands on cheaper hours than the zone's load does
(summer solar middays and nights). Comparison of the two ledgers: the ships
buy €100m of electricity while everyone else pays €148m extra — every €1 of
shore power raised other consumers' bills by ~€1.50.

Reproduce (DuckDB on `data/results.duckdb`, after the runs):

```sql
SET TimeZone='UTC';
WITH ops AS (
  SELECT CAST(datetime_utc AS TIMESTAMP) AS h, ops_mw
  FROM read_csv_auto('docs/experiments/scenario-exercises/ops_hourly_gr_central_2024H2_2025H1.csv')
  WHERE ops_mw > 0),
px AS (
  SELECT date_trunc('hour', date_time_utc) AS h, clearing_mode, AVG(price_eur_mwh) AS p
  FROM simulations.energy_prices
  WHERE bidding_zone = 'GR' AND clearing_mode IN ('gr_scn_ops', 'gr_scn_base')
    AND date_time_utc >= TIMESTAMP '2024-07-01' AND date_time_utc < TIMESTAMP '2025-07-01'
  GROUP BY 1, 2)
SELECT SUM(o.ops_mw)                             AS mwh,
       SUM(o.ops_mw * s.p) / 1e6                 AS bill_scenario_meur,
       SUM(o.ops_mw * b.p) / 1e6                 AS bill_baseline_meur,
       SUM(o.ops_mw * s.p) / SUM(o.ops_mw)       AS ops_weighted_price_scenario,
       SUM(o.ops_mw * b.p) / SUM(o.ops_mw)       AS ops_weighted_price_baseline
FROM ops o
JOIN px s ON s.h = o.h AND s.clearing_mode = 'gr_scn_ops'
JOIN px b ON b.h = o.h AND b.clearing_mode = 'gr_scn_base';
```

### Caveats

- **Single-zone runs**: net imports are fixed at their historical values, so
  no import relief responds to the added demand. In the coupled multi-zone
  measurement of the documented +200 MW ships example, neighbours absorb part
  of the shock (+2.62 €/MWh for 200 MW). These single-zone deltas are
  therefore toward the upper end; a multi-zone rerun would soften them,
  especially the DC scarcity tail.
- **OPS profile is the CENTRAL (imputed) scenario** — it leans high; the floor
  series is ~3.3× smaller. Bracket accordingly.
- **Full uptake**: every in-scope ship connects (pre-AFIR-phase-in upper
  bound).

---

## EU-coupled runs (39-zone footprint)

The single-zone caveat above — fixed historical imports make the deltas an
upper bound — is answered by re-running the counterfactuals on the **full
39-zone EU footprint** (`order_method=:merit_order, enrich_network=true,
passes=2`), so imports respond endogenously through the coupled ATC network.
Runs via `eu_scenarios.jl` → `run_pipelined_backfill` with the new `scenario=`
passthrough (Gurobi, `solver_workers=2`, ex-ante flow mode pinned `:v2`, the
cv16+ EU product default; offline against the living extract, results in
`data/results.duckdb`). ~155–204 days/h; 2,192 day-solves total; every day
`:optimal` (two transient pass-1 failures solved on the resumable rerun).

| run | clearing_mode | window | scenario |
|---|---|---|---|
| baseline | `eu_scn_base` | 2024-07-01..2026-06-30 (730 d) | none |
| data center | `eu_scn_dc574` | 2024-07-01..2026-06-30 (730 d) | `Dict("GR" => ZoneScenario(load_modifier = (ts,l) -> l + 574.0))` |
| cold ironing | `eu_scn_ops_floor` | 2024-07-01..2025-06-30 (365 d) | `Dict("GR" => ZoneScenario(extra_orders = <FLOOR profile at the cap>))` |

**FLOOR profile provenance.** `ops_hourly_gr_floor_2024H2_2025H1.csv` is the
**floor** scenario of the same ceres ships export (column `power_total_mw`):
only ships with a registry-confirmed >5000 GT match — the hard lower bound
(GFW matches tonnage for ~27% of frequent Greek ferries), vs the central
(imputed) profile used in the single-zone exercise. Same aggregation (all 21
ports, four 15-min UTC slots averaged to hourly MW, actual dates, no tiling):
mean 37.6 MW, max 163 MW, 329 GWh over the year — ~3.35× smaller than central.

**Coverage note.** The coupled clear prices ~23.2–23.5 of 24 hours/day (hours
without a coupled marginal are unpriced; late-Oct 2024 has the largest gaps).
Coverage is IDENTICAL across the three labels, and the delta SQL inner-joins
hours present in both runs, so all deltas are computed pairwise on the same
hours (8,402 joined hours in the 2025-26 window, 8,567 in 2024-25).

### (a) Data center EU-coupled, 2025-07-01..2026-06-30 (Δ = eu_scn_dc574 − eu_scn_base, zone GR)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | Δ% | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2025 H2 | 4,199 | 98.68 | 107.69 | **+9.01** | | 226.6 | 472.8 |
| 2026 H1 | 4,203 | 88.27 | 96.14 | **+7.87** | | 185.2 | 386.1 |
| **TOTAL** | 8,402 | 93.65 | 102.11 | **+8.46** | **+9.0%** | **411.9** | **429.4** |

**DC bill**: 574 MW × scenario prices = **€486.2m** over the window (time-avg
price paid €100.82/MWh; €506.9m annualized to 8,760 h).

**EU-wide extra cost** (all 39 zones, each weighted by its own load forecast):
**€896.9m** — GR €411.9m, **outside GR €485.0m**. The data center's neighbours
pay more than Greece does in aggregate.

### (b) Cold ironing FLOOR EU-coupled, 2024-07-01..2025-06-30 (Δ = eu_scn_ops_floor − eu_scn_base, zone GR)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | Δ% | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2024 H2 | 4,319 | 105.90 | 106.44 | **+0.55** | | 14.6 | 29.5 |
| 2025 H1 | 4,248 | 102.58 | 102.97 | **+0.38** | | 9.0 | 18.6 |
| **TOTAL** | 8,567 | 104.34 | 104.81 | **+0.47** | **+0.45%** | **23.6** | **24.1** |

**Ships' floor bill**: floor MW × scenario prices = **€27.95m** for 321.7 GWh
of joined shore-power energy (OPS-weighted price €86.87/MWh — *below* the
€104.81 load-weighted average: ferry/cruise berthing is overnight-heavy, off
the evening peak).

**EU-wide extra cost**: **€65.9m** — GR €23.6m, outside GR €42.3m.

### (c) Data center EU-coupled, 2024-07-01..2025-06-30 (same window as OPS — directly comparable)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | Δ% | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2024 H2 | 4,319 | 105.90 | 113.75 | **+7.86** | | 208.6 | 423.1 |
| 2025 H1 | 4,248 | 102.58 | 111.69 | **+9.10** | | 214.8 | 443.0 |
| **TOTAL** | 8,567 | 104.34 | 112.78 | **+8.44** | **+8.1%** | **423.4** | **433.0** |

**DC bill**: **€537.4m** over the window (time-avg €109.29/MWh). **EU-wide
extra cost €1,168.0m** — GR €423.4m, outside GR €744.5m.

On the same window and same coupled model, the 574 MW data center (5.03 TWh/yr)
costs GR consumers **18×** what floor cold ironing (0.32 TWh/yr) does
(€423m vs €24m) on **15.6×** the energy — flat baseload demand is slightly
more expensive per MWh than the overnight-heavy OPS profile in the coupled
model (the single-zone comparison, with its scarcity tail, ordered them the
other way; coupling shaves scarcity first).

### Single-zone vs EU-coupled (import relief)

| exercise | single-zone Δ | EU-coupled Δ | relief |
|---|---:|---:|---:|
| DC +574 MW, 2025-26 | **+19.46** €/MWh | **+8.46** €/MWh | −57% |
| OPS central 2024-25 (single) vs floor coupled | +2.90 | +0.47 | mixes two dimensions |

- **DC (clean comparison, same scenario + window):** endogenous imports absorb
  57% of the single-zone price impact (+19.46 → +8.46). The €983m/yr GR extra
  cost becomes €412m — but the shock does not vanish, it propagates: EU-wide
  the extra cost is €897m, over half of it landing on GR's neighbours.
- **OPS (not a clean pair — profile AND coupling changed):** central→floor
  scales the energy by ~0.30 (which alone would put the single-zone delta near
  +0.87 €/MWh); coupling then shaves roughly half of that (+0.47), consistent
  with the DC relief factor.

### Neighbour spillover (mean Δ €/MWh over joined hours)

The GR shock exports through the SEE coupling corridor and dies at the
congested borders beyond it:

- **DC 2024-25**: BG **+5.14**, RO **+4.46**, RS **+3.38**, HU **+1.62**;
  SI +0.60, IT-* ≤ +0.09, DE_LU/FR +0.03 — the corridor carries €745m of extra
  cost outside GR.
- **DC 2025-26**: RO +3.44, BG +3.61, RS +2.57, HU +1.59, IT-SOUTH +0.18.
- **OPS floor 2024-25**: RO +0.23, BG +0.29, RS +0.18, HU +0.08 — same shape,
  ~20× smaller.

### Pipeline notes (what these runs added to the codebase)

- `run_pipelined_backfill(...; scenario=)` — the scenario passthrough into both
  book stages (`mz_build_books` / `mz_rebuild_anchored`), so counterfactuals
  run at full pipeline throughput. `nothing` remains byte-identical.
- **Explicit `EUPHEMIA_FLOW_ASOF_MODE` is now forwarded to pipeline workers**
  (they call `mz_build_books` directly, so the EU-footprint scoped `:v2`
  default does not apply there; unforwarded it silently fell back to `:d0` —
  measured GR 122.49 vs 134.10 €/MWh day-mean on 2025-04-03).
- **Pipeline workers now load `Dates`**: scenario hooks are closures serialized
  from the coordinator's Main, and hooks that reference `DateTime` (as every
  documented example does) threw `UndefVarError` on the workers — which the
  per-zone book build catches by *silently dropping the zone*. The first OPS
  attempt saved 365 days of a 38-zone footprint with GR (and the scenario)
  missing entirely; the label was purged and rerun. Keep hooks to Euphemia
  exports, `Dates`, and plain captured data.
