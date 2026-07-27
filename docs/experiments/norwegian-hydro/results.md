# cv23 interior-Norway A/B — results

Coupled 39-zone A/B, HiGHS decomposed, offline live extract (read-only, shared),
`:v3` flows, scored on realized `entsoe.energy_prices`. 13 days: summer
(2025-09-15..18), winter (2026-02-09..12), dry-spring (2026-05-17..21). Base arm =
`EUPHEMIA_DISABLE_CV23=1`. Gate pre-registered in `GATE.md`. Scored table:
`tbl_ab_gateway_scored.tsv`; scorer `score_ab.py`.

> **Window caveat (read before the numbers).** The window deliberately
> over-weights the dry-spring regime (5 of 13 days ≈ 38%, vs ~8% of a calendar
> year) to stress the phantom-cap failure. Removing the cap therefore lifts the
> *windowed* pooled correlation far more than it lifts the *full-year* NO1 corr.
> Read MAE/bias improvements at face value; read corr movements as regime-biased.

## Attempt 1 — blunt `anchor_include_dropped` + backstop (NO1/NO3/NO5): REJECTED

Anchor reference = ALL dropped Nordic borders weighted by climatology import
flow (the SE3 mechanism). The import-flow weighting pulls the reference to the
cheap SE/FI level:

- NO1 winter bias **−43 → −87** (doubled underprice); summer corr **0.83 → 0.11**
  (shape destroyed).
- NO5 **degraded** (corr 0.72 → 0.64) — dropped from the treatment.

The failure localised the fix: the weighting must reference the *single* export
gateway, not a Nordic average. → Attempt 2.

## Attempt 2 — gateway anchor `anchor_gateway="NO2"` + backstop (NO1/NO3): FAILED GATE

Reference the opportunity anchor on NO2 alone. Full 13-day result (base → cv23):

| zone | corr | MAE | bias | | corr | MAE | bias | Δcorr | ΔMAE |
|---|---|---|---|---|---|---|---|---|---|
| **NO1** | 0.102 | 366.7 | +327.5 | → | 0.121 | **86.1** | **+5.8** | +0.02 | **−280.6** |
| NO3 | 0.136 | 422.6 | +392.9 | → | 0.192 | 61.4 | −1.2 | +0.06 | −361.2 |
| NO2 | 0.859 | 18.5 | +7.4 | → | 0.861 | 18.5 | +7.6 | +0.00 | 0.0 |
| DE_LU | 0.920 | 16.7 | −3.5 | → | 0.922 | 16.5 | −3.5 | +0.00 | −0.2 |
| NL / DK1 / DK2 | — | — | — | → | — | — | — | ≤0.008 | ≤0.5 |

**Gate: FAIL.** NO1 corr 0.121 < 0.30 (gate 1). Guards all clean (gate 3, 4 pass;
dry-May gate 2 passes, ΔMAE −758).

**Why it fails (regime split, base → cv23):**

| regime | NO1 base (corr/MAE/bias) | NO1 cv23 |
|---|---|---|
| summer | 0.83 / 23.1 / +22.5 | 0.25 / 21.7 / **+2.5** |
| winter | 0.70 / 55.1 / −55.1 | 0.61 / 102.0 / **−102.0** |
| dry-May | 0.16 / 944.8 / +933.6 | 0.23 / **139.8** / +114.1 |
| **non-May** | **0.746 / 39.0 / −16.1** | **0.533 / 61.6 / −49.5** |

Two decisive facts:
1. **The entire win is the backstop, not the anchor.** All of the MAE gain is the
   dry-May cap removal (945 → 140); the anchor adds no supply, so it cannot
   relieve a shortage-driven cap.
2. **The anchor makes non-May WORSE** (corr 0.746 → 0.533, MAE 39 → 62). Anchoring
   the hydro *offer* to NO2 is not the same as transplanting NO2's *clearing
   price* (the §2 counterfactual was optimistic — NO1's clear is set by its cheap
   imports and local balance, not its hydro offer). Worse, it drives winter from
   −55 to −102: NO2's clamped reference sits below NO1's genuinely-scarce
   continental winter level, and the anchored water value is capped at gas SRMC,
   so re-anchoring can only push winter *down*.

## Attempt 3 — backstop-only (NO1/NO3, no anchor change): the clean minimal win

`import_backstop` on NO1/NO3, anchor untouched. Scored as base(non-May) ∪
bkonly(dry-May); **inert-check passed** — bkonly == base **bit-identical**
(max|Δ| = 0.0000) on the non-tail guard day 2026-02-09, confirming the backstop
is byte-inert off the tail (priced above every tranche). Dry-May sub-window is
2026-05-17/18/19 (the 20/21 shard did not persist; the direction is
unambiguous). base → bkonly:

| zone | corr | MAE | bias | | corr | MAE | bias |
|---|---|---|---|---|---|---|---|
| **NO1** | 0.183 | 340.3 | +297.6 | → | 0.168 | **73.0** | **+30.3** |
| **NO3** | 0.160 | 313.5 | +278.2 | → | **0.477** | **46.2** | +10.9 |
| NO2, NO5, DE_LU, NL, DK1, DK2, SE1–SE4 | — | — | — | → | **byte-identical to base** |||

dry-spring (05-17/18/19): NO1 MAE 882.8 → **162.1** (bias +869 → +152);
NO3 MAE 1019.5 → **52.9**. The backstop de-caps the knife-edge (NO1 05-19
1576→179, NO3 05-18 2520→199) but does not fully cure the single most extreme
day (NO1 05-18 2045→535 vs actual 132) — the demonstrated import headroom is
itself finite, so an extreme draw keeps a residual overshoot.

**Gate (pre-registered, applied honestly):**

| # | criterion | result |
|---|---|---|
| 1 | NO1 corr ≥ 0.30 AND MAE −15 | **FAIL** (corr 0.168 < 0.30; MAE −267 ✓) |
| 2 | dry-spring NO1 MAE −30 | **PASS** (−721) |
| 3 | NO2 no degrade | **PASS** (byte-identical) |
| 4 | no continental leakage | **PASS** (byte-identical) |

The composite gate **fails on the corr criterion** (gate 1). That criterion was
the re-anchoring lever's target; the backstop does not — and structurally cannot
— fix the seasonal corr (see Verdict). On the phantom-cap objective it was scoped
for (gate 2) plus the guards (3, 4), backstop-only is a **clean pass**: NO1 MAE
340→73, bias +298→+30, NO3 corr 0.16→0.48, every other zone byte-identical.

## Verdict

The diagnosis is correct that NO1 physically tracks NO2, but **no available
lever re-anchors NO1 to NO2's clearing price**: the opportunity anchor sets the
hydro *offer*, and NO1's clear is import-dominated; and the anchored water value
is clamped ≤ gas SRMC, so the winter underprice (realized €135 > gas SRMC ≈ €95)
is a **structural ceiling** re-anchoring cannot lift. The one clean, precedented
win is the **import backstop** (extending the cv17 DK1/DK2/CH/AT/SI fix to the
interior NO zones): it removes the spring-drawdown phantom-cap knife-edge — a
large MAE/bias artifact — with zero non-May regression. It does **not** solve the
headline full-year corr≈0, which is the seasonal level inversion + the gas-SRMC
clamp, and needs new mechanisms/data (see §7 of DIAGNOSIS.md).
