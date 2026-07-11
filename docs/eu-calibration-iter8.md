# EU calibration — iteration 8 (MPCC robustness + continental installed fleet)

Unblocks the iteration-7 parked prize: `:installed` fleet truth for the
continental core (DE_LU/NL/PL/CZ), by fixing the MPCC false-infeasibility at the
root and adding a per-day fallback. Bumps `ENERGY_PRICES_CODE_VERSION` to **15**.

## 1. Root cause of the "deterministically infeasible" days

Reproducers: 2025-07-24 (iter7, DE_LU book under `:installed`) and six cv14
production-backfill days (2025-07-01, 07-08, 10-21, 12-12, 2026-02-06, 02-07).

The two Big-M complementarity families in `solve_mpcc_market_clearing` carry
per-order constants `q × price-span` — up to **~2.6e8** on multi-GW cap-priced
demand blocks (e.g. DE's ~75 GW firm demand at the €3,000 cap against the −€500
floor). At that magnitude, Gurobi's integrality tolerance (1e-5) leaks
~10³ €·MW through each such constraint, and on large books the leakage
accumulates into **false INFEASIBLE certificates** that survive the whole
numeric retry ladder (DualReductions=0, NumericFocus=3, seed) with a degenerate
134k-constraint IIS. The same class was measured once before (2026-04-02, fixed
by tightening the side-1 constant); side-2's constant — the full surplus bound
of a cap-priced order — cannot be tightened, only eliminated.

## 2. The fix (two layers)

**Layer 1 — exact indicator-form retry (root fix).** A final retry rung deletes
both Big-M families and re-poses them as **Gurobi native indicator
constraints**: `aux = 1 ⟹ dual_rhs ≤ 0` (side 1) and `aux2 = 0 ⟹ dual ≤ 0`
(side 2) — the *same logical model* with **no constants at all** (integer
solutions pin `dual = surplus` exactly as before via `dual_rhs ≥ 0`). Only
reached when every Big-M solve has failed, so the default solve path — and the
SEE byte-identity — is untouched.

**Measured proof:** the 2025-07-24 39-zone book with continental `:installed` —
deterministically "infeasible" through the whole old ladder — **solves OPTIMAL
in indicator form**. The certificates were false.

**Layer 2 — per-day `:p95` fallback (safety net).** If the MPCC is still
unusable after the full ladder and any zone runs a non-`:p95` fleet-truth mode,
`run_multi_zone_market_clearing` re-clears the *whole day* with baseline v10
books (guarded recursion via `MeritOrderBook.FLEET_TRUTH_OVERRIDE`, reset in a
`finally`; pass-2 anchored rebuilds inherit the override). A backfill never
ships a missing day. Loud by design.

Also: the MPCC's outer `catch` now logs the exception it previously swallowed
(a shadowed-variable bug during development masqueraded as `status=:error` —
that silence cost a diagnosis cycle).

**Verification: all 6 backfill reproducer days + 2025-07-24 now clear OPTIMAL**
(07-01 needed the indicator rung in both passes, 02-06 in one; the others
recovered in the earlier rungs; the fallback was never needed — it remains as
insurance).

## 3. Continental `:installed` enabled

`CONTINENTAL_PROFILE.fleet_truth_mode = :installed` (DE_LU, NL, PL, CZ), joining
the Baltics (iter7). Everything else unchanged.

## 4. Measured on the frozen 36-day sample (vs main = iter7 state)

**36/36 days cleared, 0 failed** (one day recovered via the indicator rung, the
fallback never fired). Aggregate: **mean MAE 38.8 → 31.9, mean corr
0.55 → 0.59, mean bias +4.4 → −8.8** — the iteration-7 predicted prize
(≈ 32 / 0.60) delivered.

