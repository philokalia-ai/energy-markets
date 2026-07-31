# cv29 — the surplus-regime book, pre-registration

**Gates frozen by this merge** (process directive 2026-07-30). Inherited
gates/windows from `docs/cv28-pricetaker-hydro-prereg.md` (6-month family,
A=1/8/15/22, B=4/11/18/25→19; flat-day shape rule). Baseline cv26. The
synthesis round: each cv27/cv28 treatment failed exactly where it lacked
another's finding (`docs/experiments/cv27-results.md`, `cv28-results.md`, the
GME/OMIE book measurement) — this prereg couples them under ONE primitive.

**The surplus signal (shared primitive, ex-ante):** hour h is in surplus when
the book's own price-taker mass covers gross load:
`res_qty(h) + ror_mw + deep_mustrun_mw ≥ load(h)`. No new data; one declared
inequality, no tunable threshold.

- **T1 — conditional price-taker floor:** in surplus hours ONLY, the
  price-taker block (RES, run-of-river, deep must-run) offers at
  `PRICE_TAKER_FLOOR_EUR = -20`; otherwise status-quo prices. Target: keep
  cv28's measured 41% hit-rate on settled negatives, phantom rate ≤2% (the
  cv28 falsifier that fired at 18%).
- **T2 — banded hydro placement (public-book shares, lagged):** Italy:
  reservoir/pumped hydro splits 70% at the floor / 30% at water value (GME:
  hydro at/below zero, tail ≤3%); Iberia: 25% at 1.5×gas SRMC / 75% status
  quo (OMIE ≥€300 share 15–31%). Declared shares, not per-zone tuning.
- **T3 — small-IT domestic-offer haircut:** unit offers scale by the inverse
  measured over-offer (book comparison, vol ratios): IT-Sardinia 0.5,
  IT-CSOUTH 0.62, IT-CNORTH 0.7, IT-Sicily 0.7. Named characteristic:
  self-scheduling/bilateral share visible in the public books. RES/imports
  untouched.
- **T4 — Nordic spill valley under the same regime:** the cv27-T2 mechanism
  (dryness-gated valley-following) revived WITH the floor present (its
  measured missing companion), NO4 excluded (its measured falsifier).

**Falsifiers:** phantom negatives >2% of sim-negative hours; any zone
+3.0/−0.05; new cap hours; IT family: evening MAE must improve AND family MAE
must not worsen (the cv28 lesson — direction alone is not enough); SE1/SE2
must not breach (the cv28 blanket-floor victims); NO3 median daily shape corr
≥0.55 with NO4 unharmed; Set-B non-survival.

**Protocol:** `EUPHEMIA_DISABLE_CV29` + `_T1.._T4`; all-off guard bit-identical
to main; arms cv26 (reused), all, loo_T1..loo_T4; inherited scoring + the
falsifiers; Set B once on a pass; non-draft PR with code+results; owner
decides. cv→29 only on the activating branch. Border-program borders (separate
agent, in flight) join only at the combined Set-B confirmation if both pass.
