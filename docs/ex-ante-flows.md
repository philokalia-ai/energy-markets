# Ex-ante flows — replacing the one forward-looking input (Phase 2)

The iteration-6 audit (`docs/ex-ante-audit.md`) established that same-day
observed `entsoe.physical_flows` are the **only** forward-looking input in the
book, and that naively lagging them (D-7 same-weekday) costs ~5 mean MAE with a
GR correlation collapse. This phase designs the real forward-product fix:
per-border-class diagnosis, then the best admissible replacement per class.

## The admissibility line (stated once, explicitly)

- The **price counterfactual stays no-fit**: realized prices never enter any
  book, and no model is fitted to price errors.
- **Forecasting an INPUT is legitimate** — exactly as the model already
  consumes ENTSO-E's load and RES *forecasts*. A flow forecast must be built
  only from data available strictly before the D-1 auction, be simple and
  interpretable, and be versioned with the model.
- **Scheduled commercial exchanges are NOT admissible.** They are the day-ahead
  auction's own output — using them would re-import the very leak this phase
  removes.

## Border classes

1. **Endogenous** — in-footprint borders with usable ATC: flows are decision
   variables of the coupled clear; nothing to replace.
2. **Dropped flow-based borders** (`flow_based_drop_borders`: NO*-internal,
   FI–SE1/SE3, HU–AT/SK, BE–FR/NL/DE_LU, SE2–SE3, SE3–SE4, SK–CZ/PL): observed
   flows enter as import-only supply + ref-priced exports.
3. **Retained injections** — out-of-footprint counterparties (GR–TR/AL,
   PL/SK/HU/RO–UA, BE/NL–GB, IT–ME/MT, FI–RU…) and in-footprint borders with
   no usable ATC: observed net flow as €1 price-taker supply / firm demand.

## Can the out-of-footprint borders be endogenized instead? (measured)

Data availability audit (live Postgres, 2026 rows):

| zone | DA load fcst | units | RES fcst | ATC (impl/expl) | verdict |
|---|---|---|---|---|---|
| TR | 0 | 0 | 0 | 0 / 37k | **no** — forecast its flows |
| UA | 0 | 0 | 0 | 0 / 0 | **no** — forecast |
| GB | 0 | 416 | 0 | 9k / 686k | **no** (demand side missing post-Brexit) |
| RU/BY/MA | 0 | 0 | 0 | ~0 | **no** — forecast |
| **AL** | 18k | 19 | 14k | 0 / 138k | **candidate** (explicit-ATC union — the RS treatment) |
| **MK** | 4k | 15 | 14k | 0 / 166k | **candidate** |
| **BA** | 4.6k | 16 | 9k | 0 / 111k | **candidate** |
| **ME** | 4.6k | 5 | 9k | 0 / 230k | **candidate** |
| XK / MD | 4.6k / 3.6k | 12 / 8 | 0 | 0 / 138k / 27k | partial (no RES fcst) |

**Conclusion:** the Western Balkans (AL/MK/BA/ME) can join the footprint via
the explicit-ATC union exactly like RS did — an iteration-9 footprint-expansion
project (tiny fleets need fleet-completion care). TR, UA and GB **cannot** be
endogenized from our tables; their flows must be forecast.

## The flow replacement mechanism (gated)

Three runtime switches (all env-configurable, default = byte-identical D-0):

- `FLOW_ASOF_MODE` — `:d0` (same-day, default) | `:dlag` (D-N) | `:clim`
  (per-(border, hour) **median of the trailing 8 same-weekday days**,
  D-7…D-56 — every input strictly predates the auction; no fitting, no
  parameters beyond the window length).
- `FLOW_ASOF_LAG` — N for `:dlag` (the iter6 audit variants).
- `FLOW_ASOF_CLASS` — `:all` | `:dropped` | `:retained`: which border class
  gets the replacement (the other class stays same-day), enabling per-class
  cost attribution.

## Per-class attribution of the D-7 cost (frozen 36-day sample, vs D-0 iter8)

<!-- ATTRIBUTION -->

## The v2 recommendation

<!-- V2 -->
