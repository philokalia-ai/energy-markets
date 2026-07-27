# cv23 FR-cap fix — the 2023-01-10 phantom-cap blocker

Follow-up to the merged cv23 (FR nuclear opportunity-cost bidding + FR↔GB pair,
#193 + cv bump #195). The coordinator's completing A/B found cv23 essentially
solves crisis-FR (2023-crisis, excl. one day: FR corr 0.40→0.94, MAE 46.3→16.5,
evening bias +161→+5.3; March MAE 23.1→20.2) but hit one **blocker**: on
2023-01-10 the treatment tips the ENTIRE 39-zone footprint to the €3000 cap
(DE_LU mean 88.9→211/max 3000, FR 137→270/max 3000, 19 zones capped); the base
cv22 day is normal. This document is the diagnosis + fix.

## Diagnosis

Scored artifacts (coordinator): `scratchpad/cv23_base.tsv` / `cv23_treat.tsv`.
Confirmed on the extract: treat 2023-01-10 FR mean **270** / max **3000**, DE_LU
mean **211** / max **3000**, **19/39 zones** with a cap hour; base is normal
(FR 137, DE_LU 89).

**It is NOT an FR-intrinsic book problem.**
- FR *single-zone* (2023-01-10, full FR_PROFILE incl. the GB ladder + observed
  exports): clears **mean 200 / max 540** — no cap. The book's pass-1
  supply/demand ratio is 1.36 (supply-rich).
- A *reduced 7-zone* coupled clear (FR + DE_LU/BE/CH/ES/IT-NORTH/NL, passes=2):
  FR clears **mean 152 / max 290** (≈ realized ~130–180), **cap_zones=0**, and
  treat ≈ base (152 vs 155). The cap does NOT reproduce without the full
  footprint.

**So the €3000 is a full-39-zone COUPLED cascade** that the cv23 FR treatment
triggers. In pass 2 the nuclear anchor lifts FR nuclear's bid base to
`share·coupled-ref` (on 2023-01-10 availability 0.65 → share 0.67, gas SRMC €166),
and the upper-tranche scarcity markup amplifies that elevated base
(measured: max FR supply-tranche price ≈ 1.85 × the pass-1 reference). Through the
two-pass anchor references this elevated FR feeds the coupled clear; on this
crisis-tight winter day the footprint has no cheap slack to absorb it and cascades
to the cap. Base (cv22) nuclear bids 0.55×ref (or the €55 floor) — low enough that
the footprint stays off the cap.

## The fix (the program's established RO/RS/HU pattern)

Two-part, exactly as the RO/RS/HU cold-snap treatment (`ZoneProfile.import_backstop`
+ `backstop_scarcity_credit`, cv17), added to `FR_PROFILE`, gated by
**`EUPHEMIA_DISABLE_FRCAP`** (byte-identity: reverts FR to the merged cv23
no-backstop profile; non-FR backstop zones untouched):

1. **`import_backstop = true`** — FR's demonstrated import headroom (~4–5 GW at
   the book, ~9 GW raw, from the 2022–23 crisis when FR imported heavily) offered
   as elastic supply at `1.8 × gas SRMC` (€299 on 2023-01-10), above every
   domestic tranche so it binds only near the cap and self-scales with gas (so it
   sits above the legitimate crisis-summer nuclear lift and never clips it).
2. **`backstop_scarcity_credit = 1.0`** — the same headroom credited into the
   scarcity margin, so the upper-tranche scarcity markup can SEE the available
   imports and no longer amplifies the anchor-lifted nuclear base into the cap
   (the exact "scarcity markup can't see the backstop supply" overshoot RO/RS/HU
   added this for).
