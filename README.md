# Euphemia — an ex-ante competitive counterfactual of the European day-ahead electricity market

A fully **ex-ante** simulation of the European day-ahead electricity
auction across **39 bidding zones**, with **transparent bidding methodology**:
every input is available before the auction gate, every bid-construction rule is
published, and where a parameter is calibrated it is a *market characteristic*
(a zone's gas premium, a hydro system's water value) fitted on ex-ante data and
validated on held-out windows — never a curve fitted to the prices we score
against in-sample. For each zone it reconstructs the *rational
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

## Quickstart

```bash
git clone https://github.com/philokalia-ai/energy-markets && cd energy-markets
./setup.sh                                    # Julia deps + public data (623 MB, checksummed) + smoke test
julia --project=. bin/reproduce.jl --quick    # clear 5 days offline, diff vs committed reference metrics
```

No database, no license, no credentials — the public extract from
<https://data.philokalia.ai> covers 39 zones, 2023-01-01…2026-06-30
(`./setup.sh --live` fetches the daily-refreshed extract instead). Then try a
counterfactual:

```julia
using Euphemia, Dates
solar = (ts, mw) -> (8 <= parse(Int, ts[10:11]) <= 17) ? mw + 300.0 : mw
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, renewable_modifier=solar)
```

Full scenario API: [docs/scenario-api.md](docs/scenario-api.md) · deeper
reproduce options: [docs/reproducibility.md](docs/reproducibility.md) ·
source-tree guide: [docs/code-map.md](docs/code-map.md). Claude Code users
get a bundled **`scenarios` skill** ([.claude/skills/scenarios/](.claude/skills/scenarios/SKILL.md))
that teaches the agent the hooks, labels and pitfalls.

## Headline results — honest, whole-sample, never cherry-picked

**Full record (cv24, 2023-01-01 → 2026-07-27, 1,304 days × 39 zones).** The
current model (`code_version` 24 — cv22 plus French nuclear opportunity-cost
bidding, the re-paired FR–GB border with its GB boundary book, the
interior-Norway import backstop, and a registry sanity bound), backfilled
over the entire history the public extract covers:

> [!IMPORTANT]
> **These figures are not ex-ante figures.** The cv22/23/24 records were produced
> by the pipelined backfill (cv16 and cv17 too — every record built through
> `run_pipelined_backfill` or `eu_calibration_run.jl PIPELINE=true`, so the lineage
> figures below are like-for-like), which never resolved the scoped ex-ante flow rule and
> therefore built its order books with **`:d0` — same-day *observed* cross-border
> flows**, information no forecaster has before the auction. Measured by re-clearing
> record days both ways against the stored prices: `:d0` reproduces the record at
> 93.8–100% bit-identical, the documented ex-ante `:v3` at ~47%
> ([audit](docs/experiments/exante-audit-2026-07.md)). The live daily forecast is
> unaffected — it clears through `run_multi_zone_market_clearing` and *does* resolve
> `:v3`, so it is ex-ante *with respect to flows*; the backtest it is benchmarked against had an
> information advantage it does not have. cv25 corrects this
> ([plan](docs/cv25-plan.md)) and will restate the headline against a
> like-for-like ex-ante baseline.
>
> A second correction lands with it: **65 of the 1,304 days (5.0%) carry fewer than
> 24 UTC hours** — 12 of them a single hour, 2.52% of the record's zone-hours — and
> were saved as complete. Cause: those days are **missing D-1 load-forecast hours at
> source** for one zone (SI on 48 of the 65, then BE 8, BG 4), and a zone's book takes
> its timeslots from the load forecast, so a one-hour zone collapses the coupled
> period intersection for all 39.

**Comparable full-year window (2025-07-25 → 2026-07-24): mean corr 0.68,
mean MAE €26.3** (lineage: cv22: 0.67 / €27.4; cv19: 0.64 / €27.2; cv17:
0.64 / €27.3; cv16: 0.56 / €29.9). Full 2023+ record: mean corr 0.64 /
MAE €26.0 (2023 carries the post-crisis regime, the hardest to model
competitively). Read all of these with the correction above.

