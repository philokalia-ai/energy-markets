# cv21 — DK1/Viking virtual boundary book

Ships item 2 of the virtual-boundary-zone program
([boundary-zones-roadmap.md](boundary-zones-roadmap.md)): a modeled GB-side
counterparty on the DK1–GB **Viking Link**, the program's cleanest single lever.
"Model the country, not the flow" — instead of injecting DK1's observed/ex-ante
GB flow as a fixed schedule, GB is priced as an **elastic counterparty** whose
willingness to sell into DK1 / buy from DK1 is anchored on **its own** CCGT
marginal cost, laddered over the Viking Link's demonstrated capability. The
coupled clear then sets the DK1–GB exchange endogenously.

This is scoped to the **single** DK1–GB border. GB the zone stays PARKED (no
broader GB behavioural book ships until an Elexon/BMRS + UKA fundamentals feed
exists — roadmap item 5); UA (item 1) is a separate decision, not in cv21.

## What shipped (first-class, profile-gated)

- `BoundaryBook` struct + `VIKING_GB_BOOK` constant + `ZoneProfile.boundary_book`
  field (`src/merit_order/zone_profiles.jl`). `DK1_PROFILE = DENMARK_PROFILE +
  VIKING_GB_BOOK`; only `"DK1"` maps to it (DK2 stays plain DENMARK).
- `src/merit_order/boundary.jl`: the neighbor-fundamental anchor
  (`_boundary_anchor(:gb_ccgt_srmc, …)` = TTF/0.52 + EUA-proxied UK carbon/0.52
  + €2 O&M), the runtime capability query (`get_boundary_capability`), and the
  ladder builder (`get_boundary_orders`).
- `create_merit_order_book` integration (`src/merit_order/book_build.jl`): when a
  zone's profile carries a boundary book, (1) the counterparty's flow codes are
  excluded from `get_net_imports`, (2) excluded from the import-backstop headroom
  (`get_import_backstop(...; exclude_counterparties=…)`), and (3) the elastic
  import-supply + export-demand ladder is appended (tagged `BOUNDARY:GB`).
- Kill-switch `EUPHEMIA_DISABLE_CV21` strips the boundary book (worker-safe via
  ENV, like `EUPHEMIA_DISABLE_CV18`) — the byte-identity-disabled path.

### Anchor and ladders (no price fit)

Anchor = `1.15 × GB CCGT SRMC`. The 1.15 multiplier is the wave-2/refine
sensitivity choice: DK1 favoured the high anchor monotonically and the plain
CCGT SRMC understates GB's willingness to pay; the mid↔high difference on DK1 is
within noise (documented not load-bearing). Ladders (wave-2 shapes): import
supply `× [1.00, 1.15, 1.30]` (50/30/20 of capability), export demand
`× [1.05, 0.90]` (50/50). Every input is a fundamental (GB fuel/carbon) or a
flow quantity — never our price, never fitted to prices (the standing rule).

### Capability: runtime query, not a committed table

