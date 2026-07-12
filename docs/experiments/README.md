# Experiments — standalone prototypes behind negative results

Self-contained scripts that were run once to answer a specific methodological
question, committed as the record that we tested it. They are **not** part of
the library or the test suite; each needs the data store (Postgres or the
DuckDB extract) and, where noted, Gurobi. Full write-up and verdicts:
[../complex-orders-investigation.md](../complex-orders-investigation.md).

| Script | Question | Verdict |
|---|---|---|
| `proto_ramp_dispatch.jl` | Does ramp coupling (buildup/builddown) alone move the competitive price shape closer to reality? GR, 2026-04-03, LP with duals (HiGHS). | **No.** Corr 0.743 → 0.762 (+0.02), MAE slightly worse. The dominant error (midday collapse) is a commitment/cost-stack effect, not a ramp effect. |
| `proto_mini_uc.jl` | Does endogenous commitment (mini-UC + fix-and-reprice, water-valued hydro) beat the per-period clear? GR, 2026-04-03 (Gurobi). | **No — slightly worse** (corr 0.884 → 0.747, MAE 22.7 → 23.4). With hydro at its water value the per-period clear already holds the midday price; commitment's min-load constraints distort the shoulders. |
| `proto_mini_uc_de.jl` | Same mini-UC on a thermal-cycling zone: DE_LU, 2025-12-15 winter (Gurobi). | **Flips: helps** (corr 0.831 → 0.870, MAE 21.3 → 14.8, shortage-artefact hours excluded). Commitment carries real information where plants genuinely cycle — the effect is conditional, not universal. |

The follow-up one-variable isolation (endogenous must-run inside the calibrated
merit book, 16-zone canary) and the final verdict — no always-on temporal-order
mechanism beats the calibrated per-period book; the live lead is a
winter/tight-day-gated endogenous must-run — are in the investigation doc. The
mechanism code (`src/BlockCommitment.jl`) and canary harnesses stay on the
parked branch `feat/v17-block-commitment` (commits 7635e2b, 708e16f).
