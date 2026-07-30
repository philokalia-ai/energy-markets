# cv28 — price-taker book floor + zone-aware hydro placement, pre-registration

**Status: gates frozen by this merge (process directive 2026-07-30): the
experimenter runs theory→experiment→results autonomously; the owner decides on
the measured numbers.** Inherited gates/tie-break/envelope from
`docs/cv25-phase2-prereg.md`; Set A calibrates, Set B scored once; baseline =
cv26 main. Windows: the cv27 6-month family (2025-01, 2026-01, 2024-07,
2025-07, 2025-05, 2026-05; A=1/8/15/22, B=4/11/18/25, 2025-07-18→19). Shape
stats under the preregistered flat-day rule.

**Evidence base** (docs/experiments/cv27-results.md + the 2026-07-30 GME/OMIE
public-book measurement, frozen protocol in the session record): real books
put 20–78% (IT) / 26–42% (Iberia) of offered supply at ≤0 €/MWh — ours 0%;
our Italian reservoir hydro is opportunity-priced into the €301–675 band the
real book doesn't have (evening dP +121 NORD), while Iberia's real book
carries the fat cap-tail we lack (midday slope 0.7 vs 17.6 €/MWh/GW); cv27 T3
proved a must-run-only negative floor is inert while RES sits at +€1.

## T1 — price-taker floor (footprint-wide form)

- **Lever:** the price-taker block — RES forecast injection + run-of-river +
  the deep must-run block — prices at a single declared floor
  `PRICE_TAKER_FLOOR_EUR = -20.0` (form-level constant; the cv27 T3 constant
  generalized from must-run-only to the full price-taker set). The RES
  *forecast* tranche moves from +1 to the floor; everything else in the book
  unchanged.
- **Market characteristic:** support-scheme + inflexibility economics — the
  documented ≤0 mass in every public book.
- **Expected:** settled-negative hours become reproducible (hit-rate > 0);
  midday MAE falls in NL/DE_LU/ES/DK1/PL/SE3; no level shift where demand
  clears mid-ladder (the marginal unit, not the floor, sets those prices).
- **Falsifiers:** phantom negatives (sim<0 where settled>20) beyond 2% of
  sim-negative hours; any zone +3.0/−0.05; new cap hours; Set-B non-survival.

## T2 — zone-aware hydro placement

- **Lever:** ZoneProfile gains `hydro_placement::Symbol` (∈ `:opportunity`
  (status quo), `:price_taker`, `:cap_tail`): Italian zones set
  `:price_taker` (reservoir hydro joins the price-taker block at the floor —
  the measured GME behaviour), Iberia sets `:cap_tail` (the water-value order
  re-prices to a declared high band — 1.5×gas SRMC, the measured OMIE
  opportunity tail), Nordic/others unchanged (`:opportunity`). One new enum
  field + two declared constants; no per-zone tuning beyond the three-way
  placement that the public books justify zone-by-zone.
- **Falsifiers:** IT evening dP direction must move toward the book truth
  (NORD evening MAE improves); ES/PT MAE improves; the inherited envelope; no
  new caps; Set-B non-survival.

## Protocol

1. Behind `EUPHEMIA_DISABLE_CV28` + `_T1/_T2`; all-off guard bit-identical to
   cv26 main (1032/1032) before any arm.
2. Arms Set A: `cv26`, `all`, `loo_T1`, `loo_T2` (reuse the existing cv26
   baseline cells). Per-cell harness, HiGHS, ≤12-way (machine shared with the
   border and demand agents).
3. Inherited gates + the falsifiers above; Set B once on a pass; non-draft PR
   with code AND results; owner decides. cv→28 only on the activating branch.

**Interaction note:** the demand-elasticity program (separate agent) measures
against cv26 and scopes to mid/high-price elasticity; if both ship, the
combined arm re-runs Set B before any backfill.
