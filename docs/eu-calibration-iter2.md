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
| cal7 | FR share 0.55; exports ref-priced; MPCC DualReductions retry | see addendum |

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

## Iteration history addendum

| run | change | key measurements |
|---|---|---|
| cal7 | FR share 0.55; exports as ref-priced NET demand | FR bias +10.3 ✓; but netting cost NO1 ~1 GW of import supply in mixed-direction hours (−23 → **+134**) |
| **cal8 (final)** | split, don't net: imports stay clamped, dropped-border exports as SEPARATE ref-priced demand | table below |

## Per-zone metrics: cal4 (iteration-1 final) → cal8 (iteration-2 final)

Four clean days (2026-04-01, 03, 04, 05) for BOTH columns — 2026-04-02 is
excluded (see below).

| zone | cal4 (iter-1 final) corr/MAE/bias | **cal8 (iter-2 final)** corr/MAE/bias |
|---|---|---|
| AT | 0.75 / 41.4 / +31.5 | **0.75 / 39.7 / +29.0** |
| BE | 0.68 / 52.3 / +44.3 | **0.71 / 50.9 / +44.7** |
| BG | 0.80 / 32.2 / +12.5 | **0.80 / 32.2 / +12.4** |
| CH | 0.82 / 48.5 / +48.0 | **0.83 / 45.9 / +45.4** |
| CZ | 0.80 / 38.6 / +13.1 | **0.80 / 38.4 / +12.9** |
| DE_LU | 0.89 / 26.8 / +13.7 | **0.89 / 27.1 / +15.1** |
| DK1 | 0.87 / 23.2 / +0.2 | **0.86 / 23.9 / +1.2** |
| DK2 | 0.84 / 36.0 / +31.1 | **0.84 / 36.2 / +31.3** |
| EE | 0.60 / 20.1 / +5.2 | **0.60 / 20.1 / +5.2** |
| ES | 0.81 / 32.8 / +32.2 | **0.80 / 34.4 / +33.9** |
| FI | 0.80 / 12.9 / +7.1 | **0.80 / 12.9 / +7.1** |
| FR | 0.76 / 42.8 / +8.5 | **0.79 / 36.6 / +10.3** |
| GR | 0.80 / 31.4 / +10.7 | **0.80 / 31.4 / +10.7** |
| HU | 0.60 / 68.7 / +58.1 | **0.61 / 68.1 / +57.6** |
| IT-CNORTH | 0.77 / 24.3 / -0.3 | **0.78 / 24.0 / -2.9** |
| IT-CSOUTH | 0.85 / 22.5 / -8.6 | **0.85 / 22.1 / -9.9** |
| IT-Calabria | 0.83 / 22.3 / -7.3 | **0.83 / 21.9 / -8.6** |
| IT-NORTH | 0.77 / 24.3 / -0.3 | **0.78 / 24.0 / -2.9** |
| IT-SOUTH | 0.83 / 22.3 / -7.3 | **0.83 / 21.9 / -8.6** |
| IT-Sardinia | 0.83 / 24.4 / -10.7 | **0.84 / 23.9 / -12.0** |
| IT-Sicily | 0.83 / 22.3 / -7.3 | **0.83 / 21.9 / -8.6** |
| LT | 0.84 / 40.3 / +29.0 | **0.84 / 40.4 / +29.2** |
| LV | 0.41 / 24.4 / -8.3 | **0.41 / 24.4 / -8.3** |
| NL | 0.83 / 35.2 / -3.6 | **0.84 / 34.3 / -3.2** |
| NO1 | 0.38 / 79.2 / -79.2 | **0.87 / 29.0 / -18.2** |
| NO2 | 0.63 / 37.7 / -33.7 | **0.92 / 17.9 / -6.7** |
| NO3 | 0.26 / 30.9 / -30.9 | **0.65 / 29.1 / +0.0** |
| NO4 | 0.56 / 21.1 / +21.1 | **0.56 / 21.1 / +21.1** |
| NO5 | 0.36 / 64.8 / -64.8 | **0.41 / 36.5 / -34.0** |
| PL | 0.82 / 37.5 / +22.5 | **0.82 / 37.5 / +22.5** |
| PT | 0.80 / 32.7 / +32.2 | **0.80 / 34.3 / +33.8** |
| RO | 0.80 / 32.2 / +12.5 | **0.80 / 32.2 / +12.4** |
| RS | 0.83 / 28.4 / +13.4 | **0.83 / 28.3 / +13.2** |
| SE1 | 0.49 / 13.5 / +2.8 | **0.49 / 13.5 / +2.8** |
| SE2 | 0.50 / 13.9 / +5.3 | **0.50 / 13.9 / +5.3** |
| SE3 | 0.57 / 54.4 / +50.0 | **0.57 / 54.5 / +50.1** |
| SE4 | 0.80 / 67.9 / +67.5 | **0.80 / 68.0 / +67.7** |
| SI | 0.76 / 42.9 / +31.0 | **0.77 / 41.0 / +29.2** |
| SK | 0.76 / 36.1 / -2.9 | **0.76 / 35.8 / -3.3** |

