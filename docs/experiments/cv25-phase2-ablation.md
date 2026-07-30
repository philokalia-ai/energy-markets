# cv25 Phase 2 — the pre-registered ablation

Run overnight 2026-07-30, exactly per `docs/cv25-phase2-prereg.md` (ratified as
#226 **before** any cell ran — the commit timestamp is the point). Branch
`feat/cv25-phase2-fixes`; every arm from one binary via kill-switches; each
(arm, day) cell its own process with the switches set at launch. The
all-switches-off guard passed first: **bit-identical to `main`, 1032/1032**.

## Set A (screening) — 5 arms × 16 days, 80/80 cells, none truncated, none failed

**14,976 scored cells** (hourly, zones×hours present in every arm with a settled
`Day-ahead` price — the count the prereg requires beside every figure).

| arm | MAE €/MWh | corr | ΔMAE | Δcorr |
|---|---|---|---|---|
| baseline (all fixes off) | 30.60 | 0.741 | — | — |
| **all-on** | 33.94 | 0.550 | **+3.34** | **−0.192** |
| leave-out fix 1 (ATC) | 30.60 | 0.741 | ±0.00 | ±0.000 |
| leave-out fix 3 (ISO-year) | 33.94 | 0.550 | +3.34 | −0.192 |
| leave-out fix 4 (fleet probe) | 33.94 | 0.550 | +3.34 | −0.192 |

The arithmetic of the leave-outs says everything: **the entire all-on effect is
fix 1.** Removing fix 3 or fix 4 from the bundle changes nothing; removing fix 1
recovers the baseline exactly.

### Per-fix verdicts (prereg gates)

**Fix 1 — ATC canonicalisation: FAIL standalone.** ΔMAE +3.34, Δcorr −0.192.
**19 hard envelope breaches** (worst: IT-CNORTH +18.8, IT-NORTH +17.2, BG
corr −0.33, RO corr −0.33, GR corr −0.28) and **5 new cap hours** (BG 2, RO 2,
GR 1) — the cap ceiling is breached too. This is the screening result confirmed
at scale and with the ratified gates: the physics fix is correct (net transfers
now respect the offered ATC) and the calibration was built around the phantom
capacity, so the SEE/Italian/Alpine importers collapse into phantom scarcity
without it. **Ships only with the Phase-4 re-calibration**, exactly as the plan
prescribed. Notable counter-movement: **SK improves dramatically**
(MAE 63.9 → 51.4, corr 0.578 → 0.712) — a zone whose treatment was fighting the
inflated imports.

**Fix 3 — ISO-year: NO EFFECT ON WINDOW (provable, not "conflicted").** None of
the 32 Set-A/B days has ISO year ≠ calendar year — the calendar rule's
1/8/15/22 + 4/11/18/25 days never straddle the ISO week boundary. The defect
only fires on 2–3 days per year (e.g. 2023-01-01, 2025-12-29..31), which no
blind monthly rule can sample. The fix's correctness rests on the unit-level
demonstration in the review record; its record-level effect will appear on
exactly those days of the full backfill.

**Fix 4 — delivery-day fleet probe: NO EFFECT ON WINDOW, with positive
control.** Zero price effect on all 16 days. Because a zero can mean "inert" or
"broken switch", both were checked: the switch demonstrably changes the SQL
(`$2::timestamp` vs `+ INTERVAL '1 day'`), and the resolved fleets are
**identical with and without the fix** on 3 probe days × 39 zones (117 rows
each side, zero diffs). The ~37% incidence measured in Phase 0.5 was an upper
bound before the registry-validity intersection; on these windows the
intersection is empty. Inert here; still correct; its effect belongs to the
days where a stale-validity unit generates.

**Fix 2 — `:d0` → scoped `:v3` in the pipeline entries:** verified by
**agreement**, not a price arm (the sequential path already resolved `:v3` — the
defect was pipeline-only). See below.

### Cap hours (sim ≥ €2,999)

| arm | total | new vs baseline |
|---|---|---|
| baseline | 0 | — |
| all-on | 5 | BG 2, RO 2, GR 1 |
| leave-out fix 1 | 0 | none |

All five are fix-1 artifacts — phantom scarcity in the SEE cold-snap cluster
once import capacity halves.

## Set B (held out) — baseline & all-on, 32/32 cells, none truncated

One substitution by the declared rule: 2025-07-18 unusable (SI has 2 forecast
hours at source) → **2025-07-20**. **14,976 scored cells.**

| arm | MAE | corr |
|---|---|---|
| baseline | 25.06 | 0.667 |
| all-on | 27.17 | 0.635 |

Held-out delta ΔMAE **+2.11** / Δcorr **−0.032** — same direction as Set A,
milder magnitude, **zero cap hours in either arm**, and the same zones carry the
damage (SI +11.8, HU +7.9, AT +6.6, CH +5.6, RS +6.4, the Italian islands). The
Set-A finding is not a sample artifact.

## Phase 3 — the honest baseline

With the claim restated (#227: ex-ante + transparent methodology; no-fit
retired), the number any Phase-4 re-calibration must beat is the **all-on**
model with the calibration untouched:

| set | honest baseline (all-on) | old-physics baseline | the gap re-calibration must close |
|---|---|---|---|
| A (screening) | 33.94 / 0.550 | 30.60 / 0.741 | 3.34 MAE / 0.191 corr |
| B (held out) | 27.17 / 0.635 | 25.06 / 0.667 | 2.11 MAE / 0.032 corr |

Decomposition on these windows: the ATC physics accounts for **all** of the gap
(fixes 3/4 inert here; fix 2 does not touch the sequential path). Against
cv24's published headline the comparison is deliberately NOT made — that number
carried same-day flows and the doubled ATC, and beating it is not the goal;
beating the honest baseline out-of-sample is.

**Where the damage lives** (both sets agree): the import-dependent zones whose
mechanisms were sized against phantom capacity — the cv17 backstops
(SI/HU/RS/RO/BG/AT/CH) and the Italian family. That is precisely the Phase-4
re-calibration surface, and the prereg's per-treatment pre-registration
requirement stands: recompute the backstop formulas against the true ATC first,
delete before adding, justify every change as a market characteristic.

## Fix-2 agreement

The minimal decisive check: books built through the **pipeline's entries**
(`mz_build_books` → `mz_solve_pass` → `mz_extract_anchor_inputs` →
`mz_rebuild_anchored` → `mz_solve_pass`), no `EUPHEMIA_FLOW_ASOF_MODE` in the
env, against `run_multi_zone_market_clearing` on the same day:

```
>>> FIX2-AGREEMENT n=936 differing=0 max|Δ|=0.0
```

**Zero differences on all 936 zone-hours** (2026-04-03, 39 zones × 24 h): the
pipeline's book path now prices bit-identically to the sequential wrapper with no
environment override. The defect that made every pipelined record `:d0` is closed.

The full-orchestration identity harness (`pipeline_identity.jl`, now asserting
its own precondition) remains the CI-level check; the first attempts through
`run_pipelined_backfill` in this session hit DuckDB lock conflicts with the
concurrently running ablation cells and were superseded by the minimal form.

## Process notes

- The all-switches-off guard ran **before** any cell: bit-identical to `main`.
- No day was truncated or failed in either sweep; nothing was excluded.
- One live pitfall re-confirmed: `pkill -f` with a pattern present in the
  caller's own command line kills the caller (the documented PKILL rule — it
  cost one polling shell).
