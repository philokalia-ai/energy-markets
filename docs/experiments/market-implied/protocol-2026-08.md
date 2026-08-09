# Market-implied RES forecast (protocol draft, 2026-08-09)

Owner-approved question (2026-08-08, the market-epistemology exchange): the
market clears on **participants' private forecasts**, not the TSO's published
D-1 fc and not the actuals. Our R1 result (actuals-target ML beating the TSO
fc as a *price* input in GR/IT-Sicily/IT-Sardinia/RO) is consistent with the
private forecasts sitting closer to the best-achievable D-1 forecast than the
TSO's. This experiment measures that object directly: **the solar MW the
market "believed"**, recovered by inverting our own book.

## Definition (the inversion)

For a zone-hour in the solar regime, the implied RES is the value `S*` such
that clearing OUR book with RES = `S*` reproduces the settled price:

    price_model(book(S)) = price_settled   →   S* = argmin_S |Δprice|

- The book's price is a monotone non-increasing step function of injected RES
  (more RES pushes the marginal tranche down the ladder), so `S*` is found by
  bisection over a bounded window `S ∈ [0, 1.3 × cap95]`.
- Step-function caveat: the settled price often falls between two tranche
  prices — then `S*` is an INTERVAL `[S_lo, S_hi]` (every S in it produces
  the same nearest tranche). We record the interval, use its midpoint as the
  point estimate, and its width as the identification quality; hours where
  the width exceeds 30% of cap95 are UNIDENTIFIED and excluded (reported).
- Identification requires the marginal tranche to be price-sensitive to RES:
  cap hours, collapse-floor hours and hours where imports set the price are
  excluded ex-ante (the book tells us which — the same tagged-owner
  attribution the strategist hook uses).

## Scope (phase 1: single-zone, no coupling)

Single-zone books only (GR first, then the other three R1 solar winners RO /
IT-Sicily / IT-Sardinia) — the multi-zone coupled clear makes `S*`
ill-defined per zone (neighbouring books move the price too). The single-zone
GR book is the program's oldest calibrated object and bit-stable offline.

- Window: 2025-08-01..2026-07-28 (the R1/cv32 comparison year; extract-ready).
- Hours: solar-regime hours only (se > 0 and solar share of load ≥ 0.15 —
  below that the book's price barely reads solar and `S*` is unidentified).

## Comparators (per zone-hour, MAE/bias vs actual solar)

1. `S*` (market-implied, this experiment)
2. TSO D-1 fc (the current default input)
3. Our actuals-target ML (the cv32 corrections)
4. Actual solar (the target; also the oracle bound = 0 by construction)

## Hypotheses (frozen BEFORE scoring)

- H1: MAE(`S*` vs actual) < MAE(TSO fc vs actual) in the identified set —
  the market is better-informed than the TSO fc.
- H2: MAE(`S*` vs ML) < MAE(`S*` vs TSO fc) — our ML is closer to what the
  market believes than the TSO fc is (the co-adaptation explanation: the
  calibrated book absorbed the participants'-forecast gap).
- H3 (diagnostic, no gate): the `S*` − ML residual in collapse hours has
  structure (systematic sign) — points at what the next input package should
  target near the collapse threshold (methodology rule 4).

No ship decision hangs on this experiment — it is a measurement instrument
for the R-cycle (it ranks input candidates by distance-to-market, not by
price MAE, so it cannot be gamed by book compensation). Its output feeds the
Iberia/core package prereg.

## Mechanics

- Offline extract, fresh process, `save_to_db=false` throughout; scenario
  hook `renewable_modifier` injects the trial S (uniform scaling of the
  solar part of the RES profile in the trial hour).
- Bisection: ≤12 book evaluations per hour; the book is built ONCE per
  (zone, day) and re-cleared per trial via the modifier (build dominates
  cost, so a day of 24 hours ≈ 1 build + ≤288 cheap re-clears).
- Settled prices: `entsoe.energy_prices` (the eval scripts' source).

## Status

- [ ] Protocol ratified (this file) — freeze hypotheses before any scoring
- [ ] GR implementation + 5-day pilot (identification-rate check)
- [ ] GR year run → H1/H2 tables
- [ ] RO / IT-Sicily / IT-Sardinia
- [ ] Findings → Iberia/core package prereg
