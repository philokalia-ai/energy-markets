# EU-wide footprint calibration — iteration 2 (France & Norway)

Follow-up to `docs/eu-calibration-iter1.md` (PR #92, frozen). Iteration 1's two
honest remaining gaps for the target regions were:

- **NO1/NO5**: flat undershoot (bias −79/−65) — water value ≈ 0.35×gas with
  full reservoirs is too cheap for zones coupled to an €85–105 continent.
- **FR**: the static €55 nuclear floor got the level right on average (bias
  +8.5) but is a static stand-in — it overprices exactly the RES-surplus hours
  where the coupled price collapses (2026-04 weekend actual €9 vs sim €53).

Both are the same structural object: a dominant **modulating resource**
(stored hydro / nuclear) that prices at **opportunity cost against the coupled
continental price**, not against local fuel cost.

**Sign convention: `bias = mean(sim − actual)` — positive = model overprices.**
Evaluation window: 2026-04-01…05, vs `entsoe.energy_prices` Day-ahead.
Baseline for this iteration = `multi_zone_eu_cal4` (iteration 1 final).

---

## The mechanism: two-pass opportunity-anchor clearing

`run_multi_zone_market_clearing(...; passes=2)` — merit-order only, default
`passes=1` keeps every existing path (SEE, single-pass EU) bit-for-bit
unchanged (unit-tested no-op).

1. **Pass 1** clears the footprint exactly as iteration 1 (cal4 books).
2. **Anchor extraction** (`compute_opportunity_anchor_refs`): for each zone
   whose profile opts in, a per-timeslot reference price = the
   border-capacity-weighted mean of its *endogenous* neighbors' pass-1 prices
   (level AND hourly shape). Zones with no endogenous neighbors (Norway — its
   flow-based borders are dropped) fall back to the DE_LU/NL continental
   proxy. All inputs are model-internal, so the counterfactual stays ex-ante —
   no observed prices enter.
3. **Pass 2**: only anchored zones rebuild their books against the reference;
   every other zone reuses its pass-1 orders verbatim (no second book-build
   cost); the footprint re-clears. If pass 2 fails, the pass-1 result stands.

Profile opt-in (`ZoneProfile.opportunity_anchor`, default `:none`):

- **`NORWAY_PROFILE` (`:hydro`)** — NO1/NO2/NO3/NO5. In pass 2:
  - water value = `clamp(ref_ts × (share + dry_boost × dryness), 2, gas SRMC)`
    — full reservoirs undercut the continent to export, dry ones price above;
  - observed **imports** priced at the border price (`share × ref_ts`), not €1
    — import-covered hours clear at the coupled price (NO1's fix);
  - observed **exports** re-enter as ref-priced demand (not cap-priced, not
    dropped) — structural exporters keep their outlet without being able to
    manufacture cap scarcity (NO5's fix).
  - NO4 (far north, actuals ≈ €18, congestion-isolated like SE1/SE2)
    deliberately stays on plain `NORDIC_PROFILE`.
- **`FRANCE_PROFILE` (`:nuclear`)** — per-slot nuclear bid base
  `max(SRMC, share × ref_ts)` REPLACES the static €55 floor in pass 2, so the
  floor collapses with the coupled price in RES-surplus hours. Pass 1 keeps
  the static floor (= cal4 behaviour). `anchor_share` calibrated on the
  measured share→bias line: 0.9 → bias +33, 0.7 → +21, **0.55 → target
  |bias| ≤ 10** — the neighbor-weighted ref imports the overpricing of
  CH/BE/ES, so the share must discount it.

## Diagnose-first evidence (from cal4)

- **NO1** residual flat −56…−92 all day; sim ≈ €3 at night (the observed-import
  block at €1 was price-setting) vs actual ≈ €88 tracking its neighbors.
- **NO5** residual dead-flat −58…−70; a structural exporter whose surplus had
  no outlet after the import-only clamp.
- **FR** hourly: nights −10…−17, midday +17…+33; weekday sim 77.5 vs act 104,
  weekend sim 53 vs act **9.3** — the static floor cannot follow the coupled
  price down.
- Reservoir filling data exists per NO1–NO5 BZN (not only the NO aggregate);
  NORDIC/NORWAY profiles do apply — the failure was pricing, not plumbing.

## Iteration history (5-day, measured after each single change)

| run | change | key measurements |
|---|---|---|
| cal5 | two-pass anchor, share 0.9 | NO2 corr 0.63→**0.92** bias −8; NO3 corr 0.26→**0.65** bias 0.0; NO5 MAE 65→37; FR corr 0.76→**0.83** but bias +8.5→+33; NO1 −79→−69 (import block still price-setting) |
| cal6 | FR share 0.7; imports at border price | **NO1 corr 0.38→0.89, MAE 79→25**; FR bias +21 (still high); NO5 unchanged −34 (export outlet missing) |
| cal7 (final) | FR share 0.55; exports ref-priced; MPCC DualReductions retry | table below |

Solver robustness: the 2026-04-02 book is numerically borderline — Gurobi's
presolve returns the ambiguous INFEASIBLE_OR_UNBOUNDED as a coin-flip across
otherwise identical runs (optimal in cal3/cal4, failed first-attempt in
cal2/cal5/cal6). `solve_mpcc_market_clearing` now retries that status once
with `DualReductions=0`, which forces Gurobi to disambiguate (this model class
cannot actually be unbounded). No-op for every other solve.

## Guards

- SEE 5-zone product **byte-identical** at every commit (GR/BG/RO = 131.34,
  HU = 84.96, RS dropped — same 2026-04-03 check as iteration 1).
- `test/test_zone_profiles.jl` grows to 61 tests, incl. "anchor_prices without
  profile opt-in is inert (byte-identical)" and "with opt-in it changes the
  book".
- Two-pass is fully gated: `passes=1` default; a `passes=2` request with no
  opted-in zone short-circuits to the pass-1 result.

## Per-zone metrics: cal4 (iteration-1 final) → cal7 (iteration-2 final)

<!-- TABLE -->

## Acceptance and honest remaining gaps

<!-- SUMMARY -->