By year (energy-weighted share of load in zones with corr ≥ 0.75, mean zone
corr, and zones ≥ 0.75): **2023: 59% / 0.65 / 10 of 39 · 2024: 57% / 0.63 /
13 · 2025: 64% / 0.66 / 14 · 2026: 63% / 0.68 / 19 of 39**. GR specifically:
0.73 → 0.78 → 0.85 → 0.86. On the measured A/B windows the cv19 anad2 flow
rule cut the July-2026 SEE evening overshoot (GR bias +57 → +43) and
improved the held-out June-2026 week's MAE 37.5 → 32.4
([docs/experiments/analogue-flows](docs/experiments/analogue-flows/README.md));
cv22's ua2 cut HU July MAE 80.3 → 61.5 and the legacy-ATC bug-fix removed
phantom-scarcity hours worth −44/−90 MAE on the 5-zone BG/RO products
([docs/experiments/cv22.md](docs/experiments/cv22.md)); cv23's nuclear
opportunity-cost mechanism moved FR's full-2023 corr 0.61 → 0.84.

The cv17 movers were exactly its targets — the weak-zone import fixes
(corr, cv16 → cv17): **AT 0.24 → 0.79**, **BE 0.30 → 0.78**,
**DK2 0.21 → 0.69**, **SI 0.26 → 0.62**, **RO 0.51 → 0.76**,
**RS 0.45 → 0.72**, SE1/SE2 ~0.32 → ~0.52. The guard zones held:
**GR 0.86 → 0.85 (MAE 20.8 → 20.3)**, DE_LU 0.85 → 0.84.

