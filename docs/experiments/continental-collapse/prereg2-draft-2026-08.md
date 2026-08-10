# Continental package, round 2 — successor prereg DRAFT (2026-08-10)

Supersedes round 1 ([setA-results-2026-08.md](setA-results-2026-08.md): no
A-pass — window starvation + the pumping double-count). Freezes at merge.

## What changes (and why, each from a measured finding)

1. **Regime-balanced evaluation windows.** Split by **ISO-week parity** over
   the full year (odd weeks → Set A, even → Set B): ex-ante, deterministic,
   both sets carry every season — Set A holds ~half of the ~170 deep-collapse
   hours instead of 10. Adjacent-day leakage is bounded by the week
   granularity. (Round-1 lesson; the harness gains this rule for every
   seasonal-regime package.)
2. **T3 becomes INCREMENTAL pumping.** The ENTSO-E total load fc already
   embeds expected pumping (the round-1 double-count, measured 50%→0% deep
   capture). New quantity basis: `max(0, trailing-30d p95 pumping −
   trailing-30d MEAN pumping for that hour-of-day)` — the demonstrated
   HEADROOM beyond what the fc plausibly embeds. Pricing unchanged (owner
   mechanism): η × pass-1 evening value, η ∈ {0.6, 0.7}.
3. **T5 (new, from the census wall): CH water-value yield.** The Swiss wall
   is reservoir supply at anchored water value (census step 3, ~5.9 GW).
   In-regime (share ≥ 0.4), the anchored hydro block's price yields to the
   floor for the surplus hours — the supply-side twin of pumping, and the
   only CH lever the data supports (no CH pumping series).
4. T1 (θ_FR = 0.3), T2 (θ2 = 0.7 → −80), T4 (pass-1-gated valley wall)
   carry over UNCHANGED — benign in round 1, unmeasured in their season.

## Frozen evaluation

- Arms: base, T1, T2, T3-incr(η=.7), T4, T5, combo — same leave-one-out
  discipline, fresh baselines, both window sets from the same runs (the
  parity split is applied at scoring).
- **Primary**: six-zone within-regime MAE −1.0 on Set A AND Set B; deep
  capture (model ≤ −20 | settled ≤ −50) +20 pts on the DE_LU/PL/BE family;
  FR spring-collapse hit +15 pts (FR winter wind/nuclear collapses are OUT
  of this package's regime by construction — solar-share gate).
- **Falsifiers**: phantom rate not up per zone beyond quarantine-class
  ±2-hour knife-edge flips (measured base levels recorded in round 1);
  envelope ±3.0/−0.05 all 39; zero new non-quarantine caps; outside-regime
  ΔMAE ≈ 0; SEE byte-identity all-off.

## Status

- [ ] Prereg ratified (freezes at merge)
- [ ] T3-incr + T5 implemented behind switches (T1/T2/T4 already on
      feat/cv34-levers) + identity guard
- [ ] Full-year arms (both sets fall out of one run per arm)
- [ ] A-gates checked → B scored once → ship/no-ship → cv34 decision
