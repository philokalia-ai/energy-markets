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

The headline finding: **on the iteration-8 model the aggregate D-7 cost has
essentially vanished** — both class-selective D-7 runs score meanMAE 31.9 vs
31.9 (D-0), meanCorr 0.58–0.59 vs 0.59. The iteration-6 audit's +5.3 MAE /
GR-corr-collapse was measured on the *pre-installed-fleet* model, whose thin
books leaned heavily on the observed injections; the deep iter8 books absorb
injection noise. (The GR D-7 corr collapse is **gone** — the TR/AL hypothesis
is refuted on the current model; GR is not even a mover.)

The residual cost is *concentrated*, not aggregate (movers at |ΔMAE| ≥ 3 or
|Δcorr| ≥ 0.05):

**Retained-class D-7** (out-of-footprint / no-ATC injections lagged):

| zone | Δcorr | ΔMAE | reading |
|---|---:|---:|---|
| HU | **−0.35** | **+16.5** | HU's retained borders (HU–RO flow-based-coupled, HR, UA) are load-bearing |
| SK | **−0.43** | +2.8 | the UA export border |
| SI | **+0.33** | **−12.1** | its D-0 injection was *noise* — lagging helps |
| NO2 | +0.11 | −0.8 | same |

**Dropped-class D-7** (flow-based-drop borders lagged):

| zone | Δcorr | ΔMAE | reading |
|---|---:|---:|---|
| SK | **−0.57** | +7.4 | the CZ/PL import clamp is day-specific |
| FI | −0.13 | +1.2 | SE1/SE3 imports |
| HU | −0.07 | +8.1 | AT/SK imports |
| NO1 | +0.07 | **−20.5** | its D-0 observed flows were *hurting* it |
| DK1 | +0.06 | −2.6 | |

So the forward product's flow problem reduces to **two zones — HU and SK**
(both Core-FBMC, both leaning on same-day flows over their dropped/retained
borders), while two zones (SI, NO1) actually *prefer* an ex-ante flow.

## The v2 recommendation

<!-- V2 -->
