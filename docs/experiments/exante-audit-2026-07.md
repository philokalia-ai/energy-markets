# Ex-ante audit of the published record (July 2026)

The July 2026 code review found that `run_pipelined_backfill` never resolves the
EU-footprint scoped ex-ante flow default: the book workers call `mz_build_books`
directly, which has no `ex_ante_mode`, so they use the process-wide
`FLOW_ASOF_MODE` — `:d0`, **same-day observed** physical flows — unless the env
var happens to be set. Every full record (cv22, cv23, cv24) was produced by that
pipeline. This audit settles what actually produced the published prices.

## Method

Re-clear a day from the record with an **explicit** flow mode and compare, cell
by cell, against the stored cv24 prices (`simulations.energy_prices`,
`clearing_mode='multi_zone_eu'`, `code_version=24`, local `data/results.duckdb`).
Both arms use the sequential path with the record's own settings —
`enrich_network=true, passes=2, order_method=:merit_order`, HiGHS, on the same
read-only extract the backfill used. Whichever arm reproduces the record is what
built it. Harness: `scratchpad/exante_audit.jl`.

## Result: the record is `:d0` — not ex-ante

| day | cells | `:d0` (same-day observed) | `:v3` (the documented ex-ante rule) |
|---|---|---|---|
| 2026-04-03 | 936 | **95.5%** bit-identical, mean \|Δ\| **0.51** | 47.0%, mean \|Δ\| 8.02 |
| 2024-02-14 | 936 | **93.8%** bit-identical, mean \|Δ\| **0.16** | 46.8%, mean \|Δ\| 3.21 |
| 2025-11-12 | 39 | **100%** bit-identical | 41.0%, mean \|Δ\| 3.36 |

The residual on the `:d0` arm is not a contradiction. On 2026-04-03, 34 of the 42
differing cells are numerical (\|Δ\| < 1e-6) and the remaining 8 sit in a **single
hour** (07:00) across coupled zones — the degenerate pass-2 anchor tie already
documented for cv20 (10 of 29,679 cells over a 39-day A/B). The `:v3` arm, by
contrast, differs on **half** the record with mean \|Δ\| of several €/MWh.

### What this means

- The ledger in `CLAUDE.md` states that from cv16 the EU-footprint path defaults
  to the fully ex-ante `:v2` rule, and from cv19 to `:v3`. **For every pipelined
  record that is not true.** The choice of `:v3` (the 39-day analogue-flows A/B)
  is not in question — it simply never reached the record.
- The published accuracy figures (cv24: corr 0.68 / MAE 26.3 comparable-year) are
  therefore **not ex-ante figures**. They use delivery-day observed cross-border
  flows, which no forecaster has.
- The live product is on the *other* side of this: `bin/daily_forecast.jl` clears
  through `run_multi_zone_market_clearing`, so it does resolve `:v3` and is
  genuinely ex-ante. The backtest record it is benchmarked against had an
  information advantage the live forecast does not — the comparison flatters the
  backtest.
- Any conduct residual derived from the record is affected wherever observed
  flows carried information the ex-ante rule would not have had.

Fixing this is not a patch: making `mz_build_books` resolve the mode *is* the
price change. It belongs in the cv25 bundle with the ATC canonicalisation
(`docs/experiments/review-2026-07.md`), followed by a full backfill.

## Second finding: 5% of the record is truncated, and was saved as complete

A **UTC** day always has 24 hours — there is no DST ambiguity — so any day with
fewer is a genuine truncation. Across the 1,304-day cv24 record:

| hours in the day | days |
|---|---|
| 1 | 12 |
| 2 | 19 |
| 3 | 2 |
| 21–23 | 32 |
| **fewer than 24** | **65 of 1,304 (5.0%)** |

That is **30,810 missing zone-hours, 2.52% of the record**, spread across every
year (2023: 6 days, 2024: 20, 2025: 26, 2026: 13).

**Mechanism.** `src/clearing/multi_zone_books.jl` intersects every zone's
periods:

```julia
common_periods = reduce(intersect, values(zone_periods))
```

so a **single** zone with a short book truncates the whole 39-zone day. The trim
is deliberate on the forecast path — it drops the unpublished next-CET-day tail —
but on a historical backfill it produces one-hour days. There is a `@warn`, and
then the day is saved with all 39 zones present and printed `DONE`.

**Why the review's first completeness fix did not catch it.** PR #212 made
resume zone-count aware. These days carry all 39 zones; only the hours are
missing. Completeness has two dimensions and the first fix only covered one.

### Shipped here (price-inert)

- `min_price_periods` (default 24) on `run_pipelined_backfill`: a day producing
  fewer distinct price periods is reported `TRUNCATED`, not saved, and its staged
  books are cleaned up — same housekeeping as any other failed day. `0` restores
  the old save-anything behaviour. Deliberately scoped to the **backfill**: the
  forecast path's trim is intentional and is left alone.
- The resume probe now requires **both** the full zone count and
  `min_price_periods` hours.

Neither gate touches a price — they change only which days are recorded as
complete. No file on the price path is modified.

## Not addressed here

- The `:d0` → scoped-`:v3` fix for `mz_build_books` (price-changing → cv25).
- The same truncation gate for the sequential runners (`bin/main.jl`,
  `bin/eu_calibration_run.jl`). The pipeline is what produced the full records,
  so it is gated first; the sequential paths should get the same treatment before
  they are next used for a record.
- Re-deriving the 65 truncated days. They will be re-processed automatically by
  the next backfill now that resume no longer treats them as complete.
