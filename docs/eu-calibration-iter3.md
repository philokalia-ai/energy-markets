# EU-wide footprint calibration — iteration 3 (MPCC Big-M root fix, CH, diagnostics)

Follow-up to `docs/eu-calibration-iter2.md` (PR #93, frozen). Priorities set
for this iteration: (1) per-order complementarity Big-M — the 2026-04-02 root
fix (mandatory), (2) CH profile, (3) NO5 Nordic-internal anchor, (4) HU/BE
adequacy diagnosis, (5) SE3/SE4 document-only.

**Sign convention: `bias = mean(sim − actual)` — positive = model overprices.**
Evaluation window: 2026-04-01…05 vs `entsoe.energy_prices` Day-ahead.
Baseline = `multi_zone_eu_cal8` (iteration-2 final). Shipped iteration-3
result = `multi_zone_eu_cal9`.

---

## 1. Per-order complementarity Big-M (shipped — all acceptance criteria green)

**Root cause found**: the acceptance-side (side-1) complementarity constant
was `2·q·span` — ~1e8 on multi-GW cap-priced demand blocks. Its
integrality-tolerance leakage (1e-5 × 1e8 ≈ 4000 €·MW) is what made the
2026-04-02 full-book model "provably" infeasible while the blamed hour
solved optimal in isolation.

**The fix is exact, not a tuning**: when `aux = 0`, acceptance = 0 forces
(via side 2's second constraint) `aux2 = 0` and hence `dual = 0` — the
2·span "dual headroom" was provably vacuous. The tight per-order constant is
`q·(bid − floor)` for supply, `q·(ceiling − bid)` for demand — **exactly 0**
for cap-priced demand blocks, whose coefficients disappear entirely.
Side-2's `max_surplus` was already per-order tight; the congestion-rent
constants are span/cap-exact. Bids outside the price limits keep their
documented behaviour (rejection impossible via `rhs ≥ 0` itself).

**Acceptance (all green)**:

- (a) **2026-04-02 clears OPTIMAL** with the iteration-2 books — first time;
  **all 5 days optimal** (cal9: 8.7–10.9 s solves).
- (b) **SEE 5-zone product byte-identical** (GR/BG/RO = 131.34, HU = 84.96,
  RS dropped); `test_mpcc.jl` 35/35, `test_multi_zone_mpcc.jl` 25/25.
- (c) **Prices unchanged within noise** vs cal8 on the 4 common clean days:
  every zone identical to 0.1 MAE (only the degenerate-tied IT chain moved
  ±0.1). The old Big-M was NOT binding anywhere — pure conditioning.
- Bonus: solve times improved ~10–20 % (day-2: 25 s false-INFEASIBLE → 8.7 s
  optimal).

Also shipped: the INFEASIBLE retry ladder restructured per review —
NumericFocus=3 + conservative presolve first, different seed as last resort,
each time-boxed, all gated (only reached on a claimed INFEASIBLE; unreachable
for day 2 now that the root fix landed).

## 2. CH profile (measured, GATED — target fixed, neighbor regression)

Diagnosis: CH is hydro-storage dominated but sat on CONTINENTAL, pricing its
storage gas-anchored — cal9 residual **+28…+78 in every hour**, worst at
peaks and RES-surplus midday (actual → ~0, sim stays ~47). Swiss reservoir
filling data exists (`entsoe.aggregated_hydro_storage_filling_rate`, 590
weekly BZN rows, current) — dryness is real, not a proxy.

`SWISS_PROFILE` (NORDIC-style reservoir-opportunity + two-pass `:hydro`
anchor; ref = capacity-weighted AT/DE_LU/FR/IT-NORTH pass-1 prices) was
measured as cal10 (5/5 days optimal):

- **CH itself: corr 0.82→0.86, MAE 40.2→26.7, bias +39.3→+10.2** — the
  hypothesis is confirmed; the mechanism transfers cleanly from Norway.
- **But the neighbors regress in shape** (identical actuals in both columns,
  so the differences are sim-side): AT corr 0.77→**0.57** (MAE +5.3),
  SI −0.08, SE2 −0.17. Beyond the no-regression tolerance.

Decision per acceptance rules: **CH stays on CONTINENTAL** in the shipped
state; `SWISS_PROFILE` remains defined and tested as the measured starting
point for an **AT-aware rollout** in iteration 4 — AT's price is shaped by
CH's anchor through the AT–CH border and needs its own treatment in the same
pass. cal10 rows remain in the DB as the experiment record.

## 3. NO5 Nordic-internal anchor (analyzed — rejected as circular)

The proposal was to anchor NO5 (and NO1/NO2/NO3) to Nordic neighbors instead
of the DE_LU/NL proxy. The anchor refs are extracted from **pass-1** prices,
and NO5's Nordic neighbors' pass-1 prices are the *unanchored* ones — the
very numbers the anchor exists to correct (NO1 ≈ €13, NO2 ≈ €51 pass-1 vs
actuals 94/85). Anchoring NO5 to them is definitionally worse than the
continental proxy; anchoring to their *refs* is the same proxy (circular).
The honest characterization of NO5's remaining −28: the Nordic system's
weekend price does not collapse with the continent because storage
arbitrages across days — an inter-day horizon the daily two-pass cannot
represent. Candidate real fixes (iteration 4+): a third sequential anchoring
pass (anchor NO5 against pass-2 Nordic prices), or a weekly reference
horizon for storage water value. Also noteworthy under the research framing:
part of the residual may be a genuine above-competitive-water-value finding.

## 4. HU / BE adequacy (diagnosed; prepared fix not run)

**HU residual is scarcity-shaped**: evening peak explodes (+190…+394 at
h15–19; sim €546 vs actual €152 at h17) while off-peak is modest. Border
audit: HU's observed flows to RO/RS/UA and HR are retained correctly (HR is
not in the footprint, so not excluded); the smoking gun is the ENDOGENOUS
import capacity — **HU's implicit ATCs collapse to 37–112 MW at the evening
peak** (AT→HU 37–71, SK→HU 29–59, SI→HU 85–112, vs 455–994 mid-morning)
while the real Core FBMC domain carries GWs. The model starves HU at exactly
the residual hours: the same flow-based-domain family as SE3/SE4, now
identified for the Core.

Prepared (staged, not run — out of window): extend the flow-based drop list
with HU's Core borders (HU–AT, HU–SK, HU–SI), giving HU the Nordic
treatment — observed imports instead of starved endogenous links. The diff
is in the iteration record; measuring it is the first cheap experiment of
iteration 4 alongside the CH/AT rollout.

**BE (+45)**: all-day elevated residual, worst mid-morning through midday —
consistent with the same Core-FBMC understatement (BE's real imports ride
FR/NL/DE Core capacity plus GB, which is outside the footprint), but its
flat shape means the diagnosis is not yet conclusive. Document-only.

## 5. SE3/SE4 — document-only (as instructed)

Unchanged (+50/+68 on the historical methodology). Flow-based domain model
remains the fix; the HU result strengthens the case that a single "drop the
flow-based borders, keep observed flows" treatment generalizes.

## Evaluation-methodology finding (affects future tables)

`entsoe.energy_prices` mixes **hourly and 15-minute day-ahead rows** for a
growing set of zones (quarter-hourly MTU), and the historical JOIN-based
evaluation matches sim hourly points against BOTH rows at :00 (duplicate
weighting), while a naive per-timestamp average mixes the 15-minute series
in. The two methods diverge wildly for DK2/LT/SE3/SE4. Within one table the
comparison is fair (identical actuals both columns), but cross-iteration
LEVELS are not comparable between methodologies. Recommended cleanup:
resolution-aware actuals (hourly series where present, else hourly mean of
the 15-minute series) as a shared eval helper — plus an index on
`entsoe.energy_prices (map_code, date_time_utc)`; the un-indexed join is
now minutes-slow as `simulations.energy_prices` grows.

## Shipped per-zone state

The shipped iteration-3 result (`multi_zone_eu_cal9`) is metrically identical
to cal8 (see §1(c)) — by design: the Big-M fix is solver-internals. The
per-zone table therefore remains iteration 2's cal8 table
(`docs/eu-calibration-iter2.md`), now valid on **all 5 days** with day 2
restored. Aggregate (39 zones, 4 clean days, historical methodology):
meanMAE 32.0, medMAE 31.4.

## Iteration-4 queue

1. CH/AT joint rollout of SWISS_PROFILE (AT-aware; measured starting point).
2. HU Core-border drop (prepared diff; measure the chain AT/SK/SI).
3. Eval-methodology cleanup (resolution-aware actuals + index).
4. NO5 inter-day storage horizon or sequential third pass.
5. BE Core diagnosis continuation; ES/PT drift; SE3/SE4 flow-based domain.
