# World C vs World R — year comparison (2026-08-11): R fails its primary; the margin lesson

Frozen prereg #329; arm `regfloor_fy` (363 days, 328 common with `cv34_baseFY`),
ISO-week A/B, regfloor zones DE_LU/FR/PL/BE/CZ/NL/AT.

## The two-world table (regime hours; deep = settled ≤ −50)

| set | world | regime MAE | deep depth error | model median in deep | phantoms |
|---|---|---|---|---|---|
| A | C | 28.76 | 151.95 | +2.0 | 62 |
| A | **R** | 28.95 | **158.69** | +2.9 | 62 |
| B | C | 28.72 | 139.42 | +0.5 | 77 |
| B | **R** | 28.95 | **147.26** | +0.8 | 79 |

Guards clean (0 envelope breaches, 0 new caps, footprint +0.03). **The
primary (depth error −30%) fails on both sets — depth in fact worsens ~5%.**

## Why — the margin lesson that unifies the whole week

Re-pricing the RES block deeper CANNOT move the clearing price when the RES
block is INFRA-MARGINAL — and in the deep-collapse hours our coupled model's
marginal block is the WALL (imports / water value / thermal), sitting at
+0.5..+3 €/MWh, exactly as the continental census measured. Making
already-accepted price-takers cheaper changes nothing; where RES *was*
marginal at the −20 floor, the new-vintage block at 0 RAISES the price — the
measured worsening.

In the REAL market the deep prints happen because the price-SETTING unit
bids negative (the real books: 55–64% of negative offers are accepted — the
premium fleet is genuinely at the margin there). In our model the margin in
those hours is a block the real market does not have. So the depth residual
was never about how deep our RES bids — it is about the walls, which zone-
local levers measurably cannot move (cv34 rounds 1–2), and which the World-R
reading cannot touch by construction.

## Standing conclusion for the three worlds

- **World C** remains the canonical record; its deep-hour gap is now
  understood precisely: a wall block ~+2 holds where reality clears −80..−300.
- **World R as a RES-repricing variant is closed** (this record). A
  regulatory reading would only matter through the WALLS (e.g. whether
  regulated/must-take flows and hydro yield in surplus) — that is a
  different, harder mechanism family, and the cv34 rounds already measured
  its zone-local forms as inert.
- **World S** (per-unit conduct profiles) remains the one untried route to
  the walls: in the real books the wall-equivalent units visibly yield
  (negative/zero offers). Its fleet-transplant v1 failed on volume-base
  mismatch (#331); the unit-level v2 is the open question.

Owner deliverable fulfilled: both worlds analyzable side by side
(`cv34_baseFY` / `regfloor_fy` labels in results.duckdb).
