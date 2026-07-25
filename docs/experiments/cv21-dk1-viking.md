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

Measured reference (boundary-refine, 2026-07-24): July MAE 31.5→28.3 (corr
0.90→0.93, eve bias −58→−48); March MAE 27.6→25.2 (corr 0.55→0.80).

**Confirm results: _(filled in below after the run)_**

| window | metric | base | dk1 |
|---|---|---|---|
| July | DK1 MAE | _tbd_ | _tbd_ |
| July | DK1 corr | _tbd_ | _tbd_ |
| July | DK1 eve_bias | _tbd_ | _tbd_ |
| March | DK1 MAE | _tbd_ | _tbd_ |
| March | DK1 corr | _tbd_ | _tbd_ |

Leakage (FR/NL/NO2): _tbd_.

## Byte-identity guards (vs unmodified main / cv20)

All bit-identical (`test/scripts/cv21_guards.jl`, day 2026-04-03, extract):
- GR single-zone `:merit_order` book+prices — _tbd_.
- SEE 5-zone multi_zone (`enrich_network=false`) — _tbd_.
- 39-zone EU book with `EUPHEMIA_DISABLE_CV21=1` — _tbd_.
