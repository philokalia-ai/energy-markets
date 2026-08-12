# World S v3 — gate 1 results (2026-08-12): FAIL on the frozen gates, with real signal

Frozen prereg #336 (+2 dated pre-scoring amendments). Condition-bucket
profiles (sun-up × temperature terciles × solar-share terciles, terciles
from the calibration period only; per-test-day trailing ≥30d calibration
over the 364-day dense GME set), scored on the untouched 9-day confirmation
set. 1,043 unit-days.

| scope | profile wins (% MW) | gate | med distance SRMC → profile |
|---|---|---|---|
| overall | **53.3%** | ≥60 ✗ | 66.3 → **36.4** |
| winter (n=472) | **59.0%** | ≥55 ✓ | 67.5 → **25.3** |
| spring (n=351) | 48.7% | ≥55 ✗ | 69.4 → 51.1 |
| summer (n=220) | 48.7% | ≥55 ✗ | 59.2 → 37.6 |

**The gates fail; per the frozen protocol the coupled arms do not run.**

## Honest reading

The owner's condition axes clearly CARRY signal: vs the calendar-blind v2
(48.2% overall, non-winter 43–45%), v3 gains +5 pts overall and the median
bid distance HALVES (and winter now clears its seasonal bar). But the
win-share is bimodal: where profiles help they help a lot (the median), yet
on roughly half the MW the SRMC ladder remains marginally closer — the
condition buckets fix the level regime but not the unit-by-unit tranche
placement in the solar seasons.

Not done (would be post-hoc): switching the gate to the distance metric that
"would have passed". The frozen metric was win-share; it failed; recorded.

## Options for the owner (no work started)

1. **v4 with richer conditioning** (per-unit continuous regressions on the
   condition variables rather than terciles; or hour-of-sun-position buckets)
   — the trajectory (43→48→53) says each iteration buys ~5 pts; the gate
   needs +7 more. Diminishing but not exhausted.
2. **Accept the winter-scoped result**: a winter-only World-S label (its
   season passes both bars) — a partial world, honestly scoped.
3. **Park World S** with three measured iterations and the strongest
   characterization of conduct any part of the program has: stable shapes,
   condition-dependent levels, exchange-vs-market volume bases.

Artifacts: ws3_gate1.csv, ws3_conditions.parquet, 364-day GME raw set,
profiles machinery (session scratchpad pubbooks/).
