# Euphemia — an ex-ante competitive counterfactual of the European day-ahead electricity market

A fully **ex-ante**, **no-fit** simulation of the European day-ahead electricity
auction across **39 bidding zones**. For each zone it reconstructs the *rational
competitive bid* of every market participant from fundamentals (fuel and carbon
prices, forecasts, reservoir levels, the physical fleet), assembles the
resulting order books, and clears all zones simultaneously through a
EUPHEMIA-style coupled auction — a MILP with complementarity conditions and
cross-border capacity constraints. Every input is **D-1-legal** (available
before the auction closes at D-1 noon), so the model is a genuine forecast of
tomorrow, not a reconstruction. **No parameter is ever fitted to observed
prices** — prices enter only as validation.

The research framing matters: this is a **competitive counterfactual**, not a
price-prediction product. Where the model tracks reality, competition explains
the price. Where observed prices sit *persistently above* the counterfactual,
that residual is a **candidate market-power finding** — a hypothesis to
investigate, not a model failure to calibrate away.

![Day-ahead market bidding-zone DAG](https://github.com/user-attachments/assets/36fa28b2-04b2-4a98-b633-9d9cef683b22)

## Headline results — honest, whole-sample, never cherry-picked

**Full-year record (cv16).** The current model (`code_version` 16), evaluated
over the full year **2025-07-01 → 2026-06-30** (365 days, all 39 zones,
identical-window comparison against the previous cv14 record, resolution-aware
hourly eval; bias = sim − actual):

**Aggregate over 39 zones: mean corr 0.45 → 0.56, mean MAE €42.0 → €29.9,
mean bias +17.5 → −1.5 (cv14 → cv16).**

The big movers (corr / MAE €/MWh, cv14 → cv16): DE_LU 0.50/49 → **0.85/18**,
SK 0.33/176 → 0.72/33, PL 0.27/71 → 0.67/28, Baltics (LT/LV/EE) ~0.42/78 →
~0.72/40, CZ 0.41/31 → 0.72/23, NO2 0.40/20 → 0.77/15, CH 0.36/31 → 0.65/23.
**GR — the guard zone — held: 0.85/21.0 → 0.86/20.8.**

Still weak on the full year, stated plainly: **NO1 corr 0.01 / MAE €63**
(reservoir-regime import flows — the known open problem), **DK1/DK2 corr
0.05/0.21**, **NO3 0.13**, **AT 0.24**, **SI 0.26**, **BE 0.30**.

### By strategy regime — frozen 36-day stratified sample

The per-regime breakdown below is measured on a **frozen 36-day full-year
stratified sample** (all 39 zones, every day scored; bias = sim − actual).
Source of truth: [docs/model-spec-exante.md](docs/model-spec-exante.md).
Aggregate on this sample: mean corr 0.61, mean MAE €30.7/MWh, mean bias −8.5.

By strategy regime (corr / MAE €/MWh / bias):

| Regime | Zone | corr | MAE | bias |
|---|---|---|---|---|
| Gas-marginal (SEE/Iberia) | **GR** | **0.82** | 23.3 | −6.7 |
| | BG | 0.79 | 30.3 | +6.4 |
| | ES / PT | 0.80 / 0.77 | 22 / 23 | +5 |
| | RS | 0.64 | 36.2 | +12.6 |
| | RO | 0.54 | 50.7 | +25.0 |
| Continental (installed-truthed) | **DE_LU** | **0.80** | 21.1 | −9.8 |
| | FR | 0.74 | 25.5 | +3.9 |
| | CZ / PL | 0.68 / 0.65 | 26 / 29 | −13 / −16 |
| | NL | 0.52 | 25.9 | −14.1 |
| | BE | 0.18 | 38.6 | −25.1 |
| Italy (gas + premium) | 7 zones | 0.64–0.76 | 19–24 | −14…+1 |
| Hydro, export-anchored | NO2 | **0.78** | 15.9 | −0.9 |
| | SE4 | 0.72 | 36.0 | −15.2 |
| | CH | 0.68 | 23.4 | −7.3 |
| | NO1 / NO3 / NO5 | 0.08 / 0.31 / 0.41 | 34–46 | mixed |
| Hydro, reservoir-only | FI | **0.85** | 35.1 | −27.9 |
| | DK1 | 0.69 | 26.7 | −14.6 |
| | SE1/SE2/SE3 | 0.44–0.49 | 30–39 | −13…+6 |
| Baltic (installed-truthed) | LT / LV / EE | **0.83 / 0.82 / 0.80** | 48–50 | ≈ −38 |
| Border-repaired transit | HU | 0.74 | 33.8 | −9.3 |
| | SK | 0.68 | 37.9 | −32.8 |
| | AT / DK2 / SI | 0.34 / 0.27 / 0.64 | 29–35 | −10…−12 |

Where it's strong: wherever gas or truthed thermal sets the price (Greece,
Germany, Iberia, Italy, France), correlation sits at 0.74–0.82 with MAE in the
€20s. Greece — the longest-validated zone — holds **corr 0.86 / MAE €20.8 over
the full-year cv16 backfill** (2025-07-01 → 2026-06-30).

