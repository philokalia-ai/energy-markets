# Pillars 2–4 — the Prediction page family (Load · Solar · Wind)

**Status:** design, implementation-ready. **Scope:** the three input-prediction
surfaces of the SIX-PILLARS site program — Pillar 2 **Load**, Pillar 3 **Solar**,
Pillar 4 **Wind**. This plan decides what the existing `#view=predict`
("Predicting RES & loads") page becomes, defines the shared design language the
three siblings share, specifies each page against its own physics, and lists the
additive data-plane contract the pages need. It designs; it does not implement.

> **Provenance note (read this first).** The program's charter docs named in the
> task — `docs/six-pillars.md`, `six-pillars-fits.md`, `six-pillars-plan.md` —
> **do not exist on any branch** (`feat/six-pillars` is not on origin; the closest
> live work is `feat/predictions-full-footprint`, PR #267, which this branch is cut
> from). So this plan stands on the **shipped** materials, which are authoritative:
> `docs/predictions.md` (the open input-model recipe), `bin/ml_inputs.jl` +
> `bin/input_models/meta.json` (the fitted models + winner wiring), the live
> `#view=predict` page (`web/index.html` §`view-predict`, `web/app.js`
> `loadPredict`/`renderPredict`/`renderKnobs`), the `v1/inputs/` data plane
> (`bin/export_prediction_inputs.jl`, `workers/api/`), and the input-upgrade
> scorecards (`docs/experiments/input-upgrade/`). Where this plan asserts a Pillar
> boundary (P1 = prices, P5–6 = later) it is inferring the program shape from those
> materials; reconcile with the charter docs if/when they land, but nothing here
> depends on them.

---

## 0. The decision, in one line

**Keep one top-level `Predictions` tab; make it a hub with an in-page segmented
sub-nav → `Overview · Load · Solar · Wind`.** Not three new top-level tabs (the
nav already carries 8), not a flat single page. Hub owns the cross-cutting story
(the honest contract, the footprint coverage map, the family status table); each
of the three target surfaces is a deep page honoring its own physics. Deep-linked
as `#view=predict&target={overview|load|solar|wind}&zone=GR`.

Why hub+3 and not a split into 3 tabs:
- The **collapse question** and the **coverage map** are joint (solar+wind ÷ load)
  — they need a shared home (the hub) that no single target page owns.
- Load/Solar/Wind genuinely differ in physics, drivers, winner mix, and honesty
  story (below), so each earns a dedicated surface — a single scrolling page
  cannot tell three different stories without becoming a wall.
- Three extra top-level tabs would crowd the primary nav and bury the prices
  pillars; a segmented sub-nav keeps the family together and the top nav legible.

---

## 1. What exists today (the starting point)

`#view=predict` is a single page (`web/index.html` lines ~117–195):

1. **Footprint map** coloured by *tomorrow's predicted midday RES coverage*
   (`pred_res ÷ pred_load`), collapse-risk flagged; click a zone → knobs.
2. **Knobs panel** (`renderKnobs`, `web/app.js` ~1537): two output charts
   (Renewables pred/ref/actual, Load pred/ref/actual) + **all five** driver
   small-multiples (temp, GHI, cloud, pressure, wind100) regardless of target +
   a hydro **reservoir** panel (fill ratio, dryness).
3. **"How we predict — in plain language"** methodology card.
4. Per-target **provenance badges** (`ml` LightGBM | `pack` linear weather pack).

Data plane (`v1/inputs/`, `bin/export_prediction_inputs.jl`, served via
`workers/api` routes `/api/v1/inputs/{manifest,reservoir,<zone>}`):
- `manifest.json` — freshness, column dictionary, `zones`/`pilot_zones`/`pack_zones`,
  `hydro_zones`, and the per-zone freshest-day **midday coverage** `map[]`
  (`coverage`, `collapse_risk`, `midday_res_mw`, `midday_load_mw`, `model`).