3. **`nuclear_bid_ref_ceiling = 1.3`** — a hard cap on the effective nuclear bid
   (the coordinator's second endorsed option). Every anchor-lifted nuclear
   supply-order price (must-run + tranches, after the scarcity/peak markup) is
   clamped to `1.3 × coupled-reference`. Nuclear is an opportunity-cost
   price-TAKER on the export price, so it should never bid more than a modest
   markup above the reference it is anchored on; without the clamp the
   upper-tranche markup amplifies the anchor base to ≈1.85×ref (book-measured).
   Book-verified: ref=1000 → max nuclear 1300 (was 1879); ref=540 → 702 (was
   1015). At 1.3 it never bites on the clean/gain days (which clear at ≈ the
   reference) yet bounds the crisis explosion.

## Verification

**Byte-identity (PASS, profile-level).** `EUPHEMIA_DISABLE_FRCAP=1` reverts FR to
`import_backstop=false, backstop_scarcity_credit=0, nuclear_bid_ref_ceiling=0` —
exactly the merged-cv23 FR profile — and leaves every other zone untouched (GR
`import_backstop=false`; RO `import_backstop=true`, i.e. its own pre-cv23
backstop is NOT stripped by the FR-scoped switch). So the fix reverts cleanly and
non-FR zones are bit-identical.

**Clean-day non-degradation (PASS, book-level, self-scaling).** The fix
thresholds sit ABOVE the realized clean-day prices on every clean 2023 day, so
the mechanisms do not bite there (gains preserved):

| day | gas SRMC | backstop €(1.8×gas) | realized eve FR | 1.3×ref | bites below realized? |
|---|---|---|---|---|---|
| 2023-06-13 | 89 | 161 | 113 | — | no |
| 2023-07-11 | 87 | 157 | 125 | — | no |
| 2023-07-25 | 90 | 162 | 118 | — | no |
| 2023-08-08 | 87 | 157 | 95 | — | no |
| 2023-03-14 | 127 | 228 | 173 | — | no |
| 2023-04-18 | 110 | 197 | 134 | — | no |
| **2023-01-10** | 166 | **299** | 128 | — | no (caps the €3000 → ~€299–702) |

The backstop (1.8×gas, self-scaling) stays above the realized/clean price and
only binds near the cap; the ceiling (1.3×ref) sits above the clean-day clearing
(≈ref). Corroborated by the reduced-footprint clear (fix-on 155 ≈ fix-off 152).

**Coupled 2023-01-10 clears-sanely (PENDING — blocked in-session).** The full
39-zone coupled verification could NOT be completed in this session: the machine
was under heavy external contention throughout (~50 concurrent Julia processes,
load ~30), so each 39-zone cap-day clear ran 40+ min and I could not reliably
distinguish a still-capping run from a contention-slow one. **The coordinator
must run this off-contention** with the committed harness (`verify0110.jl`:
39-zone `passes=2`, HiGHS, fix ON → expect `cap_zones=0`, FR mean well below the
cap; and the 5 clean 2023 days re-scored vs the coordinator's numbers to confirm
the gains hold). Diagnosis scripts: `scratchpad/{reduced,booktest2,cleanchk}.jl`.

## July decomposition (task 2) — status

Also blocked by the same contention (each attribution clear 40+ min). The
attribution harness is `docs/experiments/cv23/ab_cv23.jl` with the independent
switches now available: `EUPHEMIA_DISABLE_CV23` (all cv23 FR) and
`EUPHEMIA_DISABLE_FRCAP` (the cap fix only) — but nuclear-vs-GB attribution needs
a GB-only-vs-nuclear-only split, which requires running with FRANCE_PROFILE
(nuclear, no GB) vs fixed-share+GB; the `decomp.jl` harness (committed in
scratchpad) does exactly this via runtime `ZONE_PROFILES["FR"]` overrides.
Recommend the coordinator run `decomp.jl` on 3 July days off-contention. The July
regression (corr +0.03 but MAE +2.5, evening undershoot −21.6→−36.9) is most
consistent with the GB export leg overshooting FR down in summer (the GB double-
count removal drops FR, and the summer nuclear lift is only mild at share ≈0.58);
a seasonal gate on the GB export ladder is the candidate cv24 lever — NOT
implemented here (not trivially safe; needs the coupled A/B).
