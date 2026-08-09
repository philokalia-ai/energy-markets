# R2 package 1 (IT) — results: NO-SHIP as frozen, with the seasonal-gate lesson

Run `r2_it_fy` (2026-08-09, 335/365 days, quarantine applied, vs fresh
`trmk_base_fy`). Package as ratified: leg-1 actuals-ML solar for IT-Sicily
(+131 MW mean correction) and IT-Sardinia (65 MW; its R1 scorecard won so
its opt-out did not trigger); leg-2 measured structural NO-OP (the book
never consumes RES registry capacity — book_build.jl fleet completion
explicitly skips Wind/Solar); leg-3 automatic (runtime backstop).

| gate | Set A (Aug–Jan) | Set B (Feb–Jul) | verdict |
|---|---:|---:|---|
| family mean ΔMAE ≤ −0.25 | −0.03 | −0.21 | **FAIL both** |
| no zone worse than +0.20 | +0.03 worst | 0.00 worst | pass |
| footprint ≤ +0.05 / caps / envelope | −0.04 / 6→6 / clean | | pass |

Treated-zone summer deltas: IT-Sicily −0.35, IT-Calabria −0.30, IT-SOUTH
−0.29, IT-CSOUTH −0.23. Zero collateral anywhere.

**The lesson (rule 3 violated by my own gate design):** a SOLAR-input
package was frozen with an ALL-MONTHS family gate; winter dilutes a
mechanism that by construction lives in solar-relevant hours. The
methodology's regime-conditional rule should have set the primary gate
within-regime (e.g. solar-share ≥ θ hours, both sets). Re-scoring THIS run
with a regime gate after seeing the results would be post-hoc and is not
claimed; the numbers above stand as measured. Successor packages freeze
regime-conditional primaries from the start (owner disposition pending:
park / re-gated v2 on fresh window / proceed to Iberia with the lesson).

Data: `r2_it_fy` + all comparison labels in results.duckdb; models in the
session scratchpad `models39_actuals/`; deltas `it_ml_deltas.csv`.
