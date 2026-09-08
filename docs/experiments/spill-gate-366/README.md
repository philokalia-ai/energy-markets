# Spill-regime quantity gate (issue #366, hydro slice)

**Mechanism** (`feat/spill-gate-366`, stacked on the #370 fix). When a
reservoir zone's ex-ante fill ratio — the latest weekly stored energy before
the delivery day divided by the MAXIMUM stored energy seen in the same ISO
weeks (±2) of prior years (`get_reservoir_fill_ratio`) — is at or above the
gate, a share of every reservoir unit's offered quantity is priced at the
run-instead-of-spill cost and the rest stays on the water-value curve:
share = `spill_gate_share` × clamp((ratio − gate) / 0.10, 0, 1). Profile
fields `spill_gate_ratio` (0 = off, bit-identical), `spill_gate_share`
(0.5), `spill_gate_price` (€1). `EUPHEMIA_SPILL_GATE=<ratio>` arms every
`:reservoir_opportunity` profile for an A/B. A *quantity* gate, not a level
discount: the cv37 nordic-wetness T1 level discount destroyed the daily
shape (NO4 corr 0.26 → −0.02).

**Why this signal.** 2024-01..2026-35, 11 zones (`docs/experiments/review-2026-09`
§2.2 and the probe in the commit message): next-week settled ≤ 5 €/MWh share
is 9 % when the ratio is below 0.7, 27 % at 0.95–1.0, 38 % above 1.0 (NO4:
70 %); mean price 69 → 31–37. Physically: storage exhausted ⇒ the marginal
value of the water that would spill is ~0.

## A/B (paired, live Postgres, Gurobi, 39 zones)

52 even-ISO-week Wednesdays 2024-09-04..2026-08-19 (two years, all seasons —
a one-year Wednesday set misses the full-reservoir regimes), `ab366_base`
(gate off) vs `ab366_spill` (gate 0.95, share 0.5, €1). Base is
deterministic (#370) and reproduces the #370 interval arm exactly on the 26
shared days. `scripts/ab_arm.jl`, `scripts/score_ab.py`,
`scripts/score_in_gate.py`.

### Footprint (`output/ab_score.txt`; 47,300 paired zone-hours, 38 zones)

| | base | spill |
|---|---|---|
| MAE / energy-weighted | 28.15 / 26.96 | 28.06 / 26.92 |
| bias | −8.21 | −8.32 |
| corr | 0.768 | 0.768 |
| cells moved | | 958 (2.0 %), mean |Δ| 5.4, max 35 |

Per zone: NO4 −0.81 (bias +16.3 → +15.5, corr +0.008), NO3 −0.77, SE1 −0.47,
SE2 −0.43, FI −0.27, SE3 −0.16, NO5 −0.15, NO1 −0.08, Baltics −0.03..−0.06;
**no zone worse than +0.003**; the continent, Iberia and Italy untouched
(0–5 cells).

### Where it acts (`output/ab_score_in_gate.txt`; zone-days with ratio ≥ 0.95)

2,208 in-gate zone-hours (NO4 744, NO3 480, SE2 480, SE1 192, SE3 192, NO5
96, NO1 24):

| | base | spill |
|---|---|---|
| MAE | 26.36 | **25.09** (−1.27) |
| bias | +13.97 | +12.55 |
| corr | 0.629 | 0.638 |
| settled ≤ 5 hours | 846 | |
| collapse recall | 0.025 | 0.035 |
| p10 of the model price | 20.9 | 19.4 |

By ratio bin: 0.95–1.0 −0.29 (1,224 cells), 1.0–1.05 −1.32 (408), **≥ 1.05
−3.30** (576; bias +17.2 → +13.8) — the effect scales with how far above
the historical maximum the reservoir sits, as the physics says it should.
Out-of-gate guard (12,768 Nordic cells): dMAE −0.10, bias +0.24 → +0.10 —
beneficial spillover from cheaper neighbouring exports, no harm.

**What it does not do.** Collapse recall stays ~0 (NO4: 312 settled ≤ 5
hours, model p10 20.0 → 19.96). With at most half the reservoir quantity at
€1 the marginal block in the isolated Nordic zones remains the water-value
curve, so the level moves by 1–3 €/MWh where the settled market sits at
0–5. The physically complete version — share → 1.0 once the reservoir is
above the historical maximum (every MWh of further inflow spills) — is the
obvious next arm, together with the `:hydro`-anchored NO zones (NO1/NO3/NO5
price off the pass-1 anchor and only see the gate through their reservoir
units). Not run here: one paired measurement per mechanism (rule 5).

**Recommendation.** Physically right, measured where it acts (−1.27 in
gate, −3.3 above the historical max), no zone harmed, 2 % of cells touched.
Ship-ready as a profile default (`spill_gate_ratio = 0.95` on
NORDIC_PROFILE / NO4_PROFILE / the SE profiles) if the owner wants the
modest version now; the share-1.0 arm is the one that could reach the
collapse hours.
