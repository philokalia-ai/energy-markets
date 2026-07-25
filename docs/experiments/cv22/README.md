# cv22 — UA firm-slice boundary book + the four confirmed price bugs

Assembly of model iteration cv22 (Euphemia EU counterfactual). Two
price-changing components plus runner hardening. GB pair and iter9/43-zones
were both measured NO-SHIP and are NOT included (deferred to cv23).

## Components

### 1. ua2 — the UA firm-slice boundary treatment (roadmap item 1)

Ported from `exp/boundary-refine` (`docs/experiments/boundary-refine/`) to src as
a first-class, profile-gated `BoundaryBook`, following the cv21 Viking pattern.
UA is a **war-constrained scarcity buyer** on the HU/SK/RO/PL–UA borders: import
supply anchored at `0.55 × zone gas SRMC` (no UA fundamentals feed — the
documented generic-anchor compromise), export demand = a **FIRM cap-priced base
slice** (its demonstrated persistent import need, which does not curtail on
price) plus an **elastic tail** at gas parity and above. The firm slice is what
killed the wave-2 HU March breach.

- `UA_BOOK_DEFAULT` (HU/SK/RO), `UA_BOOK_PL` (PL, adds the UA_DobTPP radial) on
  `src/merit_order/zone_profiles.jl`; the mechanism in
  `src/merit_order/boundary.jl` (`:p95_block` capability + `firm_slice`).
- **Runtime inputs, no committed JSON.** `get_boundary_firm` (trailing-28-day p10
  of the daily 4h-block-mean gross export flow) and `_boundary_capability_p95`
  (trailing-366d p95 gross flow per 4h block) reproduce the experiment's
  `firm_ua.json` / `capability_w2.json` **exactly** on the confirm days — verified
  firm@18UTC: March HU 139.3 (ref 116–156), SK 282.6 (283), PL 136.7 (137),
  RO 9.0 (9–16); July HU 8.5 (≤8.5), RO/PL 0, SK 74.1 (74–129). So the book
  generalizes to every backfill day (unlike a 24-day JSON fixture).
- **Reference confirm (2026-07-24, 24-day A/B, cv19-era books):** HU July MAE
  72.3→57.1 / corr 0.69→0.79; March MAE 28.24→28.29 (breach dead); SK July eve
  bias −82→−73, SI July MAE 80.7→70.1. Accepted residuals: HU March evening MAE
  29.2→33.0, RO/BG March ~+1.

### 2. The four confirmed price-affecting bugs (July perf review)

All four are gated behind `EUPHEMIA_DISABLE_CV22` (the byte-identity kill-switch)
and ON by default in the shipped model.

1. **`flows_imports.jl` `_v2_border_map`** — a Nordic-side border MISSING its D-7
   observation fell through both mix loops and was DELETED from the border map
   (silently zeroing its ex-ante flow). Fix: fall back to climatology, never
   delete. EU-footprint `:v2`/`:v3` only (SEE uses `:d0`).
2. **`Network.jl` legacy (non-enriched) ATC build** — took whichever duplicate
   capacity row sorted LAST by `date_time_utc` for a border-hour (order-dependent).
   Fix: hourly `AVG` per `(source, sink, hour)`, matching the enriched path's
   `_fetch_atc_aggregated`. **This deliberately ends the SEE 5-zone byte-identity
   chain (unbroken since cv10)** — see the SEE-delta measurement below.
3. **`fleet_data.jl` `get_reservoir_drawdown`** — the lower-bound disjunct
   `year > $2 - 2` widened the "preceding 52 weeks" window to 52–104 weeks and
   made the `(year = Y-1 AND week >= iso_week)` disjunct dead. Fix: `$2 - 1`
   restores the intended 52-week trailing window. Nordic
   `:reservoir_opportunity` zones only.
4. **`fleet_data.jl` `get_reservoir_dryness`** — the `week BETWEEN $3-2 AND $3+2`
   ±2-ISO-week neighbourhood did not wrap the year boundary (weeks 1-2 / 52-53
   lost neighbors). Fix: explicit mod-52 wrapped week set. **Only differs at ISO
   weeks 1/2/52/53 (Dec/Jan)** — invisible to the mid-year confirm/guard windows,
   and to the SEE guard days.

### 3. #182 runner hardening (no price impact)

Flaky HiGHS SIGSEGV (~3-4% of decomposed day-solves) kills the julia process,
bypassing the MPCC retry ladder. A try/catch cannot catch a same-process
segfault, so the fix lives at the layer that survives:
- **Pipelined backfill (the backfill vehicle):** the coordinator now supervises
  solver/book worker processes; a worker death (segfault) resubmits its orphaned
  day (retry-once) and spawns a replacement worker — no deadlock, WLS session
  count preserved. See `src/PipelinedBackfill.jl`.
- **Sequential runners (`bin/reproduce.jl`, `bin/daily_forecast.jl`):** documented
  limitation — a same-process segfault cannot be caught; the `resume` flag re-runs
  the lost day on the next invocation.

## Guards & gates

- **Byte-identity vs cv21 main** (GR single-zone, SEE 5-zone, 39-zone EU) with
  `EUPHEMIA_DISABLE_CV22=1`: bit-identical (all four fixes revert, UA books
  stripped, Viking untouched). See `_cv22scratch/` guard TSVs.
- **Combined confirm A/B** (base = cv21 vs cv22-all-ON), HiGHS decomposed,
  39-zone coupled, standard 24-day windows, scored on realized prices.
- **SEE-delta (bug 2)** measured on GR/BG/RO/RS/HU single-zone + 5-zone; gate:
  no material worsening (MAE +0.5 tolerance).

Files: `ab_cv22.jl` (runner), `launch_ab.sh` (sharded launcher), `days_ab.json`,
`windows_ab.json`, `score_boundary.py`, `see_delta.jl` (bug-2 SEE measurement).
Results filled in `../cv22.md`.
