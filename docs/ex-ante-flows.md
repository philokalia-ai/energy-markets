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

## Alternatives measured (frozen 36-day sample, vs D-0 iter8 = 31.9 / 0.59 / −8.8)

| variant | meanMAE | meanCorr | meanBias | movers |
|---|---:|---:|---:|---|
| D-7 all (iter6 audit, on the iter6 model) | +5.3 vs its base | −0.02 | — | 15 zones ≥6 MAE, GR corr −0.33 |
| D-7 retained-only | 31.9 | 0.59 | −8.3 | HU +16.5/−0.35c, SK −0.43c; SI −12.1/+0.33c |
| D-7 dropped-only | 31.9 | 0.58 | −8.2 | SK −0.57c, HU +8.1; NO1 −20.5 |
| **climatology all** | 33.9 | **0.62** | −5.3 | **NO1 +99.3** (regime mis-match); SI −16.6/+0.36c; HU/SK healed |
| **:v2 (D-7 Nordic, clim rest)** | **30.8** | **0.61** | −8.4 | NO1 −20.6, SI −16.6/+0.36c, NO2 +0.13c, DK1/SE3 +0.06c; FI −0.13c |
| **:v2 final (D-7 NO\*-only, clim rest)** | **30.7** | **0.61** | −8.5 | all movers positive: NO1 −20.6, SI −16.6/+0.36c, DK1 +0.08c, NO2 +0.12c, SE4 +0.07c; FI healed (Δ0.00) |

**The remarkable finding: the fully ex-ante :v2 BEATS the same-day product**
(30.8 vs 31.9 MAE, 0.61 vs 0.59 corr). The same-day observed flows were not
just a forward-looking leak — they carried *noise* that the climatology
averages away (SI +0.36 corr, NO2 +0.13) while the D-7 recency preserves the
Norwegian reservoir regimes that a median mis-states (NO1: clim +99 MAE,
D-7 −20.6). The one leak can be removed at *negative* cost.

## The v2 default — scoped (user decision, 2026-07-11)

> **Superseded as the default since cv19.** `:v2` was the EU-footprint default
> for cv16–cv18. From **cv19 onward the scoped default is `:v3` (anad2)** — the
> per-border mean of the D-1-load-analogue median and the D-2 observed flow
> (see `docs/experiments/analogue-flows/`). This section documents the `:v2`
> evidence that established the ex-ante-flow approach; `:v3` refined it. An
> explicit `EUPHEMIA_FLOW_ASOF_MODE` / `ex_ante_mode` still selects `:v2` (or
> `:d0`) on demand.

**`:v2` was the DEFAULT for the EU-footprint path** (cv16–cv18) —
`run_multi_zone_market_clearing` with `enrich_network=true` + `:merit_order`
(the forward product) resolves `ex_ante_mode` to `:v2` unless an explicit
`EUPHEMIA_FLOW_ASOF_MODE` env or `ex_ante_mode` kwarg says otherwise. The
**SEE legacy paths keep `:d0`**: single-zone `generate_energy_prices` and the
5-zone `multi_zone` product (`enrich_network=false`) are byte-identical to the
validated v10 output (SEE guard re-verified after the flip: GR/BG/RO = 131.34,
HU = 84.96). The flipped default applies to saved EU-footprint results from
**cv16 onward** — the cv15 full-year backfill was produced with `:d0`
(see CLAUDE.md version history).

**`FLOW_ASOF_MODE = :v2`** definition: flow climatology
for every observed border, except D-7 same-weekday recency for borders touching
a Norwegian reservoir zone (NO1–NO5). Fully ex-ante — every input strictly
predates the D-1 auction.

### Per-border strategy table

| border class | strategy | evidence |
|---|---|---|
| in-footprint with ATC | **endogenous** (unchanged) | — |
| dropped flow-based, non-NO (HU–AT/SK, BE–Core, SE-internal, SK–CZ/PL, FI–SE) | **climatology** | heals the D-7 damage (HU +16.5→0, SK −0.57c→0); FI prefers it |
| dropped flow-based, NO\* (Nordic internal) | **D-7 same-weekday** | reservoir regime persists week-to-week; clim blew NO1 +99 MAE |
| retained out-of-footprint (GR–TR/AL, PL/SK/HU/RO–UA, BE/NL–GB, IT–ME, …) | **climatology** | noise-averaging beats any single draw; GR unaffected on the iter8 model |
| retained in-footprint no-ATC (RS borders, HU–RO, …) | **climatology** | same |
| Western Balkans (AL/MK/BA/ME) | **endogenize in iteration 9** (explicit-ATC union, the RS treatment — load/RES/units/ATC all present) | availability table above |

### Validation

- Frozen 36-day sample: **:v2 BEATS the same-day product** — meanMAE 30.7 vs
  31.9, meanCorr 0.61 vs 0.59, zero acceptance-gate violations (GR −0.4 MAE /
  −0.01 corr; FI Δ0.00 corr).
- Held-out 12 days: meanMAE 35.3 vs 31.7, meanCorr 0.62 vs 0.65 — the gap is
  **concentrated in NO1** (0.51/23.3 → 0.03/103.9: its import regime flipped
  between weeks on winter held-out days, so D-7 recency mis-fired there too),
  plus small GR/FI slips; SI *improves* massively on both sets (+0.36c sample,
  0.23→0.65 held-out) and HU improves held-out (42.8→40.4).
- Net across both sets the ex-ante cost is **≈ +1 MAE** (was **+5.3** in the
  iteration-6 audit on the pre-installed-fleet model) — the deep iter8 books
  absorb injection noise, and climatology-averaging is *better* than the
  noisy same-day observation for most borders.
- SEE 5-zone byte-identity guard: exact (default `:d0` untouched).

### The honest open problem — NO1

Neither naive ex-ante source works for NO1's dropped-border imports in all
seasons: the 8-week median mis-states the regime (+99 MAE on the sample), D-7
recency mis-fires when the regime flips between weeks (+80 MAE on held-out
winter days). NO1 is the one border set that genuinely needs a *real* flow
input model — candidate features are both-sides reservoir levels/dryness and
DA load/RES forecasts (all D-1-legal), ridge or per-regime climatology,
trained strictly on pre-sample data and versioned. That is the defined
iteration-9 deliverable; until then `:v2` carries NO1's cost explicitly.

### What was measured and rejected

- **D-7 for everything** (the iter6 audit variant): cost concentrated at
  HU/SK (−0.35/−0.43 corr, +16.5 MAE) — one lagged draw is noisy.
- **Climatology for everything**: best aggregate corr (0.62) but NO1 +99 MAE.
- **D-7 for all Nordic-side borders incl. FI/SE/DK**: FI −0.13 corr — only
  the NO\* reservoir zones need recency.
- **Scheduled commercial exchanges**: inadmissible by construction (the
  auction's own output — the leak itself).
