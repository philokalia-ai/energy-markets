# Nordic reservoir-wetness — measured results (NO-SHIP, conflicted)

**Verdict: NO-SHIP (conflicted).** The pre-registered mechanism
(`docs/nordic-wetness-prereg.md`) was implemented exactly, guard- and
polarity-proven, and scored on the frozen Set A. The only composition that
meets the within-regime acceptance floor (`all` = T1+T2) **fires the envelope
correlation falsifier** on its own affected zones (NO4 corr −0.287, SE1 −0.155,
SE2 −0.154 — all beyond the −0.05 ceiling) and quadruples the wet-hour collapse
false-alarm; the composition that clears the envelope (`loo_T1` = T2-only)
**misses the bias-reduction floor** (2.51 < 5). No arm passes ALL gates →
conflicted → Set B was NOT run (`.claude/SCIENTIST.md` §2, "conflicted ≠
pass"). The branch stays unmerged; the code is default-inert (behind
`EUPHEMIA_ENABLE_NW` / `_T1` / `_T2`), so no code_version bump.

Baseline = **cv31 main** (`bcfbfde`, solar-floor default-ON). All arms cleared
the 39-zone two-pass EU footprint on the read-only DuckDB extract, HiGHS, fresh
process per cell.

## Implementation + pre-scoring guards (PASS)

Behind `EUPHEMIA_ENABLE_NW` / `_T1` / `_T2` (enable-polarity opt-in), exactly per
the prereg. The wet axis is the symmetric complement of the shipped dryness norm
(`get_reservoir_wetness = clamp(fill_ratio − 1, 0, wet_cap)` over the refactored
shared `_reservoir_fill_ratio`; mod-52 ISO-week wrap + ISO-year fix inherited).
- **T1** (non-anchored `wv_frac`, SE1/SE2/FI/NO4): `wv_frac −= β·wetness`, clamped
  to `[wv_floor_wet, 1.0]`.
- **T2** (`:hydro`-anchored pass-2 share, NO1/NO2/NO3/NO5/SE3/SE4):
  `anchor_share_eff = anchor_share − β·wetness`, clamped to `[anchor_floor_wet,
  anchor_share]`.
- Params (β=0.65 default, wv_floor_wet=0.15, anchor_floor_wet=0.6, wet_cap=0.5)
  read at call time. `import_price` keeps the raw `anchor_share` (the prereg T2
  formula names only the `water_value` expression).

**Bit-identity guard — PASS.** All-off vs a fresh **cv31-main** reference
(separate `origin/main` worktree) on the GR single-zone + SEE 5-zone + 39-zone EU
harness (2026-04-03): **1128 rows, byte-identical, max|Δ| = 0.**

**Polarity — PASS.** Single-zone books, `profile=get_zone_profile(z)` explicit:
- T1, SE1 wet 2025-01-15 (wetness 0.449): all 24 hydro water-value slots move
  **down**, €51.9 → €18.7 (β saturates the €wv_floor clamp at high wetness).
- T2, NO2 wet 2025-01-15 (wetness 0.134): €54.0 → €48.8 (β=0.65) → €44.4 (β=1.2),
  strictly **monotone** in β.
- Both zones, dry spring 2026-05-15 (wetness 0.0): **exact zero effect** (all β).

## Set A — scored, frozen gates

24 ratified days (2025-01, 2026-01, 2024-07, 2025-07, 2025-05, 2026-05 ×
1/8/15/22), arms base / all / loo_T1 / loo_T2, **96/96 cells, 0 failures, 0
truncated**. Wet-Nordic regime hours (10 reservoir zones, recomputed
`wetness_ratio ≥ 1.05`): **n = 3,048**; outside-regime (Nordic dry/normal + all
non-Nordic): **n = 19,416**. Base wet-Nordic **cap hours = 0**.

### Within-regime acceptance gate — dMAE ≤ −0.5 AND bias reduction ≥ 5

| arm | wet n | base MAE | treat MAE | dMAE | base bias | treat bias | bias reduction | GATE |
|---|--:|--:|--:|--:|--:|--:|--:|:--:|
| **all** (T1+T2) | 3048 | 32.76 | 31.11 | **−1.65** | +9.88 | +2.41 | **7.48** | **PASS** |
| loo_T1 (T2 only) | 3048 | 32.76 | 31.70 | −1.06 | +9.88 | +7.37 | 2.51 | FAIL (bias<5) |
| loo_T2 (T1 only) | 3048 | 32.76 | 32.17 | −0.60 | +9.88 | +4.92 | 4.96 | FAIL (bias<5) |

Bias reduction is ~additive across treatments (T1-only 4.96 + T2-only 2.51 ≈
all 7.48 — clean LOO attribution). **Only `all` clears the acceptance floor.**
Note the base wet-Nordic bias is **+9.88**, not the cartography's +23: that
figure was the cv27 full record; cv31's solar floor + prior fixes already
compressed the wet overprice, leaving thin headroom.

### Collateral guards

| arm | outside dMAE (|·|<0.1) | new caps (=0) | phantom P(sim≤5\|sett>20) base→treat (≤+2) | envelope corr breach (any zone ≤ −0.05) |
|---|--:|--:|--:|:--|
| **all** | −0.004 ✓ | 0 ✓ | 2.0 → 2.0 ✓ | **FIRED: NO4 −0.287, SE1 −0.155, SE2 −0.154** |
| loo_T1 | +0.009 ✓ | 0 ✓ | 2.0 → 2.0 ✓ | none (worst DK1 −0.027) ✓ |
| loo_T2 | −0.001 ✓ | 0 ✓ | 2.0 → 2.0 ✓ | **FIRED: NO4 −0.287, SE1 −0.155, SE2 −0.154** |

