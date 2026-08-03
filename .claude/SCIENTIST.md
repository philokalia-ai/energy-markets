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
10. **Same-version comparisons only** (owner, 2026-08): any cross-track or
    cross-time score comparison pairs slices of the SAME code_version —
    never conflate model-version deltas with input deltas ("n/a (cv
    mismatch)" beats a wrong number). The announced track has NO lead
    ladder: one D-1 freeze per delivery day.
11. **Retro/reset labeling contract**: genuine live vintages are immutable;
    a retroactive fill is explicitly labeled (is_retro + reset_tag), the
    writer REFUSES to touch live slices by default, and supersede-with-
    backup (forecast_prices_pre_reset, backup==replaced asserted) is the
    only sanctioned exception. Data gaps at source are documented, never
    fabricated (e.g. announced 2026-07-11 = 32/33).
12. **Token/machine efficiency is part of rigor**: reuse baseline cells,
    grouped day-level scans with caches, extensive sweeps on the full machine
    when the design is frozen — but never at the cost of a fresh-process or
    identity guarantee.