Still weak on the comparable year, stated plainly: **NO1 corr 0.29**
(though its level is now honest: MAE €25.7, bias +€0.1 — the cv23 import
backstop killed the phantom-scarcity caps and the +€36.9 bias; the shape
problem remains the program's oldest open item), **NO3 0.33**, **NO4 0.14**,
**NO5 0.43**, **SE1/SE2 ≈ 0.52**, **SE3 0.61**. (DK1, weak in earlier cvs,
is now **0.78 / €22.4** — the cv21 Viking boundary book fixed it.)

**What entered between cv22 and the cv24 record:** cv23 shipped French
nuclear opportunity-cost bidding (availability-scaled anchor share — FR
full-2023 corr 0.61 → 0.84, March MAE 38.2 → 16.2), the re-paired FR–GB
border with an elastic GB CCGT boundary book (UKA carbon), and the
interior-Norway import backstop (NO1 comparable-year bias +36.9 → +0.1)
([docs/experiments/cv23-fr-nuclear.md](docs/experiments/cv23-fr-nuclear.md),
[docs/experiments/norwegian-hydro/](docs/experiments/norwegian-hydro/)).
cv24 added a registry sanity bound (25 GW ceiling on unit capacities): one
corrupt ENTSO-E entry — an IT-CSOUTH unit carrying 13,068,005 MW — had been
polluting the *coupled* clear across the whole Italian family; healing it
lifts IT-family correlations by up to +0.20 (IT-CSOUTH 2024: 0.58 → 0.78).
Two measured NO-SHIPs are documented with mechanism-level root causes: the
IT must-run price floor (twice — volume-neutral but shape-changing;
[docs/experiments/cv24-it-book.md](docs/experiments/cv24-it-book.md)) and
the 43-zone endogenization ([docs/experiments/](docs/experiments/)).

### By strategy regime — cv24 comparable full year (2025-07-25 → 2026-07-24)

The per-regime breakdown below is measured on the **cv24 canonical record**
over the comparable full year — all 39 zones, every day scored, 8,402 hours
per zone (bias = sim − actual). Aggregate: **mean corr 0.68, mean MAE €26.3,
mean bias −6.1**. (The pre-cv19 frozen 36-day stratified sample this table
replaces is preserved in
[docs/model-spec-exante.md](docs/model-spec-exante.md); its windows differ,
so compare regime-by-regime with care.)

By strategy regime (corr / MAE €/MWh / bias):

| Regime | Zone | corr | MAE | bias |
|---|---|---|---|---|
| Gas-marginal (SEE/Iberia) | **GR** | **0.85** | 21.5 | −4.6 |
| | BG | 0.79 | 25.6 | −1.8 |
| | ES / PT | 0.80 / 0.78 | 22 / 23 | +4 / +5 |
| | RO | 0.76 | 26.4 | −4.4 |
| | RS | 0.72 | 27.3 | +4.9 |
| Continental (installed-truthed) | **DE_LU** | **0.85** | 19.1 | −4.0 |
| | BE | 0.79 | 21.4 | −6.4 |
| | FR | 0.78 | 23.5 | −4.4 |
| | CZ / PL | 0.68 / 0.69 | 26 / 28 | −7 / −10 |
| | NL | 0.69 | 24.1 | −4.9 |
| Italy (gas + premium) | 7 zones | 0.67–0.77 | 19–22 | −6…+6 |
| Hydro, export-anchored | NO2 | **0.76** | 15.6 | +0.9 |
| | CH | 0.73 | 22.4 | −11.7 |
| | SE4 | 0.59 | 31.7 | −8.0 |
| | NO1 / NO3 / NO5 | 0.29 / 0.33 / 0.43 | 26–40 | +0…+23 |
| Hydro, reservoir-only | FI | **0.84** | 25.9 | −21.7 |
| | DK1 | 0.78 | 22.4 | −1.0 |
| | SE1/SE2/SE3 | 0.51–0.61 | 26–30 | −10…+16 |
| Baltic (installed-truthed) | LT / LV / EE | 0.74 / 0.72 / 0.73 | 39–42 | ≈ −29 |
| Border-repaired transit | AT | **0.80** | 24.6 | −15.7 |
| | HU / SK | 0.72 / 0.72 | 34 / 34 | −24 |
| | DK2 / SI | 0.71 / 0.63 | 26 / 36 | −8 / −25 |

What moved since the frozen pre-cv19 sample (different windows — direction,
not decimals): the meshed continental core is repaired (**BE 0.18 → 0.79,
AT 0.34 → 0.80**, NL 0.52 → 0.69), the SEE east lifted (RO 0.54 → 0.76,
RS 0.64 → 0.72), **DK1 0.69 → 0.78** carries the cv21 Viking book,
**FR holds 0.78** on the cv23 nuclear mechanism, and **NO1's bias is gone**
(+36.9 → +0.1) on the cv23 import backstop. Greece — the longest-validated
zone — holds **0.85 / €21.5** with a per-year trajectory 0.73 → 0.78 →
0.85 → **0.86 in 2026**.

The honest weak spots on the full year, stated plainly:

- **Interior Norway — NO1 corr 0.29, NO3 0.33, NO4 0.14** — the program's
  oldest open problem, though the cv23 import backstop transformed its
  character: the dry-spring phantom-cap failure and the level bias are gone
  (NO1 comparable-year MAE 62.7 → 25.7, bias +36.9 → +0.1). What remains is
  a shape problem — the seasonal water-value structure needs
  reservoir/inflow modelling that ENTSO-E data does not carry (measured
  negatives + the forward path in
  [docs/experiments/norwegian-hydro/](docs/experiments/norwegian-hydro/)).
- **Baltics (LT/LV/EE)** — shape fine (corr ~0.73), level bias still
  **≈ −€29/MWh** (winter import pricing).
- **Transit level biases** — HU/SK/SI clear €24–28 below realized on the full
  year (the Core-FBMC evening family; ua2 improved HU's July but the level
  gap remains a candidate market-power/conduct signature under the program's
  framing, not only a model gap).

Two context numbers from the pre-cv19 frozen sample, so the ex-ante claim
stays checkable: with *same-day observed* flows instead of the ex-ante flow
rule that sample's aggregate was corr 0.59 / MAE 31.9 — the fully ex-ante
version is **not worse, it's slightly better**. That comparison was made on a
frozen forecast sample, not on the backfilled record, so it does **not** bound
the size of the correction at the top of this README; Phase 3 of the cv25 plan
measures that directly. On its 12 fully held-out days
the aggregate held at corr 0.62 / MAE 35.3, with the degradation concentrated
in NO1.

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
  footprint re-clears. All anchor inputs are model-internal — the ex-ante
  property is preserved.
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

**3. The ex-ante flow rule (`:v3`, cv19+).** In the real EUPHEMIA, cross-border
flows are not derived *from* prices — flows and prices **co-emerge** from the
same optimization: energy flows from cheap zones to expensive ones until a
border saturates or prices equalize. Our coupled clear does exactly that for
every border *inside* the model. But every model has a boundary, and at the
boundary physics enters as data:

- **Endogenous borders** (most EU-internal ones with usable ATC): the MPCC
  decides these flows itself — no assumption anywhere.
- **Out-of-footprint borders** (Turkey, Ukraine, GB, Albania, N. Macedonia…):
  we do not model those markets — no fleet, no bids, no comparable data — yet
  their real exchanges move our zones' prices by ±1–2 GW. Since they cannot
  *emerge*, they must enter as inputs, exactly like load and RES do.
- **Dropped flow-based borders** (Core FBMC, Nordic-internal): the real
  market clears these against flow-based domains (PTDF polytopes) that the
  public "offered ATC" data cannot reproduce; a wrong constraint set produces
  wrong flows, so their observed/predicted flow enters as data instead.

For a *backward-looking* counterfactual the observed same-day flows would be
legitimate inputs — but this project's published record is not that, it is an
ex-ante counterfactual, and the correction at the top of this README applies: the
record was in fact built with them, and cv25 removes them. For the **D-1 forecast**
they are a data leak — and unlike
load and RES, no official D-1 flow forecast exists (scheduled exchanges are
the auction's own output; using them would be circular). So the exogenous
part is predicted by a simple, versioned rule. The current default (`:v3`
"anad2", since cv19) is the **per-border mean of the D-1-load-analogue median**
(the 16 trailing-365 days whose D-1 load-forecast vector is closest to the
delivery day's) **and the D-2 observed flow** — the load-analogue captures the
regime, D-2 catches a new one within 48 h. It refined the earlier `:v2` rule
(flow climatology + D-7 same-weekday recency on the Norwegian reservoir
borders), still selectable via `EUPHEMIA_FLOW_ASOF_MODE`. Evidence per border
class: [docs/ex-ante-flows.md](docs/ex-ante-flows.md) (`:v2`) and
[docs/experiments/analogue-flows](docs/experiments/analogue-flows/README.md)
(`:v3`).

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
- **HiGHS is the default solver, and the record is solver-invariant** (cv20).
  The per-period decomposition solves each period's coupled MILP
  independently and is the canonical mode on the EU-footprint path: prices
  are **bit-identical across HiGHS and Gurobi** at 60-minute resolution
  (~511 s wall per day on HiGHS vs Gurobi's ~10 s), so the open stack
  reproduces the published record exactly. Gurobi (academic license) remains
  the faster development option via `optimizer="gurobi"`.

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

Both artifacts are hosted on the project's public data bucket at
**<https://data.philokalia.ai>** (Cloudflare R2 behind a custom domain;
uploaded by
[publish-public-artifact.yml](.github/workflows/publish-public-artifact.yml)
and the daily extract refresh).

```bash
# 1. Download the frozen artifact (euphemia-data-v1.1.tar.zst, ~623 MB;
#    sha256 5b0e90154f21bd2649a060af60545fecf537eb562ac035fe3e687ceb3ebf0992)
mkdir -p data/public
curl -L -o euphemia-data-v1.1.tar.zst https://data.philokalia.ai/euphemia-data-v1.1.tar.zst
tar --zstd -xf euphemia-data-v1.1.tar.zst -C data/public

# 2. Verify checksums
cd data/public/euphemia-data-v1.1
sha256sum -c SHA256SUMS      # every parquet file + MANIFEST.json -> "OK"
cd -

# 3. Materialize the runtime DuckDB (auto-detected by the library)
PARQUET_DIR=data/public/euphemia-data-v1.1 \
  OUT=data/extracts/euphemia-public.duckdb \
  julia --project=. bin/build_duckdb_from_parquet.jl

# 4. Reproduce
julia --project=. bin/reproduce.jl --quick                       # 5 days, single + multi-zone
julia --project=. bin/reproduce.jl --range 2026-03-01 2026-03-07 --single GR
julia --project=. bin/reproduce.jl --full --workers auto         # the full record
```

To skip the parquet materialization and work on **current data** instead,
pull the daily-refreshed living extract directly (single ~3 GB DuckDB file,
`.sha256` sidecar next to it):

```bash
curl -L -o data/extracts/euphemia-live.duckdb https://data.philokalia.ai/euphemia-live.duckdb
EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-live.duckdb \
  julia --project=. bin/reproduce.jl --quick
```

Each run writes per-zone corr / MAE / bias tables to `results/` and `--quick`
diffs against the committed reference metrics, flagging any drift. Model
results go to a separate `data/results.duckdb`; the source extract stays
read-only.

### Living extract — a daily-refreshed canonical copy

Besides the frozen public artifact, a **living extract** is kept current by a
daily workflow ([.github/workflows/refresh-extract.yml](.github/workflows/refresh-extract.yml),
02:00 UTC): `bin/refresh_duckdb_extract.jl` opens the extract read-write and
appends, per table, only rows newer than its max timestamp —
`entsoe.*` / `yfinance.*` from the energy DB, the `weather` schema
(`city`, `city_forecast`, `city_forecast_vintage`) from the separate weather
DB, and `weather.cell_hourly` (the ERA5 wind/GHI feature history at the
wind-catalogue cells behind `bin/res_models_v1.json`) from the public
open-meteo archive API. Mutable registry-like tables (unit registry, outages,
reservoir filling, simulations caches) are re-pulled wholesale instead.

The canonical refreshed copy lives in the extract store at
**`/opt/euphemia/extracts/euphemia-live.duckdb`** — fetch it with
`bin/extract_store.sh pull euphemia-live.duckdb <dest>` (local canonical dir by
default, overridable via `EUPHEMIA_EXTRACT_STORE`; setting
`EXTRACT_S3_ENDPOINT` + `EXTRACT_S3_BUCKET` flips the same commands to an
S3-compatible store — the Cloudflare R2 / seaweedfs hook, env-only).

**Who uses it:** read-only consumers — eval scripts, scenario runs,
reproduction — already get an extract by default via the library's
auto-detection of `data/extracts/euphemia-public.duckdb`; point
`EUPHEMIA_DUCKDB_PATH` at the living copy to run them on current data:

```bash
EUPHEMIA_DUCKDB_PATH=/opt/euphemia/extracts/euphemia-live.duckdb \
  julia --project=. test/scripts/eval_pricing_accuracy.jl merit_order "2026-07-10" GR
```

**Honest scoping — what stays on Postgres:** the daily forecast pipeline
(`bin/daily_forecast.jl`) is NOT switched to the extract: it *writes*
`forecast_prices` via LibPQ, and the DuckDB backend skips the Postgres pool
entirely — a mixed read-from-extract / write-to-Postgres mode does not exist.
Moving it is a known follow-up, not part of the living-extract scope.

**Maintenance:** appended slabs land after the originally-sorted rows, so daily
refreshes slowly degrade the extract's row-group zonemap pruning (results stay
correct; scans get gradually slower). Run a monthly full rebuild
(`bin/build_duckdb_extract.jl`, then `bin/extract_store.sh push … euphemia-live.duckdb`)
to restore the global sort.

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

### Live data backend — R2 parquet + Worker API (the `/v1/` contract)

Site freshness is decoupled from git pushes (issue #152): right after each
pipeline write step, `bin/export_web_parquet.jl` exports the SPA's data
contract as **zstd parquet** (DuckDB `COPY`) and `bin/web_data_push.sh`
uploads it to the R2 bucket `euphemia-web-data` — seconds after the DB
write, no commit, no Pages build. A Cloudflare Worker
([workers/api/](workers/api/)) reads the parquet with hyparquet and serves
the exact JSON shapes the SPA consumes, ETag-cached at the edge:

```
GET https://api.philokalia.ai/api/v1/zones/GR
GET https://api.philokalia.ai/api/v1/scoreboard
GET https://api.philokalia.ai/api/v1/map
GET https://api.philokalia.ai/api/v1/manifest        # {updated_at, …}
GET https://api.philokalia.ai/api/v1/inputs/<ZONE>   # RES/load driver + prediction panel
GET https://api.philokalia.ai/api/v1/inputs/reservoir
GET https://api.philokalia.ai/api/v1/inputs/manifest
```

`web/app.js` tries the API first and falls back to the committed
`./data/*.json`, then fixtures — disabling the Worker restores the static
behavior exactly (`?live=0` forces it per visit).

**Stability contract.** The bucket layout is a public data interface:

```
v1/zones/<ZONE>.parquet   # hourly sim/actual + all vintages, ~120 recent days
v1/scoreboard.parquet     # zone × lead × window × track aggregates
v1/map.parquet            # per-day zone aggregates (freshest lead)
v1/manifest.json          # {updated_at, code_version, zones, row_counts}
v1/inputs/<ZONE>.parquet  # RES/load DRIVERS + prediction + reference + actual, per zone-hour
v1/inputs/reservoir.parquet  # weekly reservoir fill ratio / dryness (hydro zones)
v1/inputs/manifest.json   # the open input-model plane (docs/predictions.md)
```

Fields under `v1/` are append-only: new columns may be added, existing
columns never change meaning or type; breaking changes bump to `v2/` with
`v1/` kept alive during a deprecation window. The objects are typed parquet
precisely so that people **and their agents** can query them directly
(DuckDB/pandas over HTTP range reads) once public bucket access is enabled —
a one-time user action: `npx wrangler r2 bucket dev-url enable
euphemia-web-data` (or attach a custom domain to the bucket), then:

```sql
SELECT * FROM 'https://<public-bucket-url>/v1/zones/GR.parquet' LIMIT 24;
```

## Repository map

```
src/        The Euphemia library: merit-order book construction (MeritOrderBook.jl
            + merit_order/), clearing orchestration (Euphemia.jl + clearing/),
            coupled MPCC clearing (MPCC.jl), network/ATC topology (Network.jl),
            (Generators.jl + generators/), data access (dbutils.jl + db/) —
            reader's guide: docs/code-map.md
bin/        Runners: reproduce.jl (public reproduction), build_duckdb_extract.jl /
            build_duckdb_from_parquet.jl (data artifacts), backfill runners
docs/       Model spec, calibration atlas + iteration history, reproducibility,
            the open RES/load input model (predictions.md), negative-results
            record (complex-orders-investigation.md, experiments/) —
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
- **Solver:** the bundled open-source **HiGHS** is the default and covers
  every tier — no license needed. Single-zone clearing has always run on
  HiGHS with metrics identical to Gurobi's, and since cv20 the full 39-zone
  coupled clear runs in canonical per-period-decomposed mode, which is
  **bit-identical across HiGHS and Gurobi** at 60-minute resolution
  (~511 s/day vs ~10 s). **Gurobi**, if licensed (ours is academic), is the
  faster development option via `optimizer="gurobi"`.
- **Data:** either the public DuckDB extract (recommended; no database
  required) or a PostgreSQL database with the ENTSO-E schema (maintainers).

## Data attribution & acknowledgements (data)

Full column-level documentation of the published artifact, with per-table
provenance: **[docs/data-dictionary.md](docs/data-dictionary.md)**.

- **[ENTSO-E Transparency Platform](https://transparency.entsoe.eu)** — the
  backbone of the model: load and wind/solar forecasts, offered transfer
  capacities, physical flows, generation units and outages, reservoir levels,
  per-unit and per-type actual generation, and day-ahead prices (used for
  validation only). Redistributed in the public extract with attribution
  under the Platform's terms of use. This project would not exist without
  ENTSO-E's open transparency data.
- **[Open-Meteo](https://open-meteo.com)** — hourly weather (temperature,
  wind, radiation) for the weather→RES forecasting track and the ERA5
  reanalysis history behind the wind/solar feature models (CC-BY 4.0,
  non-commercial API tier). Carried in the living extract's `weather.*`
  tables.
- **Yahoo Finance** via `yfinance` — TTF gas front-month futures (`TTF=F`)
  and the SparkChange Physical Carbon ETC (`CO2.L`) as the EUA carbon proxy;
  daily reference closes.
- **[Global Fishing Watch](https://globalfishingwatch.org)** — AIS port-call
  data behind the cold-ironing case studies (CC BY-NC; the raw dataset is
  therefore *not* redistributed in this repo — only derived aggregates).

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
  iterations (cv10…cv17), the ex-ante forecasting product, the scenario API,
  and the reproducibility artifacts — engineered in collaboration with
  Claude (Anthropic).

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
