# Continental package round 2 — full-year results (2026-08-10): NO-SHIP

Prereg: [prereg2-draft-2026-08.md](prereg2-draft-2026-08.md) (frozen at merge,
#326). Seven FY arms (2025-08-01..2026-07-28, 328 common days), ISO-week-parity
A/B split at scoring, paired-by-day bootstrap significance (pre-declared
before any score was seen).

## Primary results (six floor zones, within regime; ΔMAE vs base, day-paired)

| arm | ΔMAE A [95% CI] | ΔMAE B [95% CI] | deep capture A/B | FR hit A/B |
|---|---|---|---|---|
| base (abs) | 28.48 | 28.24 | 57.1 / 78.6% | 20.7 / 23.9% |
| T1 θ_FR | **−0.07** [−.15,−.02] | +0.03 [−.04,+.16] | = | 21.3 / 25.0 |
| T2 tier −80 | +0.02 [−.42,+.42] | +0.09 [−.48,+.63] | = | 22.9 / 26.1 |
| T3 incr-pump | **+0.89** [+.56,+1.25] | **+0.69** [+.37,+1.02] | 51.8 / 75.0 | = |
| T4 wall | −0.07 [−.18,+.02] | +0.04 [−.02,+.10] | 60.7 / 78.6 | = |
| T5 CH yield | **−0.02** [−.04,−.00] | **−0.02** [−.05,−.00] | = | = |
| combo | +0.63 [−.03,+1.23] | +0.59 [−.14,+1.28] | = | 22.3 / 26.6 |

Zero envelope breaches, zero new caps everywhere; phantom deltas are
knife-edge ±1–3-hour flips (quarantine class). **No arm approaches the −1.0
primary on either set** (best significant effect: T1's −0.07 on A only; T5's
−0.02 is significant and microscopic). Deep capture and FR hit-rate gates
(+20/+15 pts) are missed by every arm by an order of magnitude. **NO-SHIP;
cv stays 32; branch `feat/cv34-levers` archived unmerged.**

## What the round measured (with tight CIs this time)

1. **The window fix worked**: 56 deep hours and 188 FR collapse hours per
   set (vs 10/61 in round 1) — the levers were finally measured in their
   season, and the answer is definitive rather than starved.
2. **Single-zone book levers do not move the coupled clear.** Across 6 zones
   × 5 lever families, every book-side edit is re-equilibrated away by the
   coupled system (imports absorb; ±0.1 €/MWh effects with CIs that exclude
   anything close to the gates). This is the GR-package lesson measured at
   continental scale: the six-zone collapse residual is NOT a per-zone book
   defect.
3. **T3 (pumping demand) is harmful in BOTH quantity bases** (absolute
   round 1, incremental round 2, both significant) — the load forecast's
   embedded pumping plus coupled import response already carry the real
   absorption; any added demand props prices up in exactly the wrong hours.
   The mechanism family is closed, with measurements, twice.
4. **The remaining depth residual (model −20 vs settled −80..−300) is
   bid-side, not quantity-side**: base already captures 57–79% of deep
   hours at the floor; what is missing is the DEPTH of negative bids —
   support-scheme / must-take contracts bidding −150..−500 in the real
   market. That is conduct/form territory (the program's declared
   competitive-counterfactual boundary), not another competitive-book lever.
   A depth-scaled floor could be measured, but T2's flat −80 already shows
   the offsetting-overshoot problem (bias improves 15.9→14.2, MAE flat).

## Decision

Round 2 closes the continental-collapse program as measured: two preregs,
14 scored arms, four mechanisms rejected with tight confidence intervals,
one structural conclusion (the depth residual sits at the competitive
boundary). The cheap keepers (T1 zonal-θ machinery, T5 clamp plumbing) stay
archived for any future package that needs them.
