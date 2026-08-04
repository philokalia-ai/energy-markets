# BG phantom caps on the pre-gate weather track — the ATC-ingest race (2026-08-04/05)

**Symptom.** BG weather-track lead-1 blew up two consecutive delivery days right
after the pre-gate 06:30 profile went live: 2026-08-04 MAE 283 / bias +207
(caps 19–20Z) and 2026-08-05 MAE 384 / bias +315 (caps 19–21Z, sim €3,000 vs
settled €285–307). Trailing-ten-day BG lead-1 MAE before that: 24–61. No other
zone capped either day.

## Diagnosis chain (all measured, in order)

1. **Not the book's own balance.** The captured BG book for 08-05 at 19Z holds
   5,857 MW of supply (max ladder price €452) against 4,102 MW of demand —
   single-zone BG clears ≈ €230–250. The €3,000 needs ≥ ~1,755 MW of coupled
   export pull with no re-import.
2. **Not Turkey.** The TR/MK fixed injection (`import_fixed`) was +181 MW
   import at 19Z while reality runs ~−300 MW (BG **exports** to TR/MK on
   summer evenings, trailing-21d avg −303/−333/−286 MW at 19/20/21Z) — the
   injection erred in the *generous* direction. TR is exonerated for this
   event (see the TR note below for what it does imply).
3. **Not the weather inputs' level.** ML load at 19Z was 4,102 MW vs ENTSO-E
   D-1 4,561 (we were 459 MW *lighter*); RES ≈ equal (54 vs 83 MW).
4. **Not the model at large.** The same day re-cleared offline against the
   refreshed extract (announced inputs, fully-published ATC) prices BG's
   evening at €232–339 with healthy flows: GR→BG imports 1.1–1.6 GW, BG→RO
   exports 1.3–1.8 GW — no cap, close to settled.
5. **The controlled pair that isolates it.** The same morning run wrote an
   entsoe lead-2 book for 08-05 at 08:25Z — **no cap** (€237–250) — while the
   weather lead-1 book built ~08:10–08:17Z capped. Eight minutes apart, same
   models otherwise.
6. **The race.** ENTSO-E published the RO↔BG Day-ahead ATC for 08-05 at
   07:05Z (`update_time_utc`); the ceres `update_entsoe_data` run that ingests
   it started 08:00Z and reaches the implicit-ATC step ~08:10–08:20Z. The
   weather book build (delayed to ~08:10Z by that morning's poison-slice
   failure, but the race exists on ANY pre-gate timing) found RO↔BG
   **wholly absent** and fell back to demonstrated flow capability; GR→BG had
   no rows at all until the 13:00Z intraday publication; RS↔BG never has
   implicit rows.

## The structural defect

The pre-gate absent-border fallback sizes capacity from **demonstrated
(observed-flow) capability**, which is *asymmetric for chronically-exporting
zones*: BG historically exports on every border, so its import directions
demonstrate ≈ 0 while its export directions demonstrate large. When RO's
evening tightness pulls the demonstrated BG→RO export, BG cannot re-import
from anywhere, its 4,020 MW inelastic demand exhausts the ladder, and the
coupled dual hits the cap — 3 hours × 2 days, exactly the evening block.

Worse, the as-of ATC coverage is **race-dependent**: whichever borders happen
to be ingested when the book builds determine the network. Two runs minutes
apart see different networks; the same profile on different mornings lands
differently (08-02's build was fine; 08-03/08-04's were not). Pre-gate inputs
are currently *non-deterministic in exactly the input that killed BG*.

## Recommended fixes (not shipped here — needs the standard gate)

1. **Trailing-DA fallback before flow-capability**: a border absent as-of the
   pre-gate build but carrying Day-ahead rows on recent days should fall back
   to those trailing DA values (RO→BG's prior-day DA avg was 2,343 MW), not to
   flow-demonstrated p95. Flow capability remains the fallback of last resort
   (borders that never publish DA — the cv27 population).
2. **Deterministic pre-gate as-of**: the pre-gate profile should apply ONE
   deterministic ATC rule for all DA borders (trailing-DA/capability), never
   the race-dependent partially-ingested table — making pre-gate books
   reproducible and testable.
3. Ops (shipped separately): #307 removed the poison-slice delay; the begun-day
   guard keeps morning timing tight but does not remove the race.

## The Turkey note (the owner's original question)

TR remains a fixed **ex-ante** injection (:v3 analogue + D-2 — no same-day
lookahead anywhere on the record since cv25; cv16–cv24 pipelined records were
:d0 and are ledgered as such). This event adds one measured fact: the :v3
injection got the evening **sign** wrong (+181 import vs −300 export reality)
— the analogue selection misses TR's own evening scarcity, which *pulls* BG
exports. An elastic TR boundary book (UA-pattern, anchored on a TR
fundamental once a feed exists) would produce exactly that export demand
endogenously. That remains the pillar-6 roadmap item; it was NOT the cause
here.

## Verification trail

- Book anatomy: `api/v1/books/BG/2026-08-05` (hours 12/19/20Z, strategy
  aggregation).
- Flows/ATC/forecast queries: `entsoe.physical_flows`,
  `entsoe.offered_transfer_capacities_implicit` (incl. `update_time_utc`),
  `entsoe.day_ahead_total_load_forecast`,
  `entsoe.generation_forecasts_for_wind_and_solar`,
  `simulations.forecast_prices` / `forecast_scores`.
- Offline repro: `run_multi_zone_market_clearing(Date(2026,8,5); …)` on the
  2026-08-04-refreshed living extract (announced inputs) — no cap.
- The natural experiment to watch: tonight's announced lead-1 freeze
  (~19:20Z) for 08-05 must not cap; tomorrow's pre-gate weather run (with
  #307's timing) will land on a different point of the race until fix (2)
  ships.