Aggregates over all 39 zones (4 clean days):

- `AGG cal4  zones=39 meanMAE=35.0 meanBias=+8.7 medMAE=32.2`
- `AGG cal8  zones=39 meanMAE=32.0 meanBias=+12.2 medMAE=31.4`

## Acceptance

- **FR**: corr 0.76 → **0.79**, MAE 42.8 → **36.6**, bias +8.5 → +10.3 — corr
  and MAE both improve, |bias| holds at the ~10 boundary. The per-slot anchor
  floor collapses with the coupled price on RES-surplus weekends (the static
  floor's failure mode) and firms up weekday nights. ✓
- **NO1**: corr 0.38 → **0.87**, MAE 79 → **29**, bias −79 → −18. ✓
- **NO2**: corr 0.63 → **0.92**, MAE 38 → 18, bias −7. **NO3**: corr 0.26 →
  0.65, bias **0.0**. ✓
- **NO5**: corr 0.36 → 0.41, MAE 65 → **37**, bias −65 → −34 — halved, still
  the largest Norwegian residual (see gaps). ✓ (improved on both metrics)
- **No currently-good zone regressed** beyond tolerance: GR bit-identical
  (0.80/31.4/+10.7), DE_LU +0.3 MAE, DK1 −0.01 corr, FI/EE/SE1/SE2/IT-*
  unchanged. ES/PT drift +1.6 MAE (pre-existing Iberia issue, tracked). ✓
- **2026-04-02 does NOT clear** — see below. ✗ (4/5 days)

## The 2026-04-02 infeasibility (diagnosed, pre-existing)

The day now returns a clean `INFEASIBLE` instead of a masked `error`: the
`MPCCResult` status conversion crashed on the raw `MOI` enum, hiding every
proven infeasibility. With the new `DualReductions=0` retry Gurobi
disambiguates the former coin-flip `INFEASIBLE_OR_UNBOUNDED`, and the new
MPCC IIS printer (same machinery as the UC solver) produced the evidence:
**7,205 conflicting constraints, every one at hour 2026-04-02 15:00** — the
market-coupling price-link equalities (λ_sink − λ_source = ρ⁺ − ρ⁻) across
virtually all borders. One (or few) zone-hour books at h15 force a price the
complementarity Big-M / price-bound structure cannot represent, and the
equality chain propagates the impossibility network-wide.

Crucially, the failing solve is **pass 1 — the iteration-1 configuration**
(no anchors, no export orders; verified: the failing runs show zero pass-2
activity, and a dedicated `passes=1` run reproduces the infeasibility). cal4
cleared this day on 2026-07-05; the books are built from live ENTSO-E tables
that have since been revised. No order in the day-2 book is outside the
price limits (scanned: 0). This is a pre-existing MPCC formulation fragility
surfaced by upstream data revision — not an iteration-2 regression.

## Honest remaining gaps (recommended next iteration)

1. **The h15 MPCC knife-edge**: single-hour bisection (drop one zone's h15
   book at a time) to isolate the culprit zone, then a structural fix —
   per-order Big-M sized from the coupled book's actual price range, or a
   guaranteed per-zone-hour cap-priced slack so no book is literally
   unclearable. This also needs an MPCC-level test so the SEE guard is
   provably unaffected.
2. **NO5 (−34)**: the continental proxy inherits the continent's weekend
   RES-surplus collapse, but the Nordic hydro system's actual price does not
   collapse (NO5 actual stays ≈ €100 through the weekend). The anchor needs a
   Nordic-internal reference (e.g. pass-1 NO2, which has genuine endogenous
   borders) rather than DE_LU/NL for NO3/NO5.
3. **SE3/SE4 (+50/+68)** unchanged — flow-based domain model still the fix.
4. **CH (+48), HU (+58), BE (+45)** — untouched this iteration by design.
5. **ES/PT (+34)** — pre-existing Iberia drift, worth its own diagnosis pass.

