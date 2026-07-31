# NOTES ON BEING A SCIENTIST — the working discipline

1. **Theory → experiment → results.** Freeze the prereg (windows, gates,
   falsifiers, tie-breaks) by MERGING it before any scored run. The owner is
   never asked to pre-approve an unvalidated idea; they decide at the end, on
   a NON-DRAFT PR carrying code AND measured results.
2. **Set A calibrates, Set B is scored once** — only after an A-pass. Blind
   day-sampling rules; substitutions declared in advance; scored-cell counts
   beside every figure; excluded days listed.
3. **Falsifiers are named per treatment** before the run, and a fired
   falsifier is a verdict, not a negotiation. Conflicted ≠ pass. Envelope
   (+3.0 MAE / −0.05 corr per zone) and the cap ceiling guard collateral
   damage. Leave-one-out arms attribute every package effect.
4. **Regime-conditional judgment**: regime mechanisms are gated by a simple
   ex-ante axis (per zone-group) and judged WITHIN the regime; outside-regime
   deltas must be ≈0 by construction and are verified. All-hours averages are
   a collateral guard, never the acceptance metric.
5. **Report the collapse classification** (hit/false-alarm on ≤€5 and <0
   hours) wherever the mechanism or input touches the surplus regime.
6. **NO-SHIP is a first-class outcome**: document the measured verdict and
   the mechanism lesson in docs/experiments/, leave the branch unmerged, and
   let the lesson constrain the successor (see cv26-scarcity, cv28, cv29,
   demand-elasticity). Never tune around a fired falsifier in the same run —
   amendments are declared, disclosed, and re-measured.
7. **Controls and bounds**: positive controls for "no effect" claims (prove
   the switch changes the SQL/inputs); oracle bounds before building (what's
   the maximum a mechanism could gain?); paired arms on identical days;
   fresh process per cell; polarity proven at book level before sweeps.
8. **Deviations are disclosed, not hidden** — in the results doc's opening,
   with the as-ratified and as-executed numbers side by side when they differ.
9. **Suspect the data first**: the program's largest gains came from input
   bugs (ATC contamination, lookahead flows), found by reading rows, not by
   fitting. When a zone breaks, check what its book actually consumed.
10. **Token/machine efficiency is part of rigor**: reuse baseline cells,
    grouped day-level scans with caches, extensive sweeps on the full machine
    when the design is frozen — but never at the cost of a fresh-process or
    identity guarantee.
