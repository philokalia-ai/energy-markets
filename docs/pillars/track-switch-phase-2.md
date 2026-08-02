# The global track switch — Phase 2 (deferred)

Phase 1 (this PR, "the global track switch: predicted vs as-announced") shipped
the **cross-cutting lens**: a header-level segmented control (Predicted | As
announced), state in the URL (`&track=`) + localStorage, defaulting to Predicted,
with every *price-series* surface reacting — Recent days (horizon), Zone explorer,
Map, Scoreboard, and the prediction page's output panels (which state inline that
they ARE the Predicted pillar). Both tracks already live in the data plane:
`simulations.forecast_prices` / `forecast_scores` carry `input_mode`
(`weather*` = predicted, `entsoe*` = announced), the zones + scoreboard parquets
carry `input_mode`, `map.parquet` gained a `track` column, and `manifest.json`
declares `tracks:["predicted","announced"]` with per-track freshness. The
track-gap chip ("announced MAE 12.1 · predicted 14.3 → input cost +2.2") is
computed client-side wherever both tracks scored the same slice.

Phase 2 is the deeper, per-track work that Phase 1 deliberately left out. It is
NOT built here. Each item below states the gap, why it is deferred, and the shape
of the fix.

## 1. Per-track order-book capture

**Gap.** The order-book view (`v1/books/<date>.parquet`, one file per market day,
all 39 zones) is a SINGLE book per day — whichever daily run flushed last. The
predicted (morning, weather) run and the announced (evening, ENTSO-E D-1) run both
write the same key, so today's captured ladder is track-ambiguous. Phase 1 is
honest about this: on the As-announced track the book view shows an inline note —
the ladder is the Predicted-track book; only the clearing-price and settled-actual
markers (overlaid from the selected track's price series) follow the switch.

**Fix.** Dual-key the capture: `v1/books/{predicted,announced}/<date>.parquet`.
This needs the daily flow to change, not just the exporter:

- `run_pipelined_backfill` / the daily forecast run must capture the book under a
  track-scoped `books_dir` per input-mode pass (the morning weather pass →
  `predicted/`, the evening entsoe pass → `announced/`). The `BOOK_SINK` machinery
  and the pass-1∪pass-2 merge already exist (see CLAUDE.md "Order-book capture");
  the change is the destination key, threaded from the run's `input_mode`.
- `bin/web_data_push.sh` syncs the two subtrees.
- The Worker `book` route (`/api/v1/books/:zone/:date`) gains a track selector —
  either `?track=` or a path segment — and `routeKey`/`buildPayload` read the
  track-scoped R2 key, falling back to the flat legacy key (graceful degradation
  for pre-Phase-2 days).
- The SPA's `loadBook` keys the cache on `zone|date|track` and passes the track;
  the book view's inline note is removed once both tracks are captured.

**Why deferred.** It is a data-pipeline change (new capture keys, a backfill to
populate the announced subtree, a Worker route change) with its own byte-identity
guard — larger than the UI lens and independent of it.

## 2. Per-track inputs-page semantics

**Gap.** The Predictions page (`v1/inputs/<Z>.parquet`, `shapeInputsZone`) already
carries BOTH the fitted series (`pred_*`) and the reference/announced series
(`ref_*`), plus the settled actual (`act_*`). Phase 1 treats the whole page as the
Predicted pillar (it IS the fitted input model) and states inline that the switch
does not re-target it.

**Fix.** Give the inputs page a real As-announced semantics: on the announced
track, the driver/prediction panels plot the `ref_*` (TSO D-1) series as the
"input", and the model-card verdicts reframe as "this is the input the announced
track feeds the solver". The scorecard (`v1/inputs/scorecard.json`) is
predicted-only by nature (it scores OUR models); on the announced track it should
say so and instead surface the input-level gap (predicted input error vs the
announced input the market used) — the input-side analogue of the price-side
track-gap chip.

**Why deferred.** It is a semantic redesign of a whole pillar's panels (what "the
input" means per track), not a filter — and it depends on settling how the
input-level gap is defined and scored.

## 3. The record tie-in (Metabase / cv31 as the deep announced track)

**Gap.** The live forecast plane has ~1 month of both tracks (leads D+1..D+7).
The **record** — the 1,238+-day cv31 `multi_zone_eu` backfill in Postgres, the
canonical published counterfactual — is effectively the deep As-announced track
(it clears on the official/observed inputs, not the pre-gate weather forecast).
Phase 1's As-announced track is the *forecast-plane* announced run only; it does
not reach back across the multi-year record.

**Fix.** Wire the record in as the historical extension of the announced track:

- Surface the Metabase counterfactual dashboard (dashboard 14, one selectable
  "Run" per code_version) as the "deep announced track — full history" link from
  the switch, so a user who flips to As-announced and scrolls past the forecast
  window is handed the multi-year record rather than an empty state.
- Optionally export a downsampled record slice into the web data plane under the
  announced track so the Map/Scoreboard can extend backwards years, with an
  explicit provenance badge (record vs live-forecast) — the code_version ledger is
  already per-row, so the honesty note ("this segment is the cvNN record, cleared
  on observed inputs") is a display of existing data.

**Why deferred.** It crosses two data planes (the live R2 forecast plane and the
Postgres/Metabase record) and needs a provenance-labelling design so the two are
never silently averaged — a product decision, not a rendering one.

---

**Ordering.** (1) is the most-requested and self-contained; do it first behind its
own byte-identity guard. (2) and (3) are semantic/product designs that should each
get a short prereg before implementation.
