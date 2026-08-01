# Protocol — Published-books clearing validation (FROZEN)

**Question (owner, verbatim intent).** For the exchanges that PUBLISH their real
order books — GME (Italy) and OMIE (Spain/Portugal) — feed the ACTUAL bids into
the Euphemia clearing engine and measure whether we reproduce the OFFICIAL
clearing outcome. This isolates the **mechanistic layer**: if real books in →
official prices out, the solver is right and any residual model error belongs to
book *construction*, not to the clearing solve.

Frozen 2026-08-01, BEFORE any closeness number is computed. Metrics and sample
are the prereg (this is a validation experiment, not a ship gate — per
`.claude/SCIENTIST.md`, the prereg is metrics + sample). Deviations are disclosed
in `results.md`, not hidden.

## 0. What the exploration established BEFORE freezing (disclosed)

A pre-freeze structural probe (Python, on the already-parsed GME parquet + OMIE
curves + the read-only extract) established two facts that shape the design:

1. **Both exchanges publish only the DOMESTIC bid layer of a coupled market.**
   - GME per-Italian-zone: total awarded demand ≠ total awarded domestic supply;
     the difference is the net inter-zonal + foreign schedule (Italy is a net
     importer). Naive domestic supply×demand crossing missed the zonal
     `awarded_price` by a median **€108/MWh**; injecting the observed net
     position as a price-taker block cut that to **€2.5/MWh** (median).
   - OMIE (Iberian pool): the published aggregate O-curve crossing missed the
     official ES price by a median **€35/MWh** (up to €83 midday), because Iberia
     is coupled to France — solar-surplus midday exports raise the official price
     above the isolated-pool crossing.

   Consequence: a single-market clear of the *published book alone* CANNOT equal
   the official price except by luck; the missing coupling layer must be supplied
   as a boundary condition. This is a book-completeness fact, not a solver
   property, and it defines the two-layer design below.

2. The engine's uniform-price clearing (`solve_mpcc_market_clearing`, single
   node, `network_topology=nothing`) reconstructs the price from the acceptance
   pattern — i.e. it computes the merit-order crossing of whatever orders it is
   given. So "does the solver clear the bids correctly" is answerable directly
   by comparing the engine to an independent crossing of the identical orders,
   with no coupling assumption.

## 1. Two-layer design

**Layer A — pure solver mechanics (the headline).** Feed the real published
DOMESTIC supply+demand orders for a zone-hour into the engine. Independently
compute the textbook merit-order uniform-price crossing of the *identical* order
set. Metric = `|P_engine − P_crossing|`. Self-contained; needs no coupling. This
is the direct test of "λύνει σωστά τα bids" — does Euphemia solve the bids
correctly. Expected: exact to floating point except at ties/degeneracy.

**Layer B — book → official (what residual belongs to book construction).** Feed
the same real bids into the engine and compare to the OFFICIAL price, in two
configurations:
- `domestic`: real supply+demand only → `P_dom`.
- `+net`: real supply+demand PLUS the observed net cross-border/inter-zonal
  position injected as a price-taker block (net import → supply at the floor; net
  export → demand at the ceiling) → `P_net`.
Metric = `|P_dom − P_off|` and `|P_net − P_off|`, with per-hour attribution of
the residual. Layer B shows the residual is the missing coupling layer (recovered
by the boundary block), not the solver.

The engine is run in BOTH configurations (real bids in, both times). Layer A's
crossing reference is computed independently in the harness.

## 2. Sample (fixed before any score)

**GME (Italy).** All 7 downloaded market days (the only days in `pubbooks/raw`;
GME enforces a 7-day publication embargo and the raw data is not redistributable,
so the sample is what is on disk): **2025-01-15, 2025-04-15, 2025-07-15,
2025-10-15, 2026-01-15, 2026-04-15, 2026-07-15** — spread across 4 seasons and 2
years. Zones: the 7 Italian zones **NORD, CNOR, CSUD, SUD, CALA, SICI, SARD**.
Scored cell = (zone, day, hour). Target ≈ 7 zones × 24 h × 7 days = **1176
cells** (minus any hour a zone has no book / no awarded price — reported).

**OMIE (Iberia).** 20 days spread across the 6 downloaded curve months
(202501, 202504, 202507 hourly; 202510, 202601, 202604 15-min → first MTU of the
hour). Days (fixed now): the **5th, 15th, 25th** of each of the 6 months
(= 18 days) plus the **10th of 202501 and 202504** (= 20 days). Zone = the ES+PT
pool cleared as one market (MIBEL). Scored cell = (day, hour) = **480 cells**.
OMIE cells are scored in Layer B only on **ES=PT hours** (no MIBEL internal
congestion, so the pool is one price); congested hours (ES≠PT) are reported
separately and excluded from the Layer-B headline (disclosed count). Layer A
(solver mechanics) uses all cells.

Every sampled day/cell is reported, including failures and empties. No day
substitution.

## 3. Conversion — real bids → our order types

