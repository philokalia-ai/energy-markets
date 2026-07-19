# Strategic layer — Phase B pilots: DE_LU and FR

The [roadmap](../strategic-layer-roadmap.md)'s Phase B applies the GR
strategic-bidding protocol ([gr-strategic-bidding/](../gr-strategic-bidding/))
to other zones, one at a time, with pre-registered gates. This directory holds
the zone-generalized harness and the first two pilots.

**Pre-registered expectation.** The residual-sign gate showed DE_LU and FR
medium-corr band residuals of **+4.5 / +4.2 €/MWh** — far below GR's +13 on its
selected days — so the expectation *written down before running* was
little-to-no exercisable markup. That makes these pilots the **placebo half**
of the GR finding: an instrument that "finds market power" everywhere is
measuring its own bias; one that finds it in GR and not in DE/FR is
discriminating.

## Harness (`zone_common.jl`, `select_days.py`, `run_pilot.jl`)

Same discipline as the corrected GR experiment — hour-averaged pairing, paired
ΔMAE vs the same-day baseline, post-hoc additive level-shift null,
calibration/held-out split — with three zone generalizations: clearing runs
`run_multi_zone_market_clearing(zones=[ZONE, partner], enrich_network=true,
apply_zone_profiles=true, passes=2)` so each zone gets its **own calibrated
ZoneProfile** (the legacy single-zone path forces SEE_PROFILE); the partner is
an NTC-link neighbor with offered implicit ATC (DE_LU–DK1, FR–ES — Core-FBMC
borders publish none); `firm_of` merges the committed wave-1 name-rule maps
([firm-maps/](../firm-maps/): DE_LU 84 % of registry MW, FR 91 %).

Day sets from the cv17 coupled baseline (`eu17_base`): DE_LU 44 calibration +
44 held-out (of an 88-day band — DE_LU fits well, mean corr 0.88); FR 60 + 139.

**Acceptance gates** (roadmap Phase B — all three or no strategic layer):
beat the additive null on the held-out set; raise held-out correlation;
better on >60 % of held-out days.

## Results

### DE_LU — gate FAILED (no exercisable markup)

| calibration (44 d) | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| big4 15 % (RWE+LEAG+Uniper+EnBW) | 0.67 | 20.18 | −1.59 | +0.58 | 25/44 |
| RWE 15 % | 0.65 | 20.53 | −0.52 | +0.23 | 23/44 |
| *baseline* | 0.62 | 20.76 | **+0.35** | 0.00 | — |
| *additive null (−1.0 flat)* | 0.62 | 20.74 | +1.35 | +0.02 | — |

Held-out: big4_15 ΔMAE +0.68 but only **23/44 days (52 %) — fails the >60 %
consistency gate** — and it drives the residual from ≈0 to **−2.4** (there was
no positive residual to close; the markup overshoots). Per-firm effects are
0.1–0.2 €/MWh — an order of magnitude below GR's +3.1. **Verdict: the German
incumbents' day-ahead bids are consistent with cost; no strategic layer for
DE_LU.**

### FR — gate FAILED (EDF's competitive bidding is the right model)

| calibration (60 d) | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| Total 25 % | 0.65 | 30.19 | −1.66 | +0.48 | 21/60 |
| *baseline* | 0.65 | 30.68 | **−1.46** | 0.00 | — |
| **EDF 15 %** | 0.65 | 31.23 | −8.51 | **−0.55** | 30/60 |
| **EDF 25 %** | 0.64 | 32.19 | −12.30 | **−1.52** | 26/60 |

The headline: **marking up EDF makes the model *worse*, monotonically** — the
baseline residual is already slightly negative and an EDF markup drives it to
−8/−12. On the held-out 139 days the only null-beating calibration config
(Total 25 %) **fails outright** (ΔMAE −0.35, 49/139 days). **Verdict: EDF —
~90 % of French capacity — bids its nuclear/hydro at competitive opportunity
cost in the day-ahead; no strategic layer for FR.** (FR's held-out residual is
−19: the model *over*prices those days — a water-value/nuclear-anchor
calibration question, explicitly not a bidding-strategy one.)

### HU — gate FAILED, but the closest call (wave-2 map: MVM/MET/Mátra, 76 %)

HU is the only other GR-magnitude positive zone (calibration residual
**+12.5**, median +10.2). Pilot via the HU–RS *explicit* ATC border (HU has
zero implicit — Core FBMC). Calibration: `big3_25` (MVM+MET+Mátra at 25 %)
ΔMAE +0.88 vs null +0.62, 62 % consistency. Held-out (155 days):

| | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| big3 25 % | 0.55 | **36.11** | +4.66 | +0.64 | **87/155 (56 %)** |
| *additive null (+3.75)* | 0.54 | 36.60 | — | +0.16 | — |
| *baseline* | 0.54 | 36.76 | +8.57 | 0.00 | — |

It **beats the null out-of-sample** (−0.49 MAE vs the null) and nudges corr
+0.01 — but **56 % day-consistency fails the >60 % gate**, and the markup
closes only ~a third of the residual (8.6 → 4.7). Verdict: **no strategic
layer for HU under the pre-registered gates** — suggestive, not confirmed.
The honest reading: HU's residual is at least half a *model* problem (it is
the border-repair transit zone; its 2-zone pilot baseline corr 0.54 is far
below its coupled 0.71) — re-test after the next import-model iteration.

## The four-zone picture

| zone | dominant | band resid | held-out vs null | consistency | verdict |
|---|---|---:|---|---:|---|
| **GR** | PPC ~69 % | **+13.2** | **+3.05 vs +2.00 ✓** | **80 %** | **markup ~25 % real** |
| HU | MVM/MET/Mátra | +12.5 | +0.64 vs +0.16 ✓ | 56 % ✗ | suggestive, not confirmed |
| DE_LU | big4 | +0.35 | +0.68 vs +0.01 | 52 % ✗ | none |
| FR | EDF ~90 % | −1.46 | wrong-signed | — | none (competitive) |

## The triptych (first three zones — see the four-zone table above)

| zone | dominant firm | band resid | best markup vs null (held-out) | consistency | verdict |
|---|---|---:|---|---:|---|
| **GR** | PPC ~69 % | **+13.2** | **+3.05 vs +2.00 — beats** | **75/94 (80 %)** | **markup ~25 % real** |
| DE_LU | RWE + big4 | +0.35 | +0.68 vs +0.01 (tiny) | 23/44 (52 %) — fails | none |
| FR | EDF ~90 % | −1.46 | EDF wrong-signed | — | none (competitive) |

The instrument discriminates: it detects an exercisable portfolio markup where
the residual, the dispatch evidence and the market structure all point the same
way (GR), and stays silent where incumbents bid competitively (DE_LU, FR) —
including refusing the *most* concentrated market of the three (FR/EDF), which
is exactly what a bias-driven instrument would have flagged. This is the
validation Phase C builds on: the EU strategic counterfactual will carry a
strategic layer **only for zones that pass these gates**, currently GR alone.

## Running

```bash
python3 docs/experiments/strategic-layer/select_days.py DE_LU 44
SL_ZONE=DE_LU julia --project=. docs/experiments/strategic-layer/run_pilot.jl
SL_ZONE=FR    julia --project=. docs/experiments/strategic-layer/run_pilot.jl
```

Next zones need wave-2 firm maps (ES: Endesa/Iberdrola/Naturgy; IT: Enel/
Edison/A2A/EPH) — and the interesting positive-residual candidates per the
cv17 sign scan are HU (needs a usable firm map; 88 % unmapped today) and the
GR-adjacent SEE corridor once its import-side model residual is separated.
