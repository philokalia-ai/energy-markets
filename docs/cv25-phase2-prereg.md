# cv25 Phase 2/3 — pre-registration

**Status: DRAFT, awaiting the owner's ratification. No scored measurement runs until
this file is merged.**

The plan's Phase-4 rule 3 says a treatment justified only by the residual it removes
is rejected, and that the enforceable part of that rule is a **commit timestamp
before the run**. This file is that timestamp. Defining the gates after seeing
results is the fitting the whole programme exists to avoid, so everything below is
fixed now and amended only in the open, by a further commit that says what changed
and why.

## What Phase 2 measures

Four structural fixes, each behind its own kill-switch, measured **leave-one-out**:

| # | fix | switch |
|---|---|---|
| 1 | ATC canonicalisation — one flow variable per unordered border | `EUPHEMIA_DISABLE_ATC_CANON` |
| 2 | `:d0` → scoped `:v3` resolution in `mz_build_books` | (policy resolver; see the note below) |
| 3 | ISO-year in the reservoir queries | `EUPHEMIA_DISABLE_ISOYEAR_FIX` |
| 4 | delivery-day exclusion in the fleet probe | `EUPHEMIA_DISABLE_FLEETPROBE_FIX` |

Arms: **baseline** (all switches ON, i.e. all fixes disabled — reproduces `main`),
**all-on**, and one leave-one-out arm per fix. Every arm from one binary.

**Fix 2 is measured differently, on purpose.** On the sequential path `main` already
resolves `:v3`, so fix 2 changes nothing there — it changes the **pipeline**. Its
verification is therefore *agreement*, not a price A/B: the same day cleared
sequentially and through the pipeline must produce identical prices, which is exactly
what `test/scripts/pipeline_identity.jl` claims today and cannot deliver (it compares
a `:v3` arm against a `:d0` one). Fix 2 passes when that harness compares like with
like and reports zero differences. Its *price* effect on the record is the
`:d0`→`:v3` delta already measured in the ex-ante audit, not a new number.

## Windows — fixed now, by calendar rule

Two winters and two summers, in different years, all after the `:v3` analogue pool is
warm (Phase 0.4: the pool is short before roughly 2023-11):

**Months:** 2025-01, 2026-01 (winter) · 2024-07, 2025-07 (summer)

- **Set A — calibration/screening:** days **1, 8, 15, 22** of each month → 16 days, 8 per season
- **Set B — held out:** days **4, 11, 18, 25** of each month → 16 days, 8 per season

Sets are disjoint by construction and identically composed across seasons. Set B is
not read until Set A has produced a verdict.

**Substitution rule (declared before use).** A scheduled day is unusable if any
footprint zone is short of 24 D-1 forecast hours at source. Then walk **+1 calendar
day** until a usable day that is in neither set is found. Applied once, checked
before ratification: **2025-07-18 is unusable (SI has 2 hours) → 2025-07-19**. All
other 31 days are clean. No day is swapped for any reason other than this rule.

**Failed builds.** A day that fails the enriched-network build in *any* arm is
dropped from *every* arm and the drop is reported with its reason. Silent truncation
is a defect, not a data-cleaning step.

## Scoring — the tie-break is fixed in advance

Scored against settled day-ahead prices (`entsoe.energy_prices`, `contract_type =
'Day-ahead'`), hourly, only on (zone, hour) cells that exist in **all** arms and have
a settled price.

**Primary metric: pooled MAE (€/MWh). Co-metric: pooled Pearson correlation.**
The ATC A/B showed these can move in opposite directions, so the rule is:

| MAE | correlation | verdict |
|---|---|---|
| improves | improves or within −0.005 | **pass** |
| improves > 0.2 | degrades > 0.005 | **conflicted — owner's call, not an automatic pass** |
| degrades ≤ 0.2 | improves > 0.005 | **conflicted — owner's call** |
| degrades | degrades | **fail** |

"Conflicted" exists so that a result cannot be accepted by quoting whichever metric
happens to flatter it. It goes to the writeup with both numbers and no verdict.

Reported but **not** gating, because the README uses them: per-year energy-weighted
share of load in zones with corr ≥ 0.75, and per-zone MAE/bias/corr tables.

## Neighbour envelope — actual numbers

For each arm, the **affected set** is declared *before* scoring, from physics only:
for fix 1, zones on borders whose modelled capacity changes; for fixes 3 and 4, zones
whose inputs the fix touches. Everything else is a **neighbour**.

- A neighbour may not degrade by more than **MAE +1.0 €/MWh** or **corr −0.02**.
- **No** zone, affected or not, may degrade by more than **MAE +3.0 €/MWh** or
  **corr −0.05**.

Either breach fails the arm. Breaches are reported per zone, never aggregated away.

These numbers are calibrated to this programme's own history: the NL BritNed no-ship
breached at FR winter corr −0.189, and the PL spread was refused at +0.047 against a
+0.05 bar — so 0.02/0.05 sit in the register where past decisions were actually made.

## Nordic cap-hour ceiling

cv18's failure mode was NO1 price-cap hours going 15 → 44. The measured baseline in
the 8-day ATC A/B was **zero cap hours in all 39 zones**.

- Ceiling: **no zone may gain a cap hour it did not have in the baseline.**
- If the baseline in these windows turns out to have cap hours, the ceiling is the
  baseline count per zone, with no increase permitted.

Cap hours are counted as simulated price ≥ €2,999.

## Truncated-day denominator

Handled identically in both arms and published:

1. Cells are scored only where **all arms** have a price and a settled price exists.
2. A day where any arm produced fewer than 24 hourly periods is **excluded from the
   aggregate and listed** in the result, with its period count.
3. The number of scored cells is reported with every figure, so a change in coverage
   can never look like a change in accuracy.

## Phase 3 — the honest baseline

After the ablation: all four fixes ON, **calibration byte-untouched**, scored on the
same Set A and Set B. That number — not cv24's published headline — is what any
Phase-4 re-calibration must beat. cv24's figure is not an ex-ante number, so asking a
re-calibration to beat it means asking it to recover a lost information advantage and
phantom transmission capacity through parameter choices.

The Phase-3 writeup publishes the **decomposition**: Δ from ex-ante honesty, Δ from
ATC physics, Δ from the two lookahead fixes — not a single cv24→cv25 delta.

## What is not covered here

Phase 4's re-calibration needs its **own** pre-registration, one entry per proposed
treatment, stating the zone, the lever, the physical or institutional hypothesis, the
expected direction and the falsifier — written without reference to the residual's
sign. That file does not exist yet and Phase 4 does not begin until it does.

---

**Ratification.** Merging this PR is the ratification. Amendments are welcome and
expected — but as commits to this file before the run, not as adjustments once a
number is on the table.