Primary treatment (declared): **include-as-simple** — every published price/qty
step becomes one `SimpleOrder`. Steps at the IDENTICAL (cell, side, price) are
summed into one order — exact for the uniform-price clearing price and cleared
volume, and it shrinks the per-cell MIP ~4× (OMIE 2900→650 orders, GME 900→200);
disclosed as a performance-equivalent aggregation. Complex conditions (OMIE
minimum-income,
load-gradient, indivisibility; GME predefined/block structures) are INCLUDED as
their simple price/qty step, ignoring the condition. Sensitivity arm:
**drop-conditioned** is not separable in these files (the public curves do not
flag which steps carry a complex condition), so the bound-from-both-sides is
instead the **domestic vs +net** contrast (Layer B) plus the ES=PT vs congested
split; this substitution is disclosed here, not discovered later.

- **GME.** Rows with `status ∈ {ACC, REJ, INC}` (final curve; REP/REV
  superseded). Supply = `purpose=OFF`, `unit_kind ∈ {UP, UPV}` (domestic +
  domestic-virtual; the pure-import UVZ layer is absent from these unit kinds).
  Demand = `purpose=BID`; a BID with `price ≤ 0` is a price-taker → placed at the
  ceiling (always buys). `(price, qty)` are the offered step. Granularity is PT60
  (hourly) in all seven downloaded files; period `p` = hour `p−1` (UTC = local −1
  CET / −2 CEST). Official price `P_off` = the file's own `awarded_price`
  (the exchange's published zonal price; hourly, per zone — preferred over the
  extract's PT15M rows per the "exchange's own price when present" rule). Net
  position (for `+net`) = `Σ awarded_qty(BID) − Σ awarded_qty(OFF)` = net import,
  injected as price-taker supply at the floor.

- **OMIE.** Rows flagged offered `O` (`Ofertada`). Supply = `Tipo V`, demand =
  `Tipo C`, all pool units (ES+PT). `(price, qty)` are the offered step; the
  15-min months use the first MTU of the local hour. Official price `P_off` =
  `entsoe.energy_prices` ES at the matching UTC hour, minute-0 row (the hourly
  PT60M price before Spain's 2025-10-01 15-min settlement go-live, the Q1 price
  after — matching the first-MTU curve); ES=PT on scored cells by construction. Net position (for `+net`) = net Iberian export =
  `Σ flow(ES/PT → non-Iberia) − Σ flow(non-Iberia → ES/PT)` from
  `entsoe.physical_flows` (hourly mean of the PT15M series), injected as
  price-taker demand at the ceiling when net export > 0 (else supply at floor).
  Physical (not day-ahead-schedule) flow is a disclosed approximation.

- **Quantity-unit sanity check (protocol, applied identically every day):** total
  offered domestic supply must be fleet-plausible — GME NORD in 15–65 GW, OMIE
  pool in 25–120 GW. The interpretation (MWh-per-period as MW as-is) that passes
  is used for all days; failures are reported.

- **Price limits fed to the engine:** GME `(-500, 4000)`, OMIE `(-500, 4000)`
  (real caps; disclosed as a structural constant, not tuned per day). Resolution
  code 60. Single node = the zone (GME) or `IBERIA` (OMIE). `network_topology =
  nothing`. Solver **HiGHS**; **fresh Julia process per market day**.

## 4. Metrics (frozen)

Per scored cell, both layers:
- **Layer A:** `dA = P_engine_domestic − P_crossing_domestic` (€/MWh). Report the
  `|dA|` distribution (median / p90 / max) and the share of cells within
  **€0.01 / €0.5 / €2**. A |dA| > €0.5 is a candidate solver finding —
  investigated to a minimal reproducing case.
- **Layer B:** `dB_dom = P_dom − P_off` and `dB_net = P_net − P_off`. Report each
  distribution (median / p90 / max), share within **€0.01 / €0.5 / €2**, and the
  **cleared-volume delta** (`V_engine − V_official`) where an official volume is
  available (GME awarded supply). Attribution of every `|dB_net| > €0.5` hour into
  one of: {import/coupling-set price (marginal unit not domestic), internal
  congestion (GME zone price ≠ neighbours), complex-order effect, discretization,
  tie/degeneracy}. Classification is by observable book/price signals, declared:
  - import/coupling-set: the injected net block is marginal (partially accepted)
    OR `P_off` lies above the domestic supply curve's top offered step.
  - congestion (GME): the zone's `awarded_price` differs from the day's modal
    Italian zonal price by > €0.5.
  - complex-order: none of the above and `P_off` sits between two adjacent offered
    steps by > €0.5 (a condition displaced the marginal step).
  - discretization / tie: residual ≤ one offered price step.

Scored-cell counts beside every figure. Aggregates = mean/median over available
cells, split by exchange and by regime (night 00–06 / midday 10–15 / evening
18–22, local).

## 5. Honesty clauses

- The answer may be "Layer A matches ~100% (solver is correct) and Layer B's
  residual is X%, fully explained by the missing coupling layer." That IS the
  deliverable, not a failure.
- A genuine engine defect (wrong tie-break, wrong curtailment/price-selection
  rule) surfaced by Layer A is a first-class finding, documented with a minimal
  reproducing case.
- No raw GME/OMIE row leaves `pubbooks/`; committed code references local paths
  via `PUBBOOKS_DIR` / the extract path only. The intermediate order files are
  derived data and stay in the scratchpad, uncommitted.

## 6. Ex-ante note

Nothing here feeds any model input. The real books and official prices are used
only as ground truth for a mechanistic comparison of the clearing solve.
