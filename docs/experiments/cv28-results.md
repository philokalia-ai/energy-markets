# cv28 — price-taker floor + zone-aware hydro: measured NO-SHIP

Run 2026-07-31 per the frozen `docs/cv28-pricetaker-hydro-prereg.md` (#237).
Arms on cv26 baseline (cells reused), 24 Set-A days, 22,464 scored cells/arm;
all-off guard bit-identical to main (1032/1032); polarity proven at book level
(RES 1.0↔−20; IT-NORTH h19 floor mass 12.9→24.9 GW with T2; ES hydro
155→136.5 = 1.5×gas).

## Set A

| arm | MAE | corr | Δ vs cv26 |
|---|---|---|---|
| cv26 | 31.58 | 0.692 | — |
| all (T1+T2) | 32.38 | 0.695 | +0.81 / +0.003 |
| loo_T1 (T2 only) | 32.12 | 0.688 | (T1 adds +0.26) |
| loo_T2 (T1 only) | 32.21 | 0.694 | (T2 adds +0.17) |

Envelope breaches (package): SE2 +6.38, SE1 +5.07, IT-Sardinia +4.26. Zero
cap hours. Set B not run.

## Verdicts

- **T1 (unconditional −20 price-taker floor): FAIL — the floor must be
  CONDITIONAL.** It finally produces negatives (1,031 sim-neg hours; hit-rate
  202/489 = 41% of settled-negative hours — the capability works) but **185
  phantom negatives where settled >20 €/MWh (18% ≫ the 2% falsifier)** and it
  wrecks the hydro-rich north (SE1/SE2 +5–6 MAE): pricing the ENTIRE RES+RoR
  mass at −20 makes the model clear negative whenever price-takers cover
  demand, which in Nordic zones is routine — the real market only clears
  negative in genuine surplus. The mechanism needs the surplus-conditionality
  (floor only when a declared surplus signal fires) or a sized floor tranche,
  not a blanket re-price.
- **T2 (zone-aware placement): MIXED, net FAIL in combination.** Iberia
  evening improves exactly as the OMIE book predicted (27.59→25.77 MAE
  evening, corr 0.775→0.791) but overall Iberian MAE +1.3 (the flat 1.5×gas
  tail is too crude off-peak); the Italian family's corr improves
  (0.763→0.784) while MAE worsens +2.1 — moving 12 GW of hydro to the floor
  overshoots at the day scale even though the evening direction is right.
  IT-Sardinia +4.26 breach echoes the known over-offer there (book comparison:
  2.0× domestic supply).

## What survives for the next round

1. The public-book diagnosis stands (the gaps are real); the FORMS were too
   blunt. Next candidates must carry conditionality: floor-on-surplus
   (share-sized, not blanket) and placement bands (hydro ladder between floor
   and water value, not a single point).
2. The 41% negative hit-rate proves the machinery; the 18% phantom rate
   defines the design target (≤2%).
3. Any Italian placement change must co-ship with the Sardinia/small-zone
   domestic-offer haircut (the measured 1.3–2× over-offer), or it breaches.

`feat/cv28-pricetaker` stays UNMERGED (cv stays 26). Cells `scratchpad/p8/`,
scores in the session record.
