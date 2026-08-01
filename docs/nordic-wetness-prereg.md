# Nordic reservoir-wetness regime — pre-registration

**Status: gates frozen by this merge (process directive 2026-07-30, `.claude/SCIENTIST.md` §1).**
The prereg is merged BEFORE any scored run; the experimenter then runs
theory→experiment→results autonomously and the owner decides on the measured
numbers in a non-draft PR carrying code AND results. This document fixes the
regime axis, the mechanism family, the windows, the gates and the per-treatment
falsifiers. Nothing here is a scored result.

Inherited gates/tie-break/envelope from `docs/cv25-phase2-prereg.md`; baseline =
cv27 main (`fef60f6` at freeze). Set A calibrates, Set B is scored ONCE and only
on an A-pass (`.claude/SCIENTIST.md` §2). Regime-conditional judgment throughout
(`.claude/STRATEGY.md` §3): the mechanism is judged WITHIN the wet regime;
outside-regime deltas must be ≈0 by construction and are verified — all-hours
averages are a collateral guard, never the acceptance metric.

## Evidence base — the finding this program targets

Phase-1 error cartography of the cv27 record (2023-01-01…2026-07-27, 39 zones,
1.15M zone-hours; artifacts under the session scratchpad `solar_regime/`,
`phase1a.txt` / `phase1b_nuc_hydro.txt` / `STATUS.md`):

- **NORDIC carries 43.4% of the entire footprint's error mass** — the single
  largest zone-group (SEE 21.1%, CWE 16.4%, ITALY 12.7%). Group MAE 30.6, and
  unlike the continental-solar groups the residual is NOT concentrated in
  high-solar hours (solar-share is a weak axis for the Nordic — all bins 22–31
  MAE).
- **The dominant Nordic axis is reservoir WETNESS.** Stratifying Nordic
  low-RES hours by reservoir fill vs the same-week norm:

  | fill state | n | bias | MAE | error-mass % |
  |---|---:|---:|---:|---:|
  | dry (<0.9) | 52,509 | +3.9 | 30.4 | 22.9 |
  | normal (0.9–1.05) | 65,717 | +2.7 | 27.3 | 25.8 |
  | **wet (≥1.05)** | **98,371** | **+23.1** | **36.4** | **51.4** |

  The wet state carries **+23 €/MWh systematic OVERPRICE** and **51% of all
  Nordic error mass**. The model prices full-reservoir Nordic water too high.

**Root-cause theory (gate on the CAUSE, not the symptom — the cv30 lesson).**
The water-value floor in `src/merit_order/book_build.jl` is
`wv_frac = 0.35 + 0.65 · max(hydro_dryness, reservoir_drawdown)`. Both `dryness`
and `drawdown` live in `[0,1]` and only ever RAISE `wv_frac` above its 0.35
floor. **The wet direction — a fuller-than-normal reservoir lowering the shadow
value of stored water below the 0.35 floor — is structurally absent.** So under
a wet reservoir the model cannot price water any cheaper than the
full-reservoir floor, and it systematically overprices. That asymmetry is the
theory this program tests: make the water-value response symmetric about the
normal state.

## Regime axis — ex-ante per-zone wetness (ONE definition, ONE threshold)

**Definition (frozen).** For a reservoir-opportunity Nordic zone `z` and market
day `d`, reusing the EXACT normalization `get_reservoir_dryness` already computes
(`src/merit_order/fleet_data.jl`):

```
wetness_ratio(z, d) = stored_energy(latest week strictly before d's ISO week)
                      ────────────────────────────────────────────────────────
                      median over PRIOR YEARS of stored_energy at the same
                      ISO week ±2 (mod-52 wrapped)
```