- `<ZONE>.parquet` — per zone-hour drivers (`temp_c, ghi_wm2, cloud_pct,
  pressure_hpa, wind100_ms`), predictions (`pred_solar_mw, pred_wind_mw,
  pred_res_mw, pred_load_mw`), ENTSO-E reference (`ref_*_mw`), settled actual
  (`act_*_mw`), provenance (`src_solar/src_wind/src_load` ∈ {ml, pack}), and
  `vintage_lag`.
- `reservoir.parquet` — weekly `fill_ratio`, `dryness` for the 29 hydro zones.

The fitted contract (from `docs/predictions.md`, unchanged and honored by all
three pages): targets are the **ENTSO-E day-ahead published forecasts** (load
`day_ahead_total_load_forecast`; solar/wind `generation_forecasts_for_wind_and_solar`)
— *not outturn*; inputs are **GFS `previous_dayN` vintages** (D-1 = `previous_day1`,
never peeking across the 12:00 CET gate); provenance is **per (zone, target)**:
whichever of {NEW LightGBM, committed linear pack} won the frozen OOS scorecard
ships (footprint total **76 of 117 zone-targets NEW**: load 38/39, solar 22, wind
16 — `meta.json` `winners`).

**Physics that forces three different pages:**

| | Load | Solar | Wind |
|---|---|---|---|
| story | calendar · temperature · holidays · autoregression | capacity growth + **the collapse question** | power curves · onshore-pack-vs-ML honesty · offshore |
| drivers | `temp_c` (CDH/HDH about 21/16.5 °C, ² terms, 48 h mean), `ghi_wm2`, calendar (hod/dow/doy-Fourier, holidays), AR (`ar1`=D-1, `ar7`=D-7) | `ghi_wm2`, `cloud_pct`, `pressure_hpa`, sun-elevation `se`, `clearness`, `cap95_solar`, `v100m` | `wind100_ms`, `cloud_pct`, `pressure_hpa`, `cap95_wind` |
| capacity-normalized | no (absolute MW) | **yes** (ratio × `cap95_solar`) | **yes** (ratio × `cap95_wind`) |
| night clamp | no | **yes** (0 at sun-elevation 0) | no |
| winner mix (of 39) | **38 NEW** (near-universal) | 22 NEW, 7 skip (no solar: NO1–5, SE1, RS) | 16 NEW — **the physical pack still wins the low/onshore zones**, 7 skip |
| owns collapse | no | **YES** (this page) | no |

---

## 2. Shared design language (the frame the three siblings inherit)

One frame, four instances (hub + 3). Every target page is the **same skeleton**
in the same order; only the target-specific content differs. This is what makes
them read as one family.

### 2.1 Page skeleton (identical across Load/Solar/Wind)

```
┌ sub-nav  [ Overview · Load · Solar · Wind ]   zone: [GR ▾]  vintage: D-1 ────┐
│ A. Honest-contract strip   (target-specialized one-liner + 3 chips)         │
│ B. Per-zone MODEL CARD     (winner + why · VALID scores · collapse if solar) │
│ C. PER-LEAD SKILL strip    (MAE/corr vs lead D-1…D-7, the new scoreboard)    │
│ D. KNOBS — driver small-multiples (only this target's physics-relevant set)  │
│ E. OUTPUT chart            (predicted vs ENTSO-E reference vs settled actual) │
│ F. PHYSICS panel           (target-specific: §3/§4/§5)                        │
└ footer: reproduce link → docs/predictions.md + input-model bundle release ───┘
```

Zone selection is **shared state** across the sub-nav: pick GR on Solar, switch
to Wind, still GR. Backed by the same `predictState.zone` the current page uses,
promoted to `&zone=` in the URL.

### 2.2 Shared components (build once, parameterize by target)

