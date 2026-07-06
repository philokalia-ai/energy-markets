# Research roadmap: competitive counterfactual → strategic-bidding detection

*Last updated: 2026-07-06, branch `feature/see-multizone-unlock` (PR #78).*

## What we are trying to do

This is a two-phase research program, not a price-forecasting exercise:

**Phase A — model ideal market conditions.** Build the most accurate
*competitive counterfactual* the data allows: what day-ahead prices would be
if every participant bid true short-run marginal cost plus rational
competitive strategy (merit order, hydro opportunity cost, scarcity rents,
cross-border coupling). The point of accuracy work is NOT MAE → 0; it is to
clean out every mechanical error source (data gaps, wrong costs, missing
constraints) **so that outliers become visible and interpretable**. The
residual `actual − counterfactual` is the object of study.

**Phase B — model the outliers' strategies.** For the days/hours/units where
actual prices sit persistently above any competitive reconstruction, model
what strategic players are doing and — crucially — **what signals they rely
on to know they can push prices**. Working hypotheses for the signal set
(all observable before the auction):

- capacity margin implied by the day-ahead load forecast vs available fleet
- low wind/solar forecast days (RES can't discipline the stack)
- hydro reservoir levels (drought = weak hydro competition — now in the DB)
- announced outages (`unavailability_*` — note outage *timing* itself can be
  strategic; cross-check announced outages vs unit economics)
- interconnector ATC reductions / neighbor-zone scarcity (imports can't
  discipline the price)
- gas/carbon price moves (cost pass-through cover for markups)
- pivotal-supplier situations: hours where one firm's capacity is required
  to meet demand (Residual Supplier Index) — the classic withholding signal
- day-of-week/holiday demand inelasticity, recent price momentum (learning)

Methodology for Phase B: per-unit analysis. We have unit-level actual
dispatch (`actual_generation_output_per_generation_unit`); compare each
plant's actual dispatch against its model-expected dispatch, invert the merit
order to estimate unit-level *implied markups*, regress implied markups on
the signal set, and test for **cross-firm correlation beyond common signals**
(the collusion test — coordinated behavior looks like correlated markup
shifts that shared observables cannot explain).

## Where we are (Phase A state)

**Model:** `:merit_order` order books + MPCC clearing. Formulation is now
sound: both complementarity sides (price pinned by the marginal order),
market-coupling price condition on flows (congestion rent structure),
deterministic competitive price selection. Bidding structure: SRMC tranches,
graduated must-run self-scheduling (UC-lite commitment), hydro water value
(gas-anchored, reservoir-dryness boosted), quartic peak markup, scarcity
margin on derated dispatchable capacity, observed net imports for
out-of-footprint borders.

**Costs:** gas from real TTF closes (D−1, no lookahead; ceres ETL refreshes
nightly), EUA carbon from a yearly lookup 2019–2026 (`EUA_PRICE_BY_YEAR` —
no real feed yet), other fuels from `FUEL_SRMC_BASE` + emission factor × EUA.

**Data fixes that mattered:** stale-outage override (units generating during
claimed outages), fleet completion from per-type actuals (RO/BG/RS were
clearing at spurious shortage caps), canonical fuel spelling `pondage`
(run-of-river was mispriced ~€110 → €3 in every zone), reservoir filling
rates (ceres PRs #474/#475), net-import resolution/dedup fixes, TTF ETL
(ceres #470).

**Benchmarks** (24 seeded-random held-out days, `test/scripts/eval_pricing_accuracy.jl <method> "<days>" <ZONE>`):

| zone | MAE | bias | corr |
|------|-----|------|------|
| GR | 31.5 | −15.1 | 0.80 |
| BG | 61.4 | +10.1 | 0.65 |
| RO | 90.7 | +62.4 | 0.71 |
| RS | 61.2 | +31.3 | 0.56 |
| HU | 66.3 | −50.7 | 0.34 |

(4-day quick benchmark days: 2023-12-01, 2025-04-26, 2025-07-02, 2026-01-26.
The 20 extra scale-test days are in the eval harness history / PR #77-#78.)

**Performance:** ~12 s per zone-day (was ~160 s; get_generators query-plan
fixes), HiGHS 1.24 + Julia 1.12, Gurobi 13 via WLS academic license is the
auto-preferred solver (9–125× on multi-zone MIPs, worst case ~1 s; auto
falls back to HiGHS cleanly when unlicensed). Full 5-zone × 24-day sweep:
minutes.

## Persistent gaps

Some are model/data debt (fix in Phase A), some are candidate findings
(hand to Phase B):

1. **High-price coupled days (candidate finding).** GR actuals of €148–167
   on 2025-05-21 / 2024-08-27 / 2025-10-20 sit far above any competitive
   reconstruction we can build — single-zone (~88–115) or 5-zone coupled
   (~85–132) — while GR≡BG to the decimal in actuals (coupled market).
   After the July 2026 multi-zone fixes the residual is **uniform across
   the region**: GR/BG/RO/RS all at −57…−77 bias with corr 0.6–0.9 on
   these days — the whole SEE region clears one tranche below actuals
   with the right hourly shape. **This is exactly the residual class
   Phase B should attribute per-unit.**
2. ~~Multi-zone instability~~ **resolved (July 2026, PR #79)** — the
   2026-01-13 "overshoot" (311 vs 147) was a solver-tolerance artifact
   (1% MIP gap on a cap-dominated objective let the incumbent curtail
   demand at the €3000 cap), and the 2025-10-20 BG/RO explosion (487 vs
   160) was phantom scarcity from excluding observed imports over borders
   with no ATC links. Fixes: gap 1e-6, component-wise competitive price
   reconstruction with rent-sign validation, border-aware import
   exclusion. Structural fact learned: **HU–RO ATC data ends 2022-06-08
   (Core flow-based coupling go-live) and RS has no implicitly coupled
   borders at all** — post-2022 the honest ATC footprint is the GR–BG–RO
   chain; RS/HU clear standalone with observed injections, which is the
   actual market design, not a data gap.
3. **HU is an import price-taker** (30–40% imported; price set by Core
   via AT/SK/SI/HR): single-zone HU cannot work; needs a wider footprint
   or a regional price anchor. Multi-zone confirms: HU bias −131…−174 on
   regional scarcity days even when GR/BG/RO/RS are within −27…−88.
4. **GR level bias −15:** appeared when the stale-outage fix re-included
   real units (the old flattering number was error cancellation);
   availability/tranche level recalibration against the corrected fleet is
   pending.
5. ~~No EUA/API2 price feeds~~ **EUA resolved (July 2026)** — daily EUA
   closes now come from `yfinance.eua_co2` (SparkChange Physical Carbon ETC
   "CO2.L", ceres PR #477; history from Nov 2021, yearly-lookup fallback
   before that). API2 coal evaluated and skipped: Yahoo's `MTF=F` is stale
   since Feb 2025 and the SEE footprint is lignite-dominated (mine-mouth
   pricing, not seaborne coal).
6. **`:uc_based` is degenerate** (`committed_only` offers supply == demand,
   price pins to the most expensive committed unit) — needs a bidding
   strategy rework if UC-based pricing is wanted.
7. **Mixed resolutions in multi-zone** are handled by aggregating to hourly;
   native 15-min multi-zone clearing is future work.

## Iteration protocol (how to continue)

1. Eval on the fixed 24-day set (never tune on it with other data, it is the
   held-out benchmark; sample new seeded days for anything exploratory).
2. Diagnose the worst residual days hourly (`sim vs act` tables); classify
   the cause: data (fix it), competitive-model structure (fix it),
   or unexplained (candidate strategic behavior).
3. Keep correctness over benchmark: if a data fix worsens metrics, the old
   number was error cancellation — recalibrate levels honestly.
4. Adversarial code review after each substantive change
   (`/code-review high`), findings → fixes → re-eval.
5. When Phase A residuals stabilize, move to Phase B per-unit attribution
   (implied markups vs the signal catalogue above).
