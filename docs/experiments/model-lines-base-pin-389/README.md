# Pinning the model line's physics base (#389)

**Date:** 2026-09-13 · **Scope:** `bin/emit_model_lines.py` · **No model change**

## The gap

PR #386 bound the emitter's *book features* and its *training artifact* to one
record version. The third input was left unpinned: the **physics base** itself.

```sql
ROW_NUMBER() OVER (PARTITION BY bidding_zone, date_time_utc
                   ORDER BY lead_days ASC, prediction_made_utc DESC)
FROM simulations.forecast_prices WHERE input_mode LIKE 'weather%'
```

`simulations.forecast_prices` carries several record versions side by side. In
the last 20 days alone: cv32 (33,033 rows), cv34 (6,552), cv35 (6,552), cv37
(77,688), cv38 (6,552), cv39 (24,336). "Freshest per (zone, hour)" takes
whichever version happens to be newest, so one emitted line could sit on a base
of mixed vintage — and the residual added on top was fitted against exactly one.

## What it actually was

Measured on the live window a production run covers (T−2 … T+7, 2026-09-11 …
2026-09-20): **9,243 of 9,243 cells, all 39 zones, came from cv39.** Not mixed —
uniformly the wrong version. The published `hybrid_gbm` line is a **cv37-trained
residual added to a cv39 physics base**, for every cell.

## The fix

`MODEL_LINES_BASE_CV` pins the base; unset, it follows `MODEL_LINES_CV`, i.e.
the version the artifact was trained against. Cells with no row of that version
are not emitted, and the run says so per day. `MODEL_LINES_ALLOW_MIXED_BASE=1`
restores the old freshest-wins behaviour, and even then the version mix is
printed rather than assumed. Each emitted row records the base it was built on
in a new nullable `simulations.model_lines.base_code_version` (additive — rows
written before this are NULL, no reader breaks).

## What the pin costs today, and why that is the point

Dry run, default pin (cv37, the artifact's version):

```
model lines: physics base PINNED to cv37 — cells by version: cv37=4641
2026-09-11 … 2026-09-15: emitted
2026-09-16 … 2026-09-20: no physics forecast rows — skipped
EMITTED 8844 rows
```

**Five of the ten days lose their hybrid line**, because the pre-gate run now
writes cv39 and the last cv37 forecast reaches 2026-09-15. Nothing was deleted:
the far-lead rows the cron wrote earlier remain, now visibly carrying a NULL
base version.

That is the honest state of the overlay, not a regression introduced here. The
artifact is cv37; production physics is cv39. Only one of three moves resolves
it, and all three are the owner's call — the same decision PR #388 is waiting
on:

1. **retire or restrict the hybrid overlay** (PR #388: the globally retrained
   hybrid is worse out of sample than the physics it corrects, 24.70 vs 23.30;
   the stats line generalises at 21.05);
2. **retrain and rebind** the artifact to the version production runs, accepting
   #388's measured out-of-sample result for it;
3. **set `MODEL_LINES_ALLOW_MIXED_BASE=1`** and keep publishing a cv37 residual
   on a cv39 base — deliberately, in writing, with the base version now recorded
   per row.

Until one is chosen, the emitter tells the truth about its coverage instead of
filling the gap with a mismatch.

## Addendum (2026-11-15, phase 2): the pin must not take the stats line down

As first written, a window with **no** row of the pinned version hit a
`SystemExit` before anything was emitted. That kills the `stats_gbm` line too,
although stats never reads the physics price (its features are settled lags,
fuels, calendar and book fundamentals). With production on cv43 and the artifact
on cv37 that is every day: both dashed lines would vanish from the site.

Now the two lines are gated independently (`lines_for_day`):

- `hybrid_gbm` needs a base row of the pinned version; without one it is skipped
  for that cell/day, with a loud warning (stderr, stdout, and a `::warning::`
  annotation under GitHub Actions) naming the window and the versions present;
- `stats_gbm` keeps its pre-pin domain (cells that carry *any* weather-track
  forecast, settled lag24 available) and is emitted regardless; its rows record
  `base_code_version = NULL` because it has no physics base.

The final line reports both counts (`EMITTED n rows … (hybrid_gbm a, stats_gbm b)`).
Test: `test/test_emit_model_lines_pin.py` (no database needed).
