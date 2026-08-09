# Market-implied solar — GR year results (2026-08-09)

Protocol: [protocol-2026-08.md](protocol-2026-08.md) (hypotheses frozen before
scoring). Run: GR single-zone, offline extract, 2025-08-01..2026-07-28,
per-hour bisection (12 iters, ±5 €/MWh identification tolerance), solar-regime
hours (fc share of load ≥ 0.15). 3,553 regime hours; **2,081 identified (59%)**;
scored set = identified ∩ actuals ∩ ML = 2,075 hours over 352 days.

## Headline tables (MW, vs actual solar)

| comparator | full year MAE | bias | summer MAE | winter MAE | collapse (≤5€) MAE |
|---|---|---|---|---|---|
| TSO D-1 fc | 1,047 | +1,024 | 1,254 | 901 | 1,797 |
| our ML (cv32 corrections) | 442 | −10 | 448 | 438 | 447 |
| **market-implied S\*** | 1,416 | +986 | 1,642 | 1,255 | **2,517** |

Implied vs fc: MAE 1,011, bias **−38**. Implied vs ML: MAE 1,455, bias +997.
corr(implied−fc, ml−fc) = **0.09**; corr(implied−fc, act−fc) = **0.04**.

## Verdicts

- **H1 REJECTED**: the implied is NOT closer to actuals than the TSO fc
  (1,416 vs 1,047). The market-implied object, recovered through OUR book, does
  not read as a better forecast of actual solar.
- **H2 REJECTED**: the implied is closer to the fc (MAE 1,011) than to our ML
  (1,455), and the hourly innovations are uncorrelated with both (≈0.04–0.09).
  At hourly granularity the inversion is dominated by non-solar book error
  (imports, scarcity margin, demand) — it does not isolate the market's solar
  belief.

## What the instrument DID measure (the two real findings)

1. **Book–fc co-adaptation, now quantified.** The implied's mean level sits on
   the fc basis (bias vs fc: −38 MW) while both are ~+1 GW above the actuals
   basis (GR fc forecasts a wider solar perimeter than the per-type actuals
   report — the ML learns the basis conversion, bias −10). The book, calibrated
   for years consuming the fc, "expects" fc-basis solar: inverting it returns
   the fc, not reality. This is the sharpest measurement yet of the
   co-adaptation thesis (oracle-input regressions, cv32 full-set rejection, and
   now the inversion all say the same thing) — and it PREDICTS the cv32 lesson
   that a better input alone must worsen prices until the mechanisms retrain.
2. **The GR collapse gap ≈ +2.5 GW.** In settled-≤5€ hours the book needs
   ~2,517 MW MORE solar than reality (and +2,410 more than the ML's
   already-accurate estimate) before its own price collapses. The collapse
   residual is therefore a QUANTITY/commitment deficit in the book (must-run /
   surplus-absorption blocks), not an input-forecast problem and not the floor
   price — confirming the cv31 postmortem's "commitment/quantity issue" with a
   measured magnitude for GR.

## Decision

- NO extension to RO / IT-Sicily / IT-Sardinia: the instrument does not
  identify forecast innovations at hourly granularity (near-zero correlations);
  more zones would re-measure the same book-error dominance at higher cost.
  A future variant would need to invert only hours where the book's marginal
  tranche is RES-adjacent AND jointly over (solar, imports) — parked.
- Finding 2 feeds the surplus/must-run quantity work (the natural cv31
  follow-up); finding 1 is standing context for every input package: inputs
  ship WITH mechanism recalibration, never alone.

Artifacts: session scratchpad `mimplied/` (year_runner.jl, gr_year_*.csv,
gr_year_all.csv — 6-way chunked run, ~55 min wall).