`d` is in the **WET regime for z** iff `wetness_ratio(z, d) ≥ θ_wet`, with the
frozen threshold **θ_wet = 1.05** (the cartography's wet cut). The mechanism's
wetness magnitude is `wetness = clamp(wetness_ratio − 1, 0, wet_cap)`, i.e. the
symmetric complement of today's `dryness = clamp(1 − wetness_ratio, 0, 1)`.

**Why this definition and not the alternatives** (checked read-only against
`data/extracts/euphemia-live.duckdb`, `entsoe.aggregated_hydro_storage_filling_rate`):

- The weekly reservoir table has **full 2014→2026 coverage for all 10 Nordic
  zones** (~604 weeks each), so both a single-prior-year and a multi-year
  climatology definition are available. We pick the **multi-year climatology
  median** (not a single prior year) because a single prior year can itself be
  an anomalous wet/dry year, and because it reuses the existing
  `get_reservoir_dryness` norm verbatim — the wet mechanism is then a strict
  symmetric extension of shipped machinery, not a new query. One axis, one
  threshold, one nameable market characteristic (reservoir fullness vs its
  seasonal-climatological norm) — per the house parameter rule.
- **cv22-E ISO-week wrap** is inherited by construction: the ±2 neighbourhood is
  taken as an explicit mod-52 wrapped set, exactly as the shipped
  `get_reservoir_dryness` does (so weeks 1/2/52/53 keep their cross-year
  neighbours). The `EUPHEMIA_DISABLE_CV22` legacy path is NOT used.
- **cv22-D window bug**: the drawdown reader's trailing-52-week window fix
  (`year > $2 − 1`) is untouched; the wetness axis reads only the dryness-norm
  query, which was never subject to the drawdown window bug. No new window is
  introduced.
- **ISO-year (cv25 fix 3)**: the axis uses `_reservoir_iso_year(day)`
  (ISO-year, not calendar-year), inheriting the fix that prevents the
  2023-01-01 / 2025-12-29 lookahead. `EUPHEMIA_DISABLE_ISOYEAR_FIX` is NOT used.

**Ex-ante**: every input is a reservoir level from a week STRICTLY BEFORE the
delivery day, and a median over YEARS strictly before the ISO year — available
at the D-1 auction gate. No lookahead.

## Zone set and the two branches it splits into

The regime applies ONLY to reservoir-opportunity Nordic zones (`hydro_model =
:reservoir_opportunity`), which split across two price branches in
`book_build.jl`:

| branch | zones | today's water-value expression | wet lever |
|---|---|---|---|
| **non-anchored `wv_frac`** | SE1, SE2, FI, NO4 | `gas_srmc · wv_frac · (base + span·norm_demand)`, `wv_frac = 0.35 + 0.65·max(dry, drawdown)` | **T1** |
| **`:hydro`-anchored (pass 2)** | NO1, NO2, NO3, NO5, SE3, SE4 | `clamp(anchor_price · (anchor_share + dry_boost·dry), 2, gas_srmc)` | **T2** |

(NO2/NO5 anchored; NO1/NO3 anchored + import_backstop; NO4 non-anchored,
seasonal_drawdown off; SE1/SE2/FI non-anchored NORDIC.) Non-Nordic
reservoir-opportunity zones (CH, AT, DK1, DK2) are OUT of scope — the regime axis
is Nordic-only; their gate never fires.

## Mechanism family — `EUPHEMIA_ENABLE_NW[_Tk]`

Default-inert: with `EUPHEMIA_ENABLE_NW` unset the book is byte-identical to
cv27 main (bit-identity guard, below). Enable-polarity switches (opt-IN), so the
record and the live forecast are untouched until a measured A+B pass.

**T1 — `wv_frac` wet discount (non-anchored SE1/SE2/FI/NO4).** Extend the floor
symmetrically below 0.35 under the wet regime:

```
wv_frac = 0.35 + 0.65·max(dryness, drawdown) − β·wetness      (wetness>0 only when dry=drawdown=0)
        clamped to [wv_floor_wet, 1.0]
```

with a single declared slope `β` and a single declared lower clamp
`wv_floor_wet` (the export-opportunity floor the wet water can still fetch;
candidate 0.15). Because `wetness` is nonzero only when `dryness = drawdown = 0`
(a reservoir simultaneously above its climatological norm and at its seasonal
peak), the discount and the existing dry/drawdown boost never both fire — the
two directions are mutually exclusive by construction, which is what "symmetric
extension" means here.

**T2 — anchor-share wet discount (`:hydro`-anchored NO1/NO2/NO3/NO5/SE3/SE4).**
The analogous lever on the pass-2 anchor:

```
anchor_share_eff = anchor_share − β·wetness      clamped to [anchor_floor_wet, anchor_share]
water_value = clamp(anchor_price · (anchor_share_eff + dry_boost·dryness), 2, gas_srmc)
```

same `β`, one declared `anchor_floor_wet`. T2 exists because the anchored zones
re-bid against the pass-1 COUPLED price; if T1 alone (which lowers the pass-1
Nordic reference the anchored zones read) propagates enough through the two-pass
anchor edge, T2 is redundant and LOO will say so — that is exactly the
attribution T2/LOO answers, not a thing to pre-judge.

**Declared parameters (frozen count):** ONE axis (`wetness_ratio`), ONE gate
threshold (`θ_wet = 1.05`), ONE discount slope (`β`, calibrated on Set A like a
θ), and per-branch lower clamps (`wv_floor_wet`, `anchor_floor_wet`) — physical
floors, not tuned fits. T1-only vs T1+T2 is a mechanism-composition variant, not
a tuned parameter.

## Windows — ratified 6-month family + wet-coverage justification

The cv27/cv28 ratified family: **2025-01, 2026-01, 2024-07, 2025-07, 2025-05,
2026-05; A = 1/8/15/22, B = 4/11/18/25 (2025-07-18→19)**. 39-zone two-pass EU
clear per cell, HiGHS, fresh process per (arm, day).

**Do the melt/summer months give enough wet coverage?** Measured read-only on
the extract, applying the frozen axis (`θ_wet = 1.05`) to all 10 Nordic zones
across every window day:

| month | Set A wet zone-days (of 40) | Set B wet zone-days (of 40) | regime character |
|---|---:|---:|---|
| 2025-01 | 31 | 31 | wet winter — 7–8/10 zones |
| 2026-01 | 29 | 29 | wet winter — 6–8/10 zones |
| 2025-05 | 26 | 26 | wet late-spring — 5–7/10 |
| 2024-07 | 20 | 20 | mixed summer — 5/10 |
| 2025-07 | 15 | 15 | drier summer — 3–4/10 |
| 2026-05 | 6 | 5 | DRY spring — 1–3/10 |
| **total** | **127 / 240 (53%)** | **125 / 240 (52%)** | balanced |

The ratified windows are **already balanced across the wetness axis**: 53% of
Set A Nordic zone-days and 52% of Set B are WET, with 2026-05 supplying a
genuinely DRY spring (the critical outside-regime control — the wet mechanism
MUST be ≈inert there). **No window augmentation is needed or taken**; the
existing frozen family covers both regime states, so the axis is not used to
hand-pick days (which would have to be disclosed as such). This coverage table
is itself frozen by this merge — the wet/dry split is declared before any score.

## Gates

| gate | rule | scope |
|---|---|---|
| **within-regime improvement** | WET-hour (`ratio ≥ θ_wet`, Nordic reservoir zones) MAE improves AND wet-hour bias moves toward 0 (from +23) | acceptance metric |
| **outside-regime ≈0** | Nordic DRY/NORMAL hours (`ratio < θ_wet`) and ALL non-Nordic zones: `|ΔMAE| < 0.1` vs base | acceptance metric (by construction) |
| **neighbour envelope** | no neighbour MAE +1.0 / corr −0.02; NO zone (affected or not) MAE +3.0 / corr −0.05 | collateral, per-zone, never aggregated |
| **cap-hour ceiling** | ZERO new price-cap hours in any of the 39 zones (measured baseline 0; cv18 failure mode) | collateral |
| **phantom-collapse guard** | wet discount must not manufacture phantom lows: `P(sim ≤ 5 \| settled > 20)` in wet Nordic hours ≤ base + 2 pts | collateral |
| **collapse classification** | in wet Nordic hours (where settled ≤5 is 14–29%): hit-rate `P(sim ≤ 20 \| settled ≤ 5)` reported and not worse than base; false-alarm reported | first-class (`.claude/SCIENTIST.md` §5) |
| **flat-day shape rule** | shape stats exclude zone-days with settled daily stdev < 2 €/MWh; level metrics keep all days | reporting (frozen) |
| **LOO attribution** | `loo_T1` / `loo_T2` arms attribute each treatment's effect; conflicted ≠ pass | acceptance |
| **scored-cell counts** | reported beside every figure; excluded days listed | reporting |
| **Set B** | scored ONCE, only on an A-pass, for the accepted config | out-of-sample |

**Affected set (declared before scoring, physics only):** the reservoir-opportunity
Nordic zones whose water-value branch the gate touches — SE1/SE2/FI/NO4 (T1),
NO1/NO2/NO3/NO5/SE3/SE4 (T2). Every other zone is a neighbour; any nonzero delta
there arises only through cross-border coupling and must sit inside the
neighbour envelope.

## Falsifiers (per treatment, named before the run — a fired falsifier is a verdict)

- **T1 / T2 refuted** if wet-regime dMAE fails to improve (bias not moving down
  from +23) WHILE dry/normal-regime Nordic hours OR any non-Nordic zone degrade
  beyond the outside-regime `|ΔMAE| < 0.1` bound — i.e. the discount is buying
  wet-hour gains with off-regime damage rather than correcting the asymmetry.
- **Phantom collapse**: `P(sim ≤ 5 | settled > 20)` in wet Nordic hours exceeds
  base + 2 pts — the discount is over-firing into genuinely-scarce wet hours.
- **Envelope / caps**: any zone MAE +3.0 or corr −0.05; any new cap hour
  anywhere.
- **Set-B non-survival**: the accepted Set-A config does not reproduce its
  wet-regime gain out-of-sample within the envelope.

Any fired falsifier is documented as a measured NO-SHIP in `docs/experiments/`
with the mechanism lesson, the branch stays unmerged, and it constrains the
successor — never tuned around in the same run (`.claude/SCIENTIST.md` §6).

## Protocol

1. Implement T1/T2 behind `EUPHEMIA_ENABLE_NW` + `_T1` / `_T2` (enable-polarity,
   default-inert). **Bit-identity guard REQUIRED before any scored arm**: all-off
   == cv27 main on the 1032-row GR+EU harness (GR single-zone, SEE 5-zone,
   39-zone EU with the switch unset), max |Δ| = 0. Positive control: prove the
   switch, when set, actually changes the wet-hour `wv_frac` / `anchor_share` at
   book level (polarity proven before any sweep).
2. **Oracle bound first**: cap the maximum wet-regime MAE gain achievable if
   wet water were priced perfectly (settled-conditioned), to know the ceiling
   before building.
3. Arms Set A (paired, identical days, fresh process per cell): `base` (== cv27
   main, REUSED as the comparison), `all` (T1+T2), `loo_T1`, `loo_T2`, plus the
   `β` sweep for the accepted composition. 39-zone two-pass EU clear per cell,
   HiGHS, ≤12-way (machine shared with other agents).
4. Score regime-STRATIFIED: join arm prices ⨝ settled Day-ahead ⨝
   `wetness_ratio` (recomputed per zone-day), truncate to UTC hour; report
   within-regime / outside-regime / envelope / caps / collapse per the gates
   table, with scored-cell counts.
5. Pick the composition (T1-only vs T1+T2) and `β` with the best within-regime
   gain meeting ALL guards. Run **Set B once** for the accepted config.
6. Non-draft PR with code AND measured results; owner decides. cv bumped only on
   the activating branch, only if it ships. Branch stays unmerged on a NO-SHIP.

**Interaction note:** cv30 (export capability / surplus floor) and the
solar-regime floor (PR #251) touch price-taker RES/must-run blocks, not the
reservoir water-value branch; if any of them ship alongside this program, the
combined arm re-runs Set B before any backfill.