| zone | main (corr/MAE/bias) | iter8 | note |
|---|---|---|---|
| **DE_LU** | 0.62 / 73.0 / +68.2 | **0.80 / 21.3 / −10.5** | the headline |
| **PL** | 0.50 / 74.0 / +62.8 | **0.65 / 29.3 / −16.0** | |
| **CH** | 0.39 / 52.0 / +32.6 | **0.68 / 23.6 / −8.4** | anchor-chain lift |
| **CZ** | 0.45 / 46.1 / +27.2 | **0.68 / 25.5 / −14.4** | |
| **FR** | 0.41 / 34.0 / +14.2 | **0.72 / 25.9 / +2.8** | |
| **IT-NORTH** | 0.36 / 39.8 / +20.2 | **0.64 / 22.4 / −1.5** | shape fixed too |
| **HU** | 0.57 / 36.3 / −7.8 | 0.74 / 33.2 / −14.0 | |
| **SK** | 0.43 / 39.3 / −20.0 | 0.68 / 39.0 / −33.9 | corr +0.25, bias worse |
| DK1 | 0.59 / 48.8 / +20.6 | 0.61 / 30.3 / −17.1 | |
| AT | 0.48 / 53.9 / +26.1 | 0.32 / 30.2 / −13.5 | corr −0.15, MAE −23.7 (see §5) |
| DK2 | 0.45 / 56.7 / +28.0 | 0.24 / 36.2 / −9.5 | corr −0.21, MAE −20.5 (see §5) |
| SI | 0.41 / 64.9 / +23.0 | 0.28 / 50.8 / +1.5 | corr −0.13, MAE −14.1 (see §5) |
| **GR (guard)** | 0.83 / 23.6 / −6.3 | **0.83 / 23.6 / −6.5** | held exactly |

Baltics/Nordics essentially unchanged (they got their fix in iter6/7); Iberia
and southern Italy flat.

## 5. The three corr regressions (AT / DK2 / SI) — what they are

All three pair a **large MAE improvement** (−24 / −21 / −14) with a correlation
drop. They are coupling-shape effects of the DE price correction, not level
errors: the sim day-shape flattened along with DE's (correlation is a weak
metric when the level collapses toward flat — atlas §7).

**AT re-tune attempted and rejected (measured):** `anchor_share` 1.1 → 1.25
moved AT only −0.4 MAE / +0.6 bias (everything else byte-flat) — the anchored
water value clamps at gas SRMC, so under the corrected (lower) DE ref the share
is no longer the binding lever. Reverted to the iter5 calibration; AT's
residual is *shape*, queued for iteration 9 together with DK2 (plain NORDIC,
no anchor — pure coupling effect) and SI (SEE profile, no local change at
all — pure neighbour coupling). All three carry improved MAE and bias.

## 6. Held-out validation (12 unseen days, the 26th of each month)

**12/12 cleared. Aggregate: mean MAE 31.7, mean bias −0.4, mean corr 0.65**
(iter7-era held-out was 39.2 / +14.5 / 0.57). DE_LU corr **0.89** / MAE 23.6;
PL 0.72 / 32.8 / −3.3; CZ 0.73; CH 0.73; GR 0.86 / 18.6 / −2.6. Notably **AT
scores corr 0.80 held-out** — its 0.32 on the frozen sample is driven by the
sample's stratified hard days, not a general regression. SI (0.23) and DK2
(0.41) remain genuine shape items for iteration 9.
(`docs/iter8-results/holdout_12d.csv`)

## 7. Validation summary

- Frozen 36-day sample: 36/36 days, meanMAE 31.9 / meanCorr 0.59 (§4).
- Held-out 12 days: 12/12, meanMAE 31.7 / meanCorr 0.65 (§6).
- All 6 cv14-backfill infeasible reproducers + 2025-07-24: clear OPTIMAL.
- SEE 5-zone byte-identity: GR/BG/RO = 131.34, HU = 84.96, RS dropped — exact.
- Gate suites green: zone_profiles (incl. the GR byte-identical book test),
  eu_footprint, mpcc, multi_zone_mpcc, network.
- `ENERGY_PRICES_CODE_VERSION = 15` (+ CLAUDE.md history); cv15 full-year
  re-backfill is the next production step after merge.

## 8. Ex-ante note

Unchanged from iter7: the registry is slowly-changing reference data; the
activity gate is the trailing-30d p95 (strictly historical). The indicator
retry and the fallback are solver-side mechanics — no new data enters any book.
