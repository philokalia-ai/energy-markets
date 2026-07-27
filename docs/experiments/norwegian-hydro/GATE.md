# cv23 interior-Norway A/B — pre-registered gate (written BEFORE measuring)

Treatment (`NORWAY_ANCHORED_PROFILE` on NO1/NO3/NO5): `anchor_include_dropped=true`
(re-anchor the opportunity reference from the DE_LU/NL continental proxy to the
NO2/SE-dominated Nordic neighbour mix) + `import_backstop=true` (restore
demonstrated tail-day import capability). Base arm = `EUPHEMIA_DISABLE_CV23=1`.
Both arms: 39-zone coupled clear, `enrich_network=true`, `passes=2`,
`:merit_order`, HiGHS decomposed, offline extract, `:v3` flows (EU default).
Scored on realized `entsoe.energy_prices` (from the extract).

Windows (13 days):
- summer decoupled (overprice regime): 2025-09-15,16,17,18
- winter coupled (underprice guard):   2026-02-09,10,11,12
- dry-spring drawdown (the cap blowup): 2026-05-17,18,19,20,21

## PASS requires ALL of:
1. **NO1 (combined window): corr ≥ 0.30 AND MAE improves ≥ 15 €/MWh** vs base.
2. **Dry-spring window (2026-05-17..21): NO1 MAE improves ≥ 30 €/MWh** (kill the
   phantom-scarcity cap; base sim ≈ €846 vs actual €94 on cap days).
3. **NO2 does NOT degrade**: Δcorr ≥ −0.03 AND ΔMAE ≤ +1.5.
4. **No continental leakage** — DE_LU, NL, DK1, DK2 each: Δcorr ≥ −0.03 AND
   ΔMAE ≤ +1.5.

Secondary (reported, not gating): NO3, NO5, SE1–SE4.

Ship rule: PR only if the gate passes; otherwise push branch + diagnosis, no PR.