| component | reuse / extend | notes |
|---|---|---|
| segmented sub-nav | new small control | writes `&target=`; mirrors the tab pattern in `index.html` |
| honest-contract strip | new, static per target | §2.3 |
| **model card** | new `renderModelCard(zone, target)` | fed by `scorecard.json` (§7); one card, target picks the row |
| **per-lead skill strip** | new `renderSkill(zone, target)` | fed by `skill.json` (§7); small MAE(lead) + corr(lead) charts |
| driver small-multiples | **reuse `driverMiniChart`** (`app.js` ~1611) | each page passes only its driver list (§3.2/§4.2/§5.2) |
| output chart (pred/ref/actual) | **reuse `driverMiniChart` `big:true`** + `sumSeries` | Solar/Wind plot their single target; hub plots RES = solar+wind |
| provenance badge | **reuse `srcBadge`** (`app.js` ~1532) | one badge (this target) not three |
| coverage map | **reuse the pmap renderer** (`renderPredict`, `app.js` ~1392) | lives on the hub; echoed read-only on Solar as the cliff |
| VALID-scores table | new, from `scorecard.json` | footprint-wide small table, sortable by winner/corr |
| chart palette | **reuse `chartColors()` / `C.sim/C.act`** | reference series keeps the `#B08A3E` dashed gold already in use |

Reusing `driverMiniChart`, `srcBadge`, `sumSeries`, `chartColors`, and the pmap
renderer verbatim is the mechanism that guarantees a single design language — the
three pages are compositions of the existing primitives, not new chart code.

### 2.3 The honest fitted-model contract strip (on every page)

A compact strip stating the two-layer epistemology, specialized per target. Three
chips + one sentence:

- **Target chip:** "predicting the TSO's published **D-1 {load|solar|wind}
  forecast** — the number the auction clears on, not the settled outturn."
- **Vintage chip:** "inputs are the **GFS `previous_day1`** run issued D-1 — never
  a later run across the 12:00 CET gate" (with the `vintage_lag` legend: 0 = run
  current at the horizon, 1 = the D-1 vintage for settled history).
- **Provenance chip:** the live winner for *this* zone+target — `LightGBM` or
  `linear pack` — via `srcBadge`, with a hover: "shipped because it won the frozen
  OOS scorecard for this (zone, target)."
- One sentence: "If our predicted input equals the TSO's forecast, the ex-ante
  weather price track converges to the reference track — so error is measured
  against what the market used." (verbatim spirit of `predictions.md` §1.)

This strip is the same on all three pages; only the three chip values change. It
replaces the long "How we predict" prose card with a persistent, per-zone-honest
header, and links out to the full recipe (`docs/predictions.md`) for the detail.

---

## 3. Pillar 2 — the **Load** page

**Story:** load is a calendar-and-temperature machine with memory. It is the
near-universal ML winner (38/39 zones), it is **not** capacity-normalized, and it
does not own collapse. Its honesty story is the **holiday map** (Orthodox vs
Western Easter, empty-map countries) and the **autoregressive lags**.

### 3.1 Physics panel (F)
- **Temperature response curve.** Scatter/binned line of predicted load vs
  `temp_c` showing the U-shape (heating below ~16.5 °C, cooling above ~21 °C) —
  built from the zone's own `<ZONE>.parquet` (`pred_load_mw` vs `temp_c`), the
  CDH/HDH bases annotated. This is the load page's signature visual.
- **Calendar & holidays.** A week-strip / day-of-week bars + a holiday flag ribbon;
  annotate whether this zone carries a holiday map (GR/BG/RO/RS Orthodox,
  ES/DE/SE Western) or an **empty map** (NL/FR/PL/… → `is_hol ≡ 0`, per
  `ml_inputs.jl`) — an explicit honesty callout that some zones' load model has no
  holiday feature.
- **Autoregression readout.** Show that `ar1` (D-1) and `ar7` (D-7) same-hour DA
  load forecasts are inputs known at the gate — a small "what the model already
  knows" note, not a chart.

