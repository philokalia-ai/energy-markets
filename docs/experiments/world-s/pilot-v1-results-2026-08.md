# World S pilot, fleet-level v1 — results (2026-08-11): NEGATIVE, with the diagnosis that matters

Frozen design (#330): does transplanting the TRAILING observed supply-curve
shape onto our quantities beat the competitive book on official-price
closeness? Harness: per IT zone-hour crossing of the RECORD-path captured
books (39-zone coupled build, 7 GME days) with the official net position
injected; calibration 2025 days, test 2026 days. Three harness iterations
(hour-vs-slot lumping, fraction-vs-absolute mapping) are recorded in the
session log; the final (v4) run on verified books:

| set | MAE competitive | MAE strategy-transplant | bias C / S |
|---|---|---|---|
| calib 2025 (n=503) | 48.4 | 107.9 | +21.9 / −95.1 |
| test 2026 (n=504) | 90.4 | 173.7 | +65.5 / −87.8 |

**The transplant loses everywhere** (only NORD improves, 87→50 on test).

## Why — the finding worth the pilot

The mapping fails structurally, not by tuning: **the exchange book is not
the market**. GME's MGP clears ~14 GW of NORD supply against a 49 GW offered
curve, while our fundamentals book carries the TOTAL load (~22.5 GW) —
Italy's large bilateral/OTC volume never enters the exchange book. Absolute-MW
alignment therefore lands our margin at the wrong point of the observed
curve (S bias ≈ −90 both sets), and fraction alignment fails the opposite
way (v1: mapped too low, tested −39). No volume normalization is ex-ante
clean because the alignment target (cleared exchange volume) is itself the
day's outcome.

**Implication (recorded for the World-S design):** curve-shape transplants
at fleet level are the wrong abstraction. The viable route is the one the
Phase-0 stability finding supports directly — **per-unit strategy profiles**
(each matched unit gets its own trailing-observed shape: markup ratio,
zero/negative block, withheld share) applied to OUR book's units via the
strategist hook. That keeps our volume base (whole-market fundamentals) and
imports only the per-unit CONDUCT, which is what is actually stable (67% of
units single-shape). Cost: the GME `unit_ref` ↔ ENTSO-E unit mapping
(name/registry matching, the strategic-layer wave-1 asset helps).

Also recorded: the uncoupled per-zone crossing harness is itself noisy for
small coupled zones (CNOR competitive MAE 174–328 — its price is made by its
neighbors, not its own book), so unit-level evaluation should score bid-level
distance per unit plus coupled-clear closeness, not uncoupled crossings.

Artifacts: session scratchpad `pubbooks/` (pilot_v4.csv, iteration logs,
captured record books for the 7 GME days).