The honest weak spots on this sample, stated plainly:

- **NO1 (corr 0.08)** — the known open problem. Its import flow regime flips
  week to week; neither an 8-week climatology nor D-7 recency captures it. It
  needs a real flow input model with reservoir-state features (the defined
  next-iteration deliverable).
- **Baltics (LT/LV/EE)** — shape is excellent (corr 0.80–0.83) but there is a
  systematic **≈ −€38/MWh level bias** (winter import pricing, the next
  calibration target).
- **BE / AT / DK2** — the remaining shape problems in the meshed continental
  core (corr 0.18–0.34).

Two context numbers, so the ex-ante claim is checkable: with *same-day
observed* flows instead of the ex-ante flow rule the aggregate is corr 0.59 /
MAE 31.9 — the fully ex-ante version is **not worse, it's slightly better**.
On 12 fully held-out days the aggregate holds at corr 0.62 / MAE 35.3, with
the degradation concentrated in NO1.

## How it works

One pipeline per market day
(full detail: [docs/model-spec-exante.md](docs/model-spec-exante.md) and
[docs/calibration-atlas.md](docs/calibration-atlas.md)):

**1. Merit-order book construction (per zone).** The path does *not* run unit
commitment — the counterfactual wants each unit's rational competitive bid,
not a simulated central dispatch. Every zone uses the same bid skeleton;
regions differ only in parameters (a per-zone `ZoneProfile`):

- **SRMC tranche ladder.** Each thermal unit's marginal cost = fuel (daily TTF
  for gas) / efficiency + EUA carbon + O&M, using the last close strictly
  before the market day. Flexible capacity bids a four-step ladder
  (55/20/15/10% of capacity at 0.95/1.05/1.25/1.60 × cost).
- **Must-run splitting.** A UC-lite rule commits the cheapest units covering
  the day's peak residual demand; their minimum load self-schedules — the
  deepest 60% at 5% of cost, the rest at cost minus an absolute
  startup-amortization discount — which is what lets midday prices collapse
  below thermal cost in renewable-surplus hours.
- **Scarcity factor.** Upper tranches are multiplied by
  `1 + κ_s·max(0, θ − margin)² + κ_p·d̂⁴` when the zone's capacity margin
  genuinely tightens and in predictable peak hours.
- **Hydro opportunity-cost regimes.** Water is never bid at variable cost:
  *gas-anchored* (thermal-dominated zones), *reservoir-opportunity* (water
  value from weekly reservoir dryness, with a seasonal drawdown signal), or
  *export-anchored* (stored water re-priced against the coupled reference).