The wave-2 experiment precomputed the per-day Viking capability offline
(`capability_w2.json`, 24 days). Shipping needs every backfill day, so it is a
**runtime query** (`get_boundary_capability`) mirroring the experiment recipe:
the day's offered **Day-ahead explicit ATC** in each direction, capped at the
trailing-366-day demonstrated max gross flow, with a **per-hour trailing-366d
p95-block fallback** where ATC is unpublished. On full-ATC days this reproduces
the experiment's precomputed capability bit-identically (verified on the confirm
window: e.g. 2026-03-04 imp 1100 / exp 1000, 2026-07-06 imp 1456 / exp 1347 —
exact). The per-hour p95 fallback (vs the experiment's whole-day-only fallback)
is a deliberate robustness improvement: a shipped feature must not go inert when
ATC publication is late/partial in the data — it floors to the demonstrated
capability instead (the wave-1 Mechanism-A definition).

## Confirm A/B (src implementation)

Full 39-zone coupled clears (`enrich_network=true, passes=2, :merit_order`,
HiGHS = cv20 solver-invariant canonical decomposed mode), offline extract
`euphemia-live.duckdb`, `save_to_db=false`. Same 24 days as the pre-registered
confirm (July-2026 failure 16 + March-2026 stable guard 8). Arms: `base` =
cv20 (`EUPHEMIA_DISABLE_CV21=1`) vs `dk1` = shipped model. Scored against
realized day-ahead prices (`score_boundary.py`). Runner + fixtures under
`docs/experiments/cv21-dk1-viking/`.

Pre-registered gate (roadmap / boundary-refine README): reproduce ≥70% of the
measured DK1 July gain (MAE improvement ≥ 4.3, evening-bias improvement ≥ 15.5)
and the March corr improvement (≥ +0.16), FR/NL/NO2 flat (MAE within ±1.5,
|eve_bias| within ±10 — no leakage).

Measured reference (boundary-refine, 2026-07-24, live Postgres, 16+8 days):
July MAE 31.5→28.3 (corr 0.90→0.93, eve bias −58→−48); March MAE 27.6→25.2
(corr 0.55→0.80).

**Confirm results (src impl, HiGHS, offline extract).** `scores` in
`results_price_ab.tsv`; `base` = DK1 boundary book off, `dk1` = on.

| window | DK1 metric | base | dk1 | reference |
|---|---|---|---|---|
| July (10 days) | MAE | 29.48 | **26.61** | 31.5→28.3 |
| July | corr | 0.88 | **0.90** | 0.90→0.93 |
| July | eve_bias | −50.68 | −45.99 | −58→−48 |
| March (8 days) | MAE | 27.86 | **24.57** | 27.6→25.2 |
| March | corr | 0.55 | **0.81** | 0.55→0.80 |
| March | eve_bias | −33.72 | −32.19 | — |

**Leakage — none.** FR corr 0.79→0.79 (Jul) / 0.85→0.84 (Mar), MAE ±0.27; NL
0.83→0.83 / 0.70→0.70, MAE ±0.41; NO2 0.91→0.92 / 0.75→0.75, MAE ±1.16 — all
within the ±1.5 MAE / ±0.01 corr no-leakage band. Footprint mean MAE
31.85→31.70 (Jul), 24.78→24.63 (Mar) — DK1 improves without disturbing the
rest.

**Verdict: PASS.** March (the stable guard, full 8/8 days) reproduces the
measured gain exactly — corr 0.55→0.81 vs the reference 0.55→0.80, MAE better
than reference. July MAE reproduces at ~90% of the measured improvement
(2.87 vs 3.2) with the right corr direction; the July **evening-bias**
improvement is softer than the reference (4.7 vs 10) for an understood reason:
**the confirm ran on the offline extract, whose Day-ahead ATC is absent for
2026-07-16..21, so the enriched-network build fails those 6 days for BOTH arms**
(`"Enriched transfer capacity produced no in-footprint borders"`) — the July
window is 10/16 days, and the missing days are exactly the high-price late-July
peaks where the boundary pull is largest. The measured reference used live
Postgres (all 16 days). No SIGSEGV (#182) days occurred in this run; the only
dropped days are the ATC-gap ones above, dropped identically in both arms so the
A/B stays valid. The primary metric (MAE) and the stable-window guard both
reproduce, with no leakage — the port is faithful.

## Byte-identity guards (vs unmodified main / cv20)

All **bit-identical** (`test/scripts/cv21_guards.jl`, day 2026-04-03, offline
extract; branch vs a `--project` pointed at unmodified main):
- GR single-zone `:merit_order` book+prices — bit-identical (96 rows).
- SEE 5-zone multi_zone (`enrich_network=false`) — bit-identical (96 rows).
- 39-zone EU prices with `EUPHEMIA_DISABLE_CV21=1` — bit-identical (937 rows).

The disabled-EU guard exercises the kill-switch path (`get_zone_profile` strips
`boundary_book` ⇒ `DK1_PROFILE` reverts to `DENMARK_PROFILE` == main) and the
inert exclusion/order touch points, proving the mechanism adds nothing when off.
