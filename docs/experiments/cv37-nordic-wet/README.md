# cv37: wetness-adjusted seasonal drawdown (2026-08-27)

Recovery-plan item 2 (owner-approved). Evidence from the 2-year conduct probe:
the Nordic bias is +13..+23 in WET months with corr(bias, dryness) −0.26..−0.40
(SE1/SE2/NO1/NO3) — the seasonal drawdown lifts the water value every winter
regardless of wetness, because reservoirs always deplete seasonally, while in a
wet year the shadow value of stored water stays low.

## Mechanism

`ZoneProfile.wet_adjusted_drawdown` (default false = bit-identical):
`eff_seasonal = clamp(drawdown + signed_dryness, max(signed_dryness,0), 1)` in
the `:reservoir_opportunity` water value; `get_reservoir_dryness(; signed=true)`
returns NEGATIVE dryness for wetter-than-norm (legacy consumers keep the 0
clamp). Verified signals: SE2 Feb-2025 −0.70, Feb-2026 −0.21, NO4 −0.55.
Applied to SE1, SE2, FI, DK1, DK2, NO4 (the non-anchored reservoir zones —
the only ones that reach the wv_frac branch).

## Results (Gurobi, cv36-code baselines)

**Set A (26 odd Wednesdays 2025-07..2026-06 — a mild winter):** touched
23.41→23.27, SE1 −0.5, SE2 −0.4, worst untouched +0.66 (LV) — mild-positive;
the mechanism barely fires because last winter's wetness was −0.2.

**Wet-winter Wednesdays (2024-11..2025-04, 26 days — where it acts; baseline =
the cv36 2-year record):** SE2 33.8→25.8 (−8.0, bias +26.2→+16.7, corr
0.61→0.69), SE1 29.2→22.7 (−6.5, 0.62→0.70), FI −2.8; beneficial spillover
NO3 −3.5, SE3 −2.3, Baltics −0.7..−0.9; touched 32.40→29.49, untouched
31.04→30.96, worst untouched +0.93 (CH), zero new cap hours.

**Held-out wet-winter SUNDAYS (25 days, scored once):** SE2 34.4→25.1 (−9.3,
corr 0.40→0.63), SE1 31.7→23.8 (−7.8, 0.42→0.65), SE3 spillover −4.0
(0.73→0.80), NO3 −3.4; touched 29.02→25.68, untouched 23.70→23.29, worst
untouched +0.48. DK1 −0.2 (its Set-A wobble did not replicate).

**Promoted**: `wet_adjusted_drawdown = true` on NORDIC_PROFILE and NO4_PROFILE
(covers exactly the six tested zones; anchored Nordics unchanged). Remaining
NO1/NO3/NO5 residual is the anchored-path / congestion-isolation story (the
probe's NO3 flat +20 bias) — a separate mechanism, not this one.