- **Two-pass opportunity anchors.** Pass 1 clears the standard books; zones
  whose dominant resource prices against the coupled system (Norwegian and
  south-Swedish hydro, alpine storage, French off-peak nuclear, Belgian
  imports) then re-bid at a share of the *pass-1 model price* and the
  footprint re-clears. All anchor inputs are model-internal — the no-fit,
  ex-ante property is preserved.
- **Fleet truthing.** Registry capacity is cross-checked against what has
  recently been active: idle-but-real capacity counts toward adequacy
  (activity-gated), phantom paper capacity is derated, and per-type capacity
  missing from the unit list is completed back.
- Renewables bid the D-1 forecast at €1 (price-takers); demand is ~98% of
  forecast load at the €3,000 cap with a 2% elastic tail at €250.

**2. Coupled MPCC clearing.** One MILP across the footprint: complementarity
with exact per-order Big-M, the market-coupling condition
λ_sink − λ_source = ρ⁺ − ρ⁻ per ATC-constrained border, MIP gap 1e-6,
deterministic price reconstruction. ~10 s/day (Gurobi) for 39 zones.

**3. The ex-ante flow rule (`:v2`).** Borders inside the footprint clear
endogenously. Borders that can't — outside the footprint (Turkey, Ukraine,
GB…) or with broken flow-based "offered ATC" — enter as injections using
**flow climatology** (median of the trailing 8 same-weekday days) everywhere
except the Norwegian borders, which use **D-7 same-weekday flows** (reservoir
regimes persist week to week; a median mis-states them). Post-auction data
such as scheduled commercial exchanges is inadmissible by construction.
Evidence per border class: [docs/ex-ante-flows.md](docs/ex-ante-flows.md).

## Resolution & solvers