### 3.2 Knobs (D): `temp_c` (headline), `ghi_wm2` (minor daylight term). Suppress
cloud/pressure/wind100 (not load features). Calendar/AR are structural, shown in F.

### 3.3 Model card (B): MAE_new vs MAE_base, corr_new vs corr_base, winner, n_valid,
window. **No collapse metrics** (load doesn't collapse prices). Highlight the
near-universal NEW win as the family's strongest result (rollout-39: 38/39).

---

## 4. Pillar 3 — the **Solar** page (owns the collapse narrative)

**Story:** two things at once — a **growing fleet** (why we predict a *ratio*
against `cap95_solar`, so capacity growth doesn't drift the forecast) and **the
collapse question** (midday is the whole game). This page is where the site tells
the collapse story end to end.

### 4.1 Physics panel (F) — the collapse cliff (the page's centerpiece)
- **Coverage-vs-load cliff.** For the selected zone, plot midday **RES coverage**
  (`pred_res ÷ pred_load`) across recent days with the collapse threshold band
  drawn in; mark days that crossed ≥1.0 (price-taker RES meets/exceeds load). This
  is the per-zone echo of the hub map, reframed as *the cliff*. Source: the same
  midday quantities the manifest `map[]` already computes, extended to the trailing
  window from `<ZONE>.parquet`.
- **Why midday, why a small error flips it.** A short annotated inset: near the
  threshold a small solar-forecast error flips collapse (≤ €5 / negative) vs not —
  the classification that dominates MAE there (`predictions.md` §9, SCIENTIST.md §4).
- **cap95 growth strip.** The trailing-30-day `cap95_solar` the ratio normalizes
  against, so viewers see the growing denominator behind a "flat" ratio.
- **Night clamp** annotation (prediction forced to 0 at sun-elevation 0).

### 4.2 Knobs (D): `ghi_wm2` (headline), `cloud_pct`, `clearness` (derived
`GHI/(S0·sinel)`), sun-elevation `se`, `pressure_hpa`. Suppress `temp_c`.

### 4.3 Model card (B): MAE/corr new-vs-base + winner **plus first-class collapse
metrics**: collapse **hit-rate** and **false-alarm-rate** (from `collapse_metrics.py`
methodology, ≤ €5 and < 0 thresholds), reported beside MAE — this is the only
target whose card carries collapse numbers. Zones with no meaningful solar
(NO1–5, SE1, RS) render an explicit "no solar regime — not modeled" state, not a
blank.

---

## 5. Pillar 4 — the **Wind** page (owns the physics-beats-ML honesty)

**Story:** wind is where the **physical power-curve pack sometimes beats the ML**
— NEW wins only 16 of the modeled zones; the committed physical pack still wins
the low-penetration / onshore zones. That honest split (not "ML everywhere") is
this page's signature. Offshore (NL, DK1, the offshore-heavy zones) is the ML's
strong ground.

### 5.1 Physics panel (F)
- **Power curve.** Predicted wind vs `wind100_ms` for the selected zone (binned),
  showing cut-in → ramp → rated → (implicit) cut-out shape — the physical object
  the pack encodes and the ML approximates. Built from `<ZONE>.parquet`.
- **Onshore-pack-vs-ML honesty callout.** State plainly which model won this zone
  and *why the pack can win*: on onshore/low-penetration fleets the monotone
  physical curve generalizes better than a boosted tree on a short record. This is
  a per-zone verdict driven by the winner flag, framed as a feature not a caveat.
- **Offshore note.** Where this zone is offshore-heavy (e.g. NL), mark it as the
  ML's favorable regime.
- **cap95 growth strip** (`cap95_wind`) — same rationale as solar (ratio model).

### 5.2 Knobs (D): `wind100_ms` (headline), `cloud_pct`, `pressure_hpa`. Suppress
`temp_c`, `ghi_wm2`.

### 5.3 Model card (B): MAE/corr new-vs-base + winner. **No collapse metrics.**
Emphasize the winner *mix* — this page's honesty is that the pack is live on many
zones by design.

---

## 6. The hub (`target=overview`)

The family landing and the home of everything joint:
- **Footprint coverage map** — reuse the current pmap verbatim (midday RES coverage,
  collapse-risk flag, `model: ml|pack` per zone). This is the single best
  cross-target visual and stays the hub centerpiece.
- **Honest-contract intro** (the §2.3 strip, un-specialized: all three targets).
- **Family status table** — the 76/117 winner breakdown (load 38, solar 22, wind
  16; skips), each row linking into the relevant target page for that zone. Fed by
  `manifest.json` zone lists + `scorecard.json`.
- **Vintage discipline** explainer + the reproduce/bundle links.
- **Hydro reservoir panel** relocates here (see §7) as a *price-side* knob, clearly
  labeled out-of-scope for the input models, pending the price pillars.
- Three large cards → Load / Solar / Wind, each with a one-line teaser + the
  headline family stat.

---

## 7. What moves, what's removed, what's added

**Moves:**
- The all-five-drivers dump splits into **per-target driver subsets** (§3.2/4.2/5.2).
- The **reservoir panel** leaves the RES/load knobs: it is a hydro **water-value /
  price** knob, not a load/solar/wind input. It relocates to the **hub** as a
  labeled "hydro state (price-side)" strip, or is deferred to the price pillars.
  Keep the existing `reservoir.parquet` + renderer; only its placement changes.

**Removed / folded:**
- The long "How we predict — in plain language" prose card is **replaced** by the
  persistent per-page honest-contract strip (§2.3) + the reproduce footer. No
  content is lost; it becomes per-zone-honest and always visible.

**Added (all additive; no existing `v1/inputs/` key renamed):**
- `v1/inputs/scorecard.json` — the per-(zone,target) **VALID scores** the model
  cards read. Shape:
  ```
  { schema:"v1", code_version, updated_at, valid_window:{first,last,n_days},
    scores:[ { zone, target, winner:"ml"|"pack",
               mae_new, mae_base, corr_new, corr_base, bias_new,
               n_valid,
               collapse:{ hit_rate, fa_rate, settled_pos } | null } ] }  // collapse only for target=solar
  ```
  Producer: extend `bin/export_prediction_inputs.jl` (or a sibling exporter) over
  the frozen OOS window, reusing `docs/experiments/input-upgrade/predict_inputs.py`
  + `collapse_metrics.py` scoring; the 5-pilot `scorecard.md` and the full
  rollout-39 scorecard are the reference values.
- `v1/inputs/skill.json` — the **per-lead** input skill the §2.2 skill strip reads
  (the new per-lead scoreboard, input-level). Shape:
  ```
  { schema:"v1", code_version, updated_at,
    skill:[ { zone, target, lead_days:1..7, mae, corr, bias, n_days } ] }
  ```
  Producer: score each `previous_dayN` vintage (N=1..7) against the ENTSO-E
  reference, reusing the archived `data/gfs_vintages/` (`bin/capture_gfs_vintages.jl`
  already stores `previous_day1..7`) and the same feature/scorer path. This is the
  **input** counterpart to the price scoreboard's `lead_days` dimension
  (`web/fixtures/scoreboard.json`) — same per-lead machinery, applied to the
  load/solar/wind predictions instead of prices. It tells the honest degradation
  story: how much skill we lose predicting D-2..D-7 ahead.
- Worker routes: add `/api/v1/inputs/scorecard` and `/api/v1/inputs/skill` next to
  the existing `{manifest,reservoir,<zone>}` matchers in `workers/api/src/index.js`
  (both are JSON pass-throughs like `manifest`, so no `shape.js` parquet work).
- Fixtures: `web/fixtures/inputs/{scorecard,skill}.json` mirroring the shapes above
  (pilot zones), so the pages render offline exactly as the current fixtures do.

---

## 8. Build sequence (implementation-ready phasing)

1. **Nav + routing shell.** Add the segmented sub-nav, `&target=`/`&zone=` URL
   params, and `predictState.target`; render the hub as today's page unchanged so
   nothing regresses. (Pure front-end; no data-plane change.)
2. **Shared components.** `renderModelCard`, `renderSkill`, the honest-contract
   strip, the per-target driver-subset wrapper around `driverMiniChart`. Wire the
   two new fixtures so all four surfaces render offline.
3. **Three target pages.** Compose Load, Solar, Wind from the shared components +
   their physics panels (§3.1/4.1/5.1). Solar's collapse cliff and Wind's power
   curve are the only genuinely new chart shapes; everything else is composition.
4. **Data plane.** Ship `scorecard.json` + `skill.json` producers in
   `bin/export_prediction_inputs.jl` (or sibling), the two worker routes, and CI
   wiring in `daily-forecast.yml` (non-fatal, like the existing inputs step).
5. **Relocate reservoir** to the hub; **replace** the prose card with the strip.
6. **Docs.** Extend `docs/predictions.md` with a short "the three prediction pages"
   section pointing at this plan; update `workers/api/README.md` route table.

Each phase is independently shippable and leaves the site working (the hub is
never worse than today).

---

## 9. Acceptance criteria

- **Design language:** the three target pages are byte-composed from the same
  primitives (`driverMiniChart`, `srcBadge`, `sumSeries`, `chartColors`, the pmap
  renderer) — a reviewer can diff two target renderers and see only the driver
  list, the physics panel, and the collapse toggle differ.
- **Honesty is per-zone, not global:** each page's model card and provenance chip
  reflect the *selected zone's* winner, including pack-wins and no-solar skips —
  never a blanket "ML" claim.
- **Collapse lives on Solar** (cliff + hit/FA metrics) and is *echoed* on the hub
  map; Load and Wind carry no collapse numbers.
- **Per-lead skill is visible and honest** — D-1…D-7 degradation shown per target,
  sourced from the archived vintages, no fabricated deep-lead rows (absent leads
  render as "pending", mirroring the vintage warm-up honesty in `predictions.md`).
- **Additive contract:** every existing `v1/inputs/` consumer (the current map,
  knobs, reservoir) keeps working unchanged; only new files/keys are added.
- **Offline parity:** fixtures render all four surfaces with no network, as the
  current predict page does.

---

## 10. Open questions (flag for the owner / charter reconciliation)

1. **Pillar numbering.** This plan assumes P2/P3/P4 = Load/Solar/Wind and P1 =
   prices (the existing board/horizon/map), P5–6 = later (order book / conduct /
   scenarios). Confirm against `six-pillars.md` when it lands.
2. **Collapse metric level.** `collapse_metrics.py` classifies at the **price**
   level (settled DA price ≤ €5). The solar model card wants an **input-level**
   proxy too (does predicted RES-coverage cross the threshold when reference
   coverage does?). Ship both, or price-level only? Recommend: input-level coverage
   crossing on the card (honest to *this* page's job), price-level in the case
   studies (a price pillar).
3. **Skill window depth.** Per-lead skill needs enough archived `previous_dayN`
   days to be non-noisy at D-5..D-7; the archive warms up. Gate the deep leads
   behind a min-`n_days` and render "warming up" until met.
4. **Reservoir home.** Hub strip now, or defer entirely to the price pillars?
   Recommend hub-now, clearly labeled price-side, to avoid losing a built panel.
5. **NO4 and the pure-pack zones.** NO4 is pack on all three targets (no ML winner
   anywhere); confirm it still gets full pages (yes — the pack IS the honest model
   there) with the provenance chip reading "linear pack" throughout.
