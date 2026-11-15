# Timestral forecast of the cv44 pumped-storage budget — gate-1 FAIL (2026-11-15)

**Idea** (planner-p2, idea 1). Replace the cv44 budget E₁₄, the 14-day mean of
daily PS generation, with **0.5·E₁₄ + 0.5·Ê**. Ê is the sum of non-negative
Timestral-209M median forecasts of delivery-day hourly PS generation. The
blend is capped at 24 × the trailing-30-day p95 hourly output.

**Setup**
- Context: 2,048 h, ending at the lead-1 cutoff D-1 00:00 UTC, the same
  cutoff `_storage_cutoff_day` uses.
- No fitting and no price input.
- Days: the 8 calibration days.
- Coverage: 158 zone-days in 20 PS zones, of which 102 zone-days in 19 zones
  have both D and D-7 fully observed. 49 zone-days lack a complete
  delivery-day actual, mostly at the end of the extract.

**Result.** Mean absolute error of daily MWh on the 102 complete zone-days:

| Budget | MAE (MWh/day) | Bias |
|---|---|---|
| E₁₄ | 3,366 | +23 |
| D-7 | 3,330 | −167 |
| Ê | 3,067 | −590 |
| Blend | 3,191 | −283 |

The blend improves on E₁₄ by **+5.2 %** and on D-7 by **+4.2 %**; the gate was
≥ 10 % against both. Timestral alone reaches only +8.9 % and +7.9 %.

**Gate 1 fails, so no paired clears were run** (pilot contract).

Why: daily PS generation is endogenous dispatch, driven by the delivery day's
spreads, wind and solar. Its own history barely predicts it.
- Errors are about 30–40 % of the daily energy for every predictor; the median
  relative error is 0.36 for E₁₄ and 0.32 for the blend.
- The large zones dominate the result, and Timestral helps some and hurts
  others:

  | Zone | E₁₄ | Ê | D-7 |
  |---|---|---|---|
  | ES | 5,274 | 7,283 | |
  | CH | 8,489 | 9,164 | |
  | DE_LU | 10,205 | 7,808 | |
  | AT | 6,974 | 4,570 | 4,565 |

- Timestral's systematic under-forecast (bias −590) is halved by the blend but
  remains.

A useful budget forecast would need the drivers (forecast spread, RES) rather
than univariate history. The circularity caveat applies: generation is
dispatch, not stored energy. Archived; the cv44 budget stays E₁₄.

Script: `gate1_budget.py`. Output: `em-team/results/blocks/p2_gate1.csv`.

---

# Idea 2 — PS opportunity reference from a frozen 06:30 Timestral price forecast: PASS (2026-11-15)

**Mechanism.** Opt-in, behind two environment variables:
`EUPHEMIA_PS_OPP_REF_FILE` (the forecast file) and `EUPHEMIA_PS_OPP_ZONES`
(which zones apply it).

The inputs are frozen before either clearing pass:
- **Forecast:** the tsfm agent's prices-only Timestral-209M forecast of
  delivery day D, issued 06:30 UTC D-1 (`fc_t209_uni_L1`).
- **Context:** ends D-1 21:00 UTC. D-1's prices were auctioned on D-2, so the
  input is ex-ante.

In the `:hydro`-anchored pass-2 books of the listed zones (here CH and AT),
**pumped-storage units only** change their reference price:
- The reference becomes **0.5 × the coupled reference + 0.5 × r**. Everything
  else is unchanged: the anchor share, the dryness boost and the
  [2, gas SRMC] clamp. Reservoir hydro is untouched.
- **r** is the H-th highest forecast hourly price of D.
- **H** = round(E₁₄ / offered PS MW), bounded to 1–24.

The day's forecast prices are sorted, so r uses their rank, not their hour.

**Not inert.** Between 11 and 384 PS unit-slots change price per zone-day, with
r between 186 and 328 €/MWh.

**Evaluation** (true 06:30, rerun after the #414 review).
- **Code:** cv44 default (`ps` on) on both arms; base vs treatment differ only
  in this switch.
- **Context:** the lead-1 issuance at **06:30 UTC D-1**, built directly as
  `ForecastContext(d, D-1 06:30, 1, …)`. `issuance_context(d, 1; …)` would
  silently use the 10:00 gate.
- **Forecast vintage:** issued D-1 06:30, admissible at that issuance.
- **Days:** the 8 calibration days; all 16 clears `optimal`.
- **Pairing:** 7,486 paired cells against the live-JSON SDAC actual.
- **PS generation:** the master LP's hourly PS allocation is used as model
  dispatch and compared with ENTSO-E actual PS generation (381 CH/AT hours).

| gate | base → treatment | threshold | |
|---|---|---|---|
| CH hourly PS-generation MAE | 653 → 479 MW (**+26.7 %**) | ≥ 10 % | pass |
| AT hourly PS-generation MAE | 402 → 326 MW (**+19.0 %**) | ≥ 10 % | pass |
| CH/AT price MAE (384 cells) | 56.61 → 55.62 (**−0.99**) | ≤ −0.5 | pass |
| footprint MAE | 48.05 → 47.93 (−0.13) | degradation ≤ +0.5 | pass |
| cap/floor prints | 0 → 0 | no new | pass |

**Coverage, read before trusting the price number**
- Only 34 of the 384 CH/AT cells move, and all 34 improve.
- 187 cells move footprint-wide.
- By day, the price gain comes from:

  | Day | ΔMAE (CH/AT) | Cells moved |
  |---|---|---|
  | 11-13 | −5.34 | 23 |
  | 09-27 | −1.53 | 4 |
  | 09-20 | −0.74 | 5 |
  | 09-16 | −0.34 | 2 |
  | 10-06, 10-19, 11-02, 11-04 | 0 | 0 |

- The PS-generation gain is broad. Model dispatch moves from 657 to 449 MW
  mean in CH (actual 586) and from 397 to 301 in AT (actual 433).
- The CH level bias (−71) is essentially untouched.

**An earlier run, labelled "06:30", actually ran at 10:00** (the
`issuance_context` lead-1 delegation, caught in review). It gave the same
verdict: CH/AT price −0.92, PS generation +23.6 % (CH) and +20.6 % (AT),
footprint −0.10, caps 0→0. Its results are kept as `o_*_1000`.

**Review fixes in the code.**
- `issued_utc` is parsed, and only vintages issued at or before the active
  issuance are admissible. On the legacy path the explicit cutoff is
  D-1 10:00 UTC. The latest admissible vintage wins.
- Later vintages therefore never feed earlier issuances or leads 2–7.
- The file is snapshotted and validated once, before pass 1, and both passes
  read that immutable snapshot.
- With no snapshot (e.g. pipelined-backfill book workers) the switch is off;
  a malformed file is an error.

**Caveats**
- *Circularity:* historic prices already embody storage behaviour and conduct.
  This is a statistically informed predictive variant, not an independent
  conduct benchmark. The forecast is frozen, and no clearing price is fed back
  into it.
- 8 days is a pilot gate, not seasonal validation.
- Turning it on in production needs the daily 06:30 Timestral forecast
  written where the clear can read it (the tsfm overlay pipeline) before the
  clear runs. Until then the switch stays off.

Scripts: `gate_oppref.py`. Forecast table: `em-team/results/blocks/p2_oppref.csv`.