- **15-minute clearing (opt-in, PR #115).** `clear_resolution_minutes=15`
  clears the coupled footprint on native 15-minute periods (the real
  auction's market time unit). Hourly inputs are upsampled by **replication, never
  division**, and the reduces-to-hourly proof is bit-exact: at 60-minute
  settings the refactored path reproduces the hourly prices bit-identically.
  Honest note: scored against native 15-minute actuals the finer clear is a
  *harder* target, not a better score — mean corr 0.582 vs 0.615 hourly
  (GR 0.751 → 0.680). 15-minute clearing buys market fidelity, not
  correlation.
- **HiGHS is now a working option for the full 39-zone clear.** The
  per-period decomposition solves each period's coupled MILP independently:
  prices are **bit-identical to Gurobi's** at 60-minute resolution, at
  ~511 s wall per day vs Gurobi's ~10 s. Gurobi remains the default fast
  path; no solver license is required for any tier anymore.

## Negative results — mechanisms tested and rejected

Complex/temporal orders — block orders, unit commitment inside the clearing,
endogenous must-run — were tested three ways (ramp-only coupling, mini-UC with
fix-and-reprice on GR and DE_LU, and a one-variable endogenous-must-run swap
inside the calibrated book across 16 zones) and **do not improve the
counterfactual as an always-on mechanism**: the calibrated per-period book
with correct costs (above all the hydro water value) already captures what
they add. The one live lead is a **winter-gated endogenous must-run** (the
signal: 11/14 zones improve on a winter day; the same mechanism hurts in
summer). This is a feature of the method, not a failure: mechanisms are
adopted only when they beat the calibrated baseline under fair, one-variable
tests. Full record:
[docs/complex-orders-investigation.md](docs/complex-orders-investigation.md);
runnable prototypes in [docs/experiments/](docs/experiments/README.md).

## Reproduce it — no database required

The full pipeline runs offline from a published, self-contained data extract
(**euphemia-data-v1.1**: 39 zones, 2023-01-01…2026-06-30 — parquet ~759 MB,
materialized runtime DuckDB ~2.61 GB). Full guide:
[docs/reproducibility.md](docs/reproducibility.md).

```bash
# 1. Download
mkdir -p data/public
curl -L -o euphemia-data-v1.tar.zst https://<published-url>/euphemia-data-v1.tar.zst
tar --zstd -xf euphemia-data-v1.tar.zst -C data/public

# 2. Verify checksums
cd data/public/euphemia-data-v1
sha256sum -c SHA256SUMS      # every parquet file + MANIFEST.json -> "OK"
cd -

# 3. Materialize the runtime DuckDB (auto-detected by the library)
PARQUET_DIR=data/public/euphemia-data-v1 \
  OUT=data/extracts/euphemia-public.duckdb \
  julia --project=. bin/build_duckdb_from_parquet.jl

# 4. Reproduce
julia --project=. bin/reproduce.jl --quick                       # 5 days, single + multi-zone
julia --project=. bin/reproduce.jl --range 2026-03-01 2026-03-07 --single GR
julia --project=. bin/reproduce.jl --full --workers auto         # the full record
```

Each run writes per-zone corr / MAE / bias tables to `results/` and `--quick`
diffs against the committed reference metrics, flagging any drift. Model
results go to a separate `data/results.duckdb`; the source extract stays
read-only.

## Scenario API — counterfactuals on the counterfactual

Perturb demand, supply, bidding behaviour, or the physical fleet, and re-clear
the coupled market ([docs/scenario-api.md](docs/scenario-api.md)):

```julia
# "Ships request 200 MW more power in GR" — extra inelastic demand at the cap
ships = ctx -> ctx.zone == "GR" ?
    [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
     for ts in ctx.timeslots] : SimpleOrder[]
result = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2,
    scenario=ZoneScenario(extra_orders=ships))
```

Measured: the +200 MW lands in GR, and GR/BG/RO — one uncongested price island
— all rise by the same +€2.62/MWh, while HU behind a binding constraint is
unmoved. That is market coupling, reproduced by the counterfactual. Other
hooks: `strategist` (e.g. an incumbent marking up its fleet 20% — the
market-power counterfactual), `fleet_modifier` (retire / add / derate physical
units), `load_modifier` / `renewable_modifier`.

## Live forecasting — live at [energy.philokalia.ai](https://energy.philokalia.ai)

The same model now runs daily as a genuine forward product:
**<https://energy.philokalia.ai>**. The pipeline runs **twice a day**:

- **08:00 UTC — the morning window.** Fill + forecast *before* the day-ahead
  auction gate (SDAC closes 12:00 CET: 10:00 UTC summer / 11:00 UTC winter).
  Any prediction written here is **pre-auction** — ex-ante with respect to the
  market clearing itself, not just to delivery. Each row records
  `prediction_made_utc`, so pre-gate rows are provable.
- **17:30 UTC — the evening fill.** ENTSO-E's D-1 items propagate to the bulk
  export late for the large zones (~19:00 UTC measured for DE/IT), so the
  evening run fills whatever the morning couldn't see. Writes are
  **no-clobber**: a morning (pre-auction) row is never overwritten by an
  evening one.

A delivery day is a **Europe/Athens market day** — the 24-hour window starting
21:00/22:00 UTC the previous evening (DST-aware), stitched from two UTC-day
solves; a day is published only when complete. An **hour-level ex-ante guard**
ensures no row is ever written whose delivery hour has already passed at
prediction time, and predictions are **frozen — never revised**; the record in
`simulations.forecast_prices` is append-only by construction. As days realize
they are scored per zone × lead time into `simulations.forecast_scores`,
browsable in the SPA under `web/`.

First live day (2026-07-12): **GR corr 0.92 / MAE €21.7 at lead 1**. Because
every input is D-1-legal, the backtest metrics above are the expected live
performance — there is no train/serve gap to hide.

### Weather → RES: cutting the dependence on late ENTSO-E forecasts

The decisive inputs (ENTSO-E 6.1.B load and 14.1.D wind/solar forecasts) are
D-1-only items that arrive *late* — which caps the product at lead 1 and
pushes it toward the evening. The answer is predicting wind/solar ourselves
from weather forecasts
([docs/res-forecasting-investigation.md](docs/res-forecasting-investigation.md)):

- **Wind**: a GFS+ECMWF+ICON lead-1 ensemble at wind-farm-sited grid cells
  predicts ENTSO-E's own DA wind forecast at **corr 0.960** (0.872 vs actual).
  Sites from the ELETAEN turbine registry for GR and an OSM extraction for the
  full footprint — **115,390 turbines → 1,425 cells across all 39 zones**
  (`ceres/geodata/eu_wind_cells.csv`).
- **Solar**: GHI + sun geometry + hour-of-day calibration reaches **corr
  0.988** vs the ENTSO-E forecast — ENTSO-E's own accuracy at half its MAE.
- **Price impact**: swapping ENTSO-E RES for pure weather-RES costs corr
  0.850 → 0.804 on the GR test days. So ENTSO-E stays the input at lead 1,
  and weather-RES is the path to **lead 2–7** (lead-2 weather costs only
  ~0.01) and to morning-window forecasts on days ENTSO-E hasn't published.
- **Plumbing** (merged July 2026): the weather DB's forecast feed now carries
  radiation (NULL since 2024), 100 m wind and cloud cover, archives
  **forecast vintages** (past hours were silently overwritten — honest lead-N
  backtesting was impossible), and refreshes on an evening schedule.
  Remaining for live use: EU-wide weather fetch at the catalogue cells and a
  temperature-driven load model for lead ≥ 2.

## Repository map

```
src/        The Euphemia library: merit-order book construction (MeritOrderBook.jl),
            coupled MPCC clearing (MPCC.jl), network/ATC topology (Network.jl),
            unit commitment (UnitCommitment.jl), data access (dbutils.jl)
bin/        Runners: reproduce.jl (public reproduction), build_duckdb_extract.jl /
            build_duckdb_from_parquet.jl (data artifacts), backfill runners
docs/       Model spec, calibration atlas + iteration history, reproducibility,
            negative-results record (complex-orders-investigation.md, experiments/) —
            see the docs index: docs/README.md
test/       Core test suite (julia --project=. test/runtests.jl), plus manual/
            DB-dependent tests and scripts/ benchmarks
results/    Committed reference metrics for reproduction drift checks
thesis/     LaTeX thesis documentation
web/        Static SPA for the live forecast browser (energy.philokalia.ai)
```

## Requirements

- **Julia** (project environment in `Project.toml`; `julia --project=. -e
  "using Pkg; Pkg.instantiate()"`).
- **Solver:** the bundled open-source **HiGHS** now covers every tier — no
  license needed. Single-zone clearing has always run on HiGHS with metrics
  identical to Gurobi's, and the per-period decomposition makes the full
  39-zone coupled clear HiGHS-viable too (bit-identical prices to Gurobi at
  60-minute resolution, ~511 s/day vs ~10 s). **Gurobi**, if licensed, remains
  the default fast path.
- **Data:** either the public DuckDB extract (recommended; no database
  required) or a PostgreSQL database with the ENTSO-E schema (maintainers).

## Data attribution

- **ENTSO-E Transparency Platform** — load and wind/solar forecasts, offered
  transfer capacities, physical flows, generation units and outages, reservoir
  levels, day-ahead prices (used for validation only). Redistributed in the
  public extract with attribution under the Platform's terms of use.
- **TTF gas and EUA carbon** — daily closes via `yfinance` (TTF front-month
  futures; the SparkChange Physical Carbon ETC as an EUA proxy).

**Bidding-zone boundaries** (web map) are adapted from the
[Electricity Maps contrib](https://github.com/electricitymaps/electricitymaps-contrib)
project (AGPL-3.0): 39-zone subset, DE+LU merged, IT-Calabria split out of
IT-SO along the Gulf of Taranto, simplified to 57 KB (`web/geo/zones.geojson`).

## License & citation

License: to be determined — until a license file is added, all rights
reserved; contact the authors for reuse.

If you use this model or the published data artifact in academic work, please
cite this repository (a `CITATION.cff` with a citable release DOI is planned).
