# Euphemia — an ex-ante competitive counterfactual of the European day-ahead electricity market

A fully **ex-ante** simulation of the European day-ahead auction across
**39 bidding zones**. For each zone it reconstructs the *rational competitive
bid* of every market participant from fundamentals (fuel and carbon prices,
D-1 forecasts, reservoir levels, the physical fleet), assembles the resulting
order books, and clears all zones simultaneously through a EUPHEMIA-style
coupled auction — a MILP with complementarity conditions and cross-border
capacity constraints.

Every input is **D-1-legal** (it existed before the auction gate), and **no
parameter is ever fitted to observed prices** — prices enter only as
validation. Where a parameter is calibrated it is a *market characteristic*
(a zone's gas premium, a hydro system's water value), fitted on ex-ante data
and validated on held-out windows.

The framing matters: this is a **competitive counterfactual**, not a
price-prediction product. Where the model tracks reality, competition explains
the price. Where observed prices sit *persistently above* the counterfactual,
that residual is a **candidate market-power finding** — a hypothesis to
investigate, not a model failure to calibrate away.

![Day-ahead market bidding-zone DAG](https://github.com/user-attachments/assets/36fa28b2-04b2-4a98-b633-9d9cef683b22)

## Quickstart

```bash
git clone https://github.com/philokalia-ai/energy-markets && cd energy-markets
./setup.sh                                    # Julia deps + public data (623 MB, checksummed) + smoke test
julia --project=. bin/reproduce.jl --quick    # clear 5 days offline, diff vs committed reference metrics
```

No database, no license, no credentials. Then try a counterfactual:

```julia
using Euphemia, Dates
solar = (ts, mw) -> (8 <= parse(Int, ts[10:11]) <= 17) ? mw + 300.0 : mw
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, renewable_modifier=solar)
```

Scenario API: [docs/scenario-api.md](docs/scenario-api.md) · reproduce options:
[docs/reproducibility.md](docs/reproducibility.md) · source-tree guide:
[docs/code-map.md](docs/code-map.md) · version history:
[docs/code-version-ledger.md](docs/code-version-ledger.md). Claude Code users
get bundled `scenarios` and `backfill` skills under
[.claude/skills/](.claude/skills/).

## Where the model stands — cv37

The current model version is **cv37** (`ENERGY_PRICES_CODE_VERSION` in
`src/db/postgres_core.jl`). The published record is
`simulations.energy_prices` at `code_version=37`,
`clearing_mode='multi_zone_eu'`: **786 delivery days (2024-07-01 → 2026-08-26)
× 39 zones**, 734,640 hourly cells matched against settled prices.

**Ratified two-year ladder** — 729 days (2024-07 → 2026-06), energy-weighted,
the metric the version decisions were made on. The mechanism write-ups are on
`main` ([cv36](docs/experiments/cv36-graded-tranche/README.md),
[cv37](docs/experiments/cv37-nordic-wet/README.md)); the full ratified table
lands with PR #353, still open at the time of writing:

| | cv35 | cv36 | cv37 |
|---|---|---|---|
| footprint corr | 0.725 | 0.737 | **0.740** |
| footprint MAE €/MWh | 25.47 | 25.48 | **25.22** |
| energy in zones at corr ≥ 0.70 | 82.6% | 90.0% | **90.0%** |
| energy in zones at corr ≥ 0.80 | 44.3% | 44.3% | **56.0%** |

**Per zone, unweighted** — a different statistic on the same record: hourly
prices over the comparable 12 months 2025-07-01 → 2026-06-30 (341,160 cells,
365 days × 39 zones). Footprint MAE **€23.71**, bias **−5.21**, mean zone corr
**0.770**, median **0.784**. Strongest: GR and DE_LU 0.86, CZ and AT 0.85,
DK1 and FI 0.83. Weakest, stated plainly: **SE4 0.42**, **RS 0.67**,
**DK2 0.67**, NO5 0.72. Persistent level biases remain in the Baltics
(LT/LV ≈ −€23) and the Core evening belt (HU −16.6, CH −17.3) — under this
program's framing those are candidate conduct signatures as much as model
gaps ([conduct probe](docs/experiments/conduct-probe-2026-08/README.md)).

**What moved recently.** cv35 replaced the broken ATC on flow-based borders
with JAO capacity data (below): on 52 held-out Wednesdays, footprint MAE
26.24 → 23.40 and corr 0.680 → 0.761, with the Core cluster 35.1 → 23.1 and
Nordic hydro 29.2 → 23.1 — the single largest version step in the program
([docs/experiments/jao-maxbex-atc.md](docs/experiments/jao-maxbex-atc.md)).
cv36 graded the upper supply tranches (all 7 Italian zones improve
out-of-sample); cv37 damps the winter water-value lift in wet Nordic years
(SE2 −8.0 MAE on the held-out window).

## How it works

One pipeline per market day (full detail:
[docs/model-spec-exante.md](docs/model-spec-exante.md) and
[docs/calibration-atlas.md](docs/calibration-atlas.md)):

**1. Merit-order book construction (per zone).** No unit commitment is run —
the counterfactual wants each unit's rational competitive bid, not a simulated
central dispatch. Every zone uses the same bid skeleton; regions differ only
in parameters (a per-zone `ZoneProfile`):

- **SRMC tranche ladder.** Marginal cost = fuel (the last close strictly before
  the market day) / efficiency + EUA carbon + O&M. Flexible capacity bids a
  four-step ladder, optionally graded into a piecewise-linear upper curve
  (cv36).
- **Must-run splitting.** A UC-lite rule commits the cheapest units covering
  the day's peak residual demand; their minimum load self-schedules below cost
  — which is what lets midday prices collapse in renewable-surplus hours.
- **Scarcity factor.** Upper tranches lift when the zone's capacity margin
  genuinely tightens and in predictable peak hours.
- **Hydro opportunity-cost regimes.** Water is never bid at variable cost:
  *gas-anchored*, *reservoir-opportunity* (water value from reservoir dryness
  and a seasonal drawdown, damped in wet years since cv37), or
  *export-anchored*.
- **Two-pass opportunity anchors.** Pass 1 clears the standard books; zones
  whose dominant resource prices against the coupled system (Nordic and
  alpine hydro, French off-peak nuclear, Belgian imports) re-bid at a share of
  the *pass-1 model price* and the footprint re-clears. All anchor inputs are
  model-internal, so the ex-ante property holds.
- **Fleet truthing.** Registry capacity is cross-checked against what has
  recently been active: idle-but-real capacity counts toward adequacy, phantom
  paper capacity is derated.
- Renewables bid the D-1 forecast at €1 (price-takers); demand is ~98% of
  forecast load at the €3,000 cap with a 2% elastic tail.

**2. Coupled MPCC clearing.** One MILP across the footprint: complementarity
with exact per-order Big-M, the market-coupling condition
λ_sink − λ_source = ρ⁺ − ρ⁻ per constrained border, MIP gap 1e-6,
deterministic price reconstruction.

**3. Network capacity — the JAO layer (cv35).** Most of Europe no longer
clears against ATC at all: Core and the Nordics clear against flow-based
domains, and the public ENTSO-E "offered capacity" table carries **zero
Day-ahead rows** for those borders — only intraday leftovers, which is what
was silently constraining the model. Since cv35 the capacity comes from the
JAO Publication Tool instead, published at **10:30 CET on D-1** and therefore
ex-ante by construction:

- `jao.max_exchanges` — the maximum bilateral exchange per directed border —
  becomes the ATC on every Day-ahead-free border-hour, and un-drops the Core
  borders earlier versions had to drop entirely.
- `jao.hub_net_positions` — each hub's min/max net position — scales those
  bilateral maxima, since they do not all hold simultaneously. (The exact
  net-position constraint inside the MPCC is parked opt-in until its price
  condition gets a dual.)
- Transmission-grid outage messages cap border-hours at the TSO's remaining
  capacity.

**4. Out-of-footprint flows.** Borders with markets we do not model (Turkey,
Ukraine, GB, Albania…) cannot *emerge* from the clear, so they enter as data.
No official D-1 flow forecast exists — scheduled exchanges are the auction's
own output — so the exogenous part is predicted by a versioned ex-ante rule
(`:v3`, since cv19): the per-border mean of the D-1-load-analogue median and
the D-2 observed flow. Evidence:
[docs/experiments/analogue-flows](docs/experiments/analogue-flows/README.md).
Two neighbours (GB on Viking, Ukraine) are instead modeled as elastic
*boundary books* bidding their own fundamentals.

## Solvers

**HiGHS is the default and needs no license.** Since cv20 the EU-footprint
path clears in canonical per-period-decomposed mode, which is **bit-identical
across HiGHS and Gurobi** at 60-minute resolution (~511 s/day vs ~10 s), so
the open stack reproduces the record exactly. Gurobi (ours is academic) is the
faster development option via `optimizer="gurobi"` — and is *required* for the
cv35 JAO network, where HiGHS segfaults on the 108-link problem.

**15-minute clearing** is opt-in (`clear_resolution_minutes=15`): hourly inputs
are upsampled by replication, never division, and at 60-minute settings the
path reproduces the hourly prices bit-identically. Scored against native
15-minute actuals it is a *harder* target, not a better score
([docs/15min-clearing.md](docs/15min-clearing.md)).

## Beyond the physics — the two statistical reference lines

The site carries two machine-learning lines *beside* the physics, never inside
it, so the counterfactual stays a counterfactual. On the same out-of-sample
protocol (729 days, energy-weighted): physics MAE 23.08 / corr 0.794;
physics + an ex-ante GBM correcting its residual **14.93 / 0.882**; a pure
statistics GBM on settled-price lags 14.49 / 0.887. The physics keeps the
better spike precision (0.77), and the statistical arms can only *agree* with
the market — they can never measure it, which is the whole point of the
program. Method and honest caveats: <https://energy.philokalia.ai/models.html>.

## Reproduce it — no database required

The full pipeline runs offline from a published, self-contained data extract
(**euphemia-data-v1.1**: 39 zones, 2023-01-01…2026-06-30). Full guide, checksums
and run tiers: [docs/reproducibility.md](docs/reproducibility.md).

```bash
julia --project=. bin/reproduce.jl --quick                       # 5 days, single + multi-zone
julia --project=. bin/reproduce.jl --range 2026-03-01 2026-03-07 --single GR
julia --project=. bin/reproduce.jl --full --workers auto         # the full record
```

Each run writes per-zone corr / MAE / bias tables to `results/`; `--quick`
diffs against the committed reference metrics and flags drift. Model results
go to a separate `data/results.duckdb` — the source extract stays read-only.
A **living extract** refreshed daily (`refresh-extract.yml`, 02:00 UTC) is
available for work on current data; point `EUPHEMIA_DUCKDB_PATH` at it.

> **Honest scope of offline reproduction.** The public and living extracts do
> **not** carry the `jao.*` tables, so an offline run clears the cv34 network,
> not cv35's. Expect the flow-based zones (Core, Nordics) to score materially
> worse than the published record — that gap is the JAO layer, not drift.
> Reproducing cv35+ exactly needs the JAO feed.

## Scenario API

Perturb demand, supply, bidding behaviour or the physical fleet, and re-clear
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
hooks: `strategist` (an incumbent marking up its fleet — the market-power
counterfactual), `fleet_modifier`, `load_modifier`, `renewable_modifier`.
Worked case studies (data-center load, EU-wide shore power) are on the site.

## Live forecasting — [energy.philokalia.ai](https://energy.philokalia.ai)

The same model runs daily as a forward product. The **06:30 UTC pre-gate run**
produces the weather track for leads D+1…D+7 *before* the 12:00 CET auction
gate, so lead 1 is a genuine pre-auction forecast; JAO-aware runs at 09:05 /
10:05 UTC freeze lead 1 once the flow-based domain publishes, and an evening
refresh fills whatever the morning could not see
([docs/experiments/pregate-7lead.md](docs/experiments/pregate-7lead.md)).

A delivery day is a Europe/Athens market day, stitched from two UTC-day solves
and published only when complete. Predictions are **frozen, never revised**:
each row records `prediction_made_utc`, an hour-level guard forbids writing a
row whose delivery hour has already passed, and writes are no-clobber. As days
settle they are scored per zone × lead into `simulations.forecast_scores` and
browsed in the SPA under [`web/`](web/README.md), served by a Cloudflare
Worker over R2 parquet ([`workers/api/`](workers/api/README.md), the public
`/v1/` data contract).

**Weather → RES.** ENTSO-E's D-1 load and wind/solar forecasts arrive late,
which caps the product at lead 1. Predicting them ourselves from weather
closes that: a GFS+ECMWF+ICON ensemble at 1,425 wind-farm cells across the 39
zones predicts ENTSO-E's own DA wind forecast at corr 0.960, and solar reaches
0.988. Swapping in pure weather-RES costs ~0.05 corr on GR price accuracy, so
ENTSO-E stays the lead-1 input and weather-RES is the path to leads 2–7
([docs/res-forecasting-investigation.md](docs/res-forecasting-investigation.md),
[docs/predictions.md](docs/predictions.md)). The fitted input model is
downloadable standalone as
[input-model-v1.0.0](https://github.com/philokalia-ai/energy-markets/releases/tag/input-model-v1.0.0).

## Known limits

- **The Nordic and Core level biases** are the oldest open items: interior
  Norway's seasonal water-value structure needs reservoir/inflow modelling
  ENTSO-E data does not carry, and the Baltic winter import level is still
  ≈ −€23/MWh off.
- **Collapse recall regressed with cv35**: hit rate on price-collapse hours
  43% → 14% (false alarms 1019 → 174). Better precision, worse recall — the
  accepted cost of the JAO network, and the first thing the next flow-based
  step (the full PTDF/RAM domain) should recover.
- **cv35–37 re-clears are not bit-reproducible.** Re-clearing a record day
  reproduces most cells but drifts up to €23/MWh on 85 of 936 zone-hours
  (cv31 passed at 1e-12). Suspects are the JAO/net-position path and
  graded-tranche iteration order. Until it is found, every scenario study
  pairs a **fresh baseline arm in the same process**, so deltas stay valid.
- **Complex/temporal orders were tested and rejected** three ways (ramp
  coupling, mini-UC with fix-and-reprice, endogenous must-run across 16
  zones): the calibrated per-period book with correct costs already captures
  what they add
  ([docs/complex-orders-investigation.md](docs/complex-orders-investigation.md)).
  Other measured NO-SHIPs — the price-floor family (cv28/29/30), demand
  elasticity, the 43-zone endogenization — are recorded with their mechanisms
  in [docs/code-version-ledger.md](docs/code-version-ledger.md) so they are
  not retried blind.

## Repository map

```
src/        The Euphemia library: merit-order book construction (MeritOrderBook.jl
            + merit_order/), clearing orchestration (Euphemia.jl + clearing/),
            coupled MPCC clearing (MPCC.jl + mpcc/), network/ATC topology
            (Network.jl), generators (Generators.jl + generators/), data access
            (dbutils.jl + db/) — reader's guide: docs/code-map.md
bin/        Runners: reproduce.jl (public reproduction), the DuckDB extract
            builders, backfill and daily-forecast runners
docs/       Model spec, calibration atlas, reproducibility, the open RES/load
            input model (predictions.md), the version ledger, and the
            experiment record incl. negative results — index: docs/README.md
            · solver validated against REAL published auctions (GME + OMIE):
              docs/experiments/pubbooks-clearing/REPRODUCE.md
test/       Core suite (julia --project=. test/runtests.jl), plus manual/
            DB-dependent tests and scripts/ benchmarks and identity guards
results/    Committed reference metrics for reproduction drift checks
thesis/     LaTeX thesis + slides
web/        Static SPA for the live forecast browser (energy.philokalia.ai)
workers/    Cloudflare Worker serving the public /v1/ data API
```

## Requirements

- **Julia** (`julia --project=. -e "using Pkg; Pkg.instantiate()"`).
- **Solver:** bundled **HiGHS** by default, no license. **Gurobi** optional
  (faster; required for the cv35 JAO network).
- **Data:** the public DuckDB extract (recommended, no database required) or a
  PostgreSQL database with the ENTSO-E schema (maintainers).

## Data attribution & acknowledgements (data)

Column-level documentation of the published artifact, with per-table
provenance: **[docs/data-dictionary.md](docs/data-dictionary.md)**.

- **[ENTSO-E Transparency Platform](https://transparency.entsoe.eu)** — the
  backbone of the model: load and wind/solar forecasts, offered transfer
  capacities, physical flows, generation units and outages, reservoir levels,
  per-unit and per-type actual generation, and day-ahead prices (validation
  only). Redistributed in the public extract with attribution under the
  Platform's terms of use. This project would not exist without it.
- **[JAO Publication Tool](https://publicationtool.jao.eu)** — flow-based
  maximum bilateral exchanges and hub net positions (Core since 2022-06,
  Nordic since 2024-10); public, no key.
- **[Open-Meteo](https://open-meteo.com)** — hourly weather and the ERA5
  reanalysis history behind the wind/solar feature models (CC-BY 4.0,
  non-commercial API tier).
- **Yahoo Finance** via `yfinance` — TTF gas front-month futures (`TTF=F`) and
  the SparkChange Physical Carbon ETC (`CO2.L`) as the EUA carbon proxy.
- **[Global Fishing Watch](https://globalfishingwatch.org)** — AIS port-call
  data behind the cold-ironing case studies (CC BY-NC; only derived aggregates
  are redistributed).

**Bidding-zone boundaries** (web map) are adapted from the
[Electricity Maps contrib](https://github.com/electricitymaps/electricitymaps-contrib)
project (AGPL-3.0): 39-zone subset, DE+LU merged, IT-Calabria split out of
IT-SO along the Gulf of Taranto, simplified to 57 KB (`web/geo/zones.geojson`).

## Acknowledgements

This repository is the work of three contributors, in three distinct phases:

- **Giannis Georgakopoulos** — original author. Two years of foundational
  work: the core Euphemia clearing engine, the unit-commitment and bidding
  layers, and the ENTSO-E data pipelines. His diploma thesis, developed in
  this repository, lives in [`thesis/`](thesis/).
- **Efthymios Karangelos** — shared the MPCC (complementarity-constraints)
  market-clearing formulation with Giannis, in the wake of the **Julia
  Meetup Athens, 2024**. The `MPCC.jl` solver at the heart of the coupled
  clear descends from that exchange.
- **Panagiotis Georgakopoulos** — Fable tokens (2026 → ). Directed and
  funded the 2026+ program: the 39-zone EU footprint, the calibration
  iterations, the ex-ante forecasting product, the scenario API, and the
  reproducibility artifacts — engineered in collaboration with Claude
  (Anthropic).

## License & citation

Licensed under the **European Union Public Licence v1.2** ([LICENSE](LICENSE),
[EUPL-1.2](https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12)) —
*from Europeans, to Europeans*: a model of the European electricity market,
built on European open data, under the EU's own copyleft licence (compatible
with GPL/AGPL/LGPL/MPL per its Appendix; the Electricity Maps-derived
`web/geo/zones.geojson` remains AGPL-3.0 as noted above).

Authors: **Giannis Georgakopoulos**, **Efthymios Karangelos**,
**Panagiotis Georgakopoulos** — see [Acknowledgements](#acknowledgements) for
who built what.

If you use this model or the published data artifact in academic work, please
cite this repository (a `CITATION.cff` with a citable release DOI is planned).