No MAE envelope breach (no zone +3.0) and zero new cap hours in any arm. The
outside-regime deltas are ≈0 by construction (verified). The **envelope
correlation falsifier fires for every T1-containing arm.**

### Per-affected-zone level (MAE) vs shape (corr) — arm `all` (flat zone-days excluded from corr)

| zone | branch | base MAE | treat MAE | dMAE | base corr | treat corr | **dCorr** |
|---|:--|--:|--:|--:|--:|--:|--:|
| NO4 | T1 | 24.83 | 19.64 | −5.19 | 0.263 | −0.024 | **−0.287** |
| SE1 | T1 | 21.99 | 22.63 | +0.63 | 0.572 | 0.418 | **−0.155** |
| SE2 | T1 | 21.87 | 23.09 | +1.23 | 0.579 | 0.425 | **−0.154** |
| NO3 | T2 | 43.89 | 42.39 | −1.51 | 0.522 | 0.481 | −0.041 |
| NO5 | T2 | 35.99 | 32.77 | −3.21 | 0.456 | 0.507 | +0.050 |
| NO2 | T2 | 22.40 | 21.55 | −0.85 | 0.671 | 0.680 | +0.008 |
| NO1 | T2 | 34.75 | 34.69 | −0.06 | 0.421 | 0.422 | +0.001 |
| SE3 | T2 | 33.30 | 33.31 | 0.00 | 0.634 | 0.635 | +0.001 |
| FI  | T1 | 27.52 | 27.52 | 0.00 | 0.680 | 0.680 | 0.000 |
| SE4 | T2 | 33.29 | 33.34 | +0.05 | 0.620 | 0.619 | −0.001 |

The aggregate within-regime gain is bought by NO4 (level −5.19 but shape
**destroyed**, corr 0.263 → −0.024) and the shape-safe T2 zones (NO5 −3.21,
NO3 −1.51). The **T1 zones SE1/SE2 get WORSE on both axes** (MAE +0.63/+1.23,
corr −0.15) and FI is inert.

### Collapse classification (wet Nordic hours; n(settled ≤ 5) = 581)

| arm | hit P(sim≤20\|sett≤5) base→treat | false-alarm P(sim≤20\|sett>20) base→treat |
|---|--:|--:|
| all | 39.1 → 77.5 | 3.6 → **16.3** |
| loo_T1 | 39.1 → 39.1 | 3.6 → 3.9 |
| loo_T2 | 39.1 → 77.5 | 3.6 → **16.0** |

T1 improves the hit-rate (39→78) but **quadruples the false-alarm** (3.6→16.3):
it manufactures phantom collapses in genuinely non-collapsed wet hours. (The
prereg's phantom guard uses the ≤5 threshold, which stays at 2.0 and passes; the
looser ≤20 false-alarm — the first-class collapse metric — is where the damage
shows.)

## Why it fails — the mechanism lesson

The theory is directionally correct: a symmetric wet discount **does** reduce the
wet-hour level overprice (+9.88 → +2.41), additively across the two branches.
The failure is **where** T1 acts. In the non-anchored reservoir-opportunity zones
(SE1/SE2/FI/NO4) the water value **is** the price-setter, and it is shaped across
the day by `water_value_base + span·norm_demand`. T1 discounts `wv_frac`, which
on the wettest days **saturates to the 0.15 floor** (proven in the polarity
probe: SE1 slammed to the floor). A floored, near-constant `wv_frac` **compresses
and inverts the within-day water-value shape**, so the clearing price flattens
against the settled diurnal curve — NO4 corr 0.263 → −0.024, SE1/SE2 −0.15 — and
the too-low floor manufactures phantom collapses (false-alarm 3.6 → 16.3%).

The **anchored** T2 zones re-price off the pass-1 coupled reference, which carries
the correct hourly shape; there the wet discount is **shape-safe** (every T2 zone
dCorr ≈ 0). But the T2 discount alone delivers only 2.51 of bias reduction —
below the ≥5 floor. So the two branches are in conflict: T2 is clean but
insufficient, T1 supplies the extra reduction but destroys shape.

## Constraint on the successor (a fired falsifier constrains, never tuned around)

1. A wet discount on a **non-anchored** water-value zone must **preserve the
   within-day shape** — discounting the level/floor cannot collapse the
   demand-shaping `span·norm_demand` term (which the floored `wv_frac` does).
   Candidate: discount the wv_frac *offset* while renormalizing the demand-shape
   band, or apply the discount to the *level* (`water_value_base`) only.
2. Or **scope the wet discount to the anchored (shape-safe) branch only** and
   find the missing bias reduction elsewhere (T2-only cleared every collateral
   gate — it is a viable half; it just needs a second, shape-safe lever to reach
   the floor).
3. Guard the **≤20 collapse false-alarm**, not only the ≤5 phantom — T1 passed
   the ≤5 phantom gate while quadrupling the ≤20 false-alarm.
4. Re-derive against a **cv31+** baseline where the wet overprice is already only
   ~+10 (not the cv27 +23) — the headroom for a shape-safe ≥5 reduction is much
   thinner than the cartography implied.

## Reproduce

Scripts in the session scratchpad `nordic_wetness/`: `nw_day.jl` (per-cell,
arms base/all/loo_T1/loo_T2 + `all_b<NNN>` β variants), `run_sweep.sh` (ratified
A/B windows, PAR-configurable, fresh process per cell), `build_settled.jl`
(settled Day-ahead prices), `build_wetness_ref.jl` (axis recomputed via the exact
`_reservoir_fill_ratio` code path), `score.jl` / `score_within.jl` /
`score_final.jl` (frozen gates). Guard: `nw_guard.jl`. Polarity: `polarity.jl`.
