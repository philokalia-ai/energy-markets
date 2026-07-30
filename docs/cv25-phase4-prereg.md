# cv25 Phase 4 — per-treatment pre-registration

**Status: DRAFT, awaiting the owner's ratification. No scored Phase-4 arm runs
until this is merged.** Windows, gates, tie-break and envelope are inherited
unchanged from the ratified `docs/cv25-phase2-prereg.md`; calibration uses
**Set A only**, Set B stays held out for the accept decision.

The claim being served (#227): parameters may be calibrated when they are
nameable **market characteristics**, on ex-ante data, validated out-of-sample.
Every entry below names its characteristic; a treatment that cannot be named
that way is out of scope by rule.

The measured starting point (Phase-2 ablation, ratified windows): all-on
34.05/0.547 (A), 27.26/0.633 (B); gap to close 3.22 / 2.17 MAE. Damage
decomposition on winter Set A:

| pathology | zones | signature |
|---|---|---|
| episodic cap-spikes | BG, RO, GR | mean +45, p95 +113, max 2499; few hours |
| sustained level shift | IT-CNORTH, IT-NORTH | 60/192 h > +50; no caps |
| shape-only degradation | SI, HU, AT (CH mild) | mean Δ ≈ −14..0 but MAE worse |

## T1 — Extend the demonstrated-headroom import backstop to BG and GR

- **Zones:** BG, GR (currently plain `SEE_PROFILE`, no backstop).
- **Lever:** `import_backstop = true`, `backstop_scarcity_credit = 1.0` — the
  exact cv17 mechanism and formula, no new machinery.
- **Market characteristic:** each zone's *demonstrated import capability* —
  trailing-8-same-weekday observed import headroom beyond the flow climatology,
  minus offered endogenous ATC. Observed flows, strictly ex-ante. Under the old
  doubled ATC these zones were fed endogenously by phantom capacity, so the
  characteristic existed but the model never needed to represent it; canonical
  physics makes it load-bearing.
- **Expected direction:** the episodic cap-spikes die (BG 2, RO 2, GR 1 new cap
  hours → 0); winter mean Δ collapses toward baseline.
- **Falsifier:** any new cap hour in any zone; a neighbour (RS, RO, TR-border
  flows via RS, IT-SOUTH) breaching MAE +1.0 / corr −0.02; the Set-A verdict
  not surviving Set B.

## T2 — Recompute the existing backstop quantities under canonical ATC

- **Zones:** RO, SI, HU, AT, CH (and any other `import_backstop=true` zone —
  the recompute is mechanism-wide, zone list is exhaustive by construction).
- **Lever:** none — **zero knobs**. The backstop quantity formula subtracts
  "offered endogenous ATC" from demonstrated headroom; that term must reflect
  the canonicalised (single-variable) capacity the solver can actually carry,
  not the doubled pre-fix effective capacity. This is the plan's
  recompute-before-retune rule applied literally.
- **Market characteristic:** unchanged — the same demonstrated capability, now
  measured against the true physics.
- **Expected direction:** SI/HU/AT shape recovers (their mean Δ was already ≈0;
  the damage is intra-day misallocation from under-crediting imports).
- **Falsifier:** as T1's envelope; additionally, if the recompute alone moves a
  zone's MAE the WRONG way by > 1.0, the implementation is wrong (a pure
  recompute must not degrade the zone it serves) — stop and diagnose, do not
  tune around it.

## T3 — Northern-Italian import pricing (the one open-design item)

- **Zones:** IT-NORTH, IT-CNORTH.
- **Pathology:** sustained level shift (+42 mean, no caps) — not scarcity
  spikes; the halved import capacity re-prices the marginal unit all day.
- **Lever (design to be finalised in implementation, gated by this entry):**
  size the existing `import_backstop` on the demonstrated import capability of
  the CH/FR/AT→IT and SI→IT borders (IT-CNORTH already carries a cv17 backstop
  to recompute under T2; IT-NORTH gains one), priced at the standard
  1.8×gas-SRMC backstop price. **No new price forms** — if the standard
  backstop cannot close a level shift of this size, that is a finding to
  report, not a licence to invent a curve.
- **Market characteristic:** Italy's demonstrated northern import capability —
  the highest-volume, most persistent import corridor in the footprint.
- **Expected direction:** the +40 level shift shrinks substantially; corr
  (which *improved* under the fix) is preserved.
- **Falsifier:** CH/AT/SI/FR neighbour envelope; any IT-family zone degrading
  vs the all-on baseline; Set-B non-survival.

## What is deliberately NOT here

- No scarcity-form changes (the hyperbolic candidate stays a separate program).
- No anchor-share retuning, no SRMC multipliers, no new price ladders.
- The parameter-vector count (17) may grow by at most the T1/T3 backstop flags —
  the audit table in the writeup reports the count before/after.

## Protocol

1. Implement all three behind `EUPHEMIA_DISABLE_CV25_RECAL` (house isempty
   style). All-off must be bit-identical to the branch (guard).
2. Arms: `allon` (fixes only — the Phase-3 baseline), `recal` (fixes +
   T1+T2+T3), plus leave-one-out per treatment. Pipelined per-arm sweeps,
   gated on `pipeline_identity.jl` passing.
3. Score Set A; verdicts per the ratified gates (conflicted ≠ pass). Only if
   the package passes on A, score Set B **once**.
4. Report both; the ship/backfill decision is the owner's.

**Ratification: merging this file. Amendments before the run, in the open.**
