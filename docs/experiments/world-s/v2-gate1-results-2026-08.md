# World S v2 — gate 1 results (2026-08-11): FAIL, program stops per protocol

Frozen prereg #333. Out-of-sample conduct transfer: per matched unit on the
three 2026 test days, distance (mean |Δ| over MW-weighted 25/50/75 price
quantiles) of the profile-transformed ladder vs our SRMC ladder to the
unit's ACTUAL observed offers. 350 unit-days, 137 distinct units.

| day | profile wins (% MW) | med distance SRMC | med distance profile |
|---|---|---|---|
| 2026-01-15 | **57.2%** | 78.3 | **37.0** |
| 2026-04-15 | 42.8% | 61.0 | 65.8 |
| 2026-07-15 | 44.6% | 70.5 | 72.9 |
| **all (gate)** | **48.2%** vs ≥60% | 70.4 | 58.0 |

**The gate fails; per the frozen protocol the coupled-clear arms do not run
and the v2 program stops here.**

## What the failure teaches

Conduct transfer is SEASONAL: January profiles (drawn from a pool including
winter days) transfer strongly (57% wins, distance halved), while
spring/summer days fail — consistent with Italian units adapting their
ladders to the solar season, which a season-blind trailing pool cannot
capture. The Phase-0 "67% single-shape" stability holds at the SHAPE level
but not at the LEVEL/ratio precision the bid-distance gate demands in
non-winter regimes.

A v3 candidate (NEW prereg required, not scored here): season-matched
trailing profiles (e.g. same-month-last-year ∪ trailing-30d once GME days
are fetched densely) and/or regime-conditional profiles (the same lesson
regime-packages learned for prices). Cost: a denser GME fetch. Whether to
spend that is an owner call; the framework (mapping, profiles, gates) is
built and reusable.

Artifacts: `ws2_gate1.csv`, `ws2_profiles.csv`, `unit_mapping_gme.csv`
(session scratchpad pubbooks/).
