# Flow-based domain violation probe (issue #365, first experiment)

**Question.** Are cv37's Core net positions feasible against the published
flow-based domain? No re-clear: the stored cv37 exchanges are tested against
`jao.final_domain` (PTDF · NP ≤ RAM, presolved constraints) on the only recent
window the store holds, **2026-01-01..2026-02-09** (40 days, 672 MTUs with a
presolved domain — 2026-01-01..01-28 in the domain table; the rest of the
window has no presolved rows). Scripts in `scripts/`, outputs in `output/`.
Read-only Postgres. Budget: one session slice (~1 h).

## Setup

- Model net positions: `simulations.transmission_flows` (cv37,
  `multi_zone_eu`), Core-internal exchanges only (AT, BE, CZ, DE_LU, FR, HU,
  NL, PL, RO, SI, SK; export positive). The ALEGrO exchange BE↔DE is carried on
  the virtual hubs ALBE/ALDE as JAO does (folding it into BE/DE instead moves
  the violation share from 5.2 % to 3.8 % of rows — reported both ways).
- **HR is a Core hub but not in the 39-zone footprint**; its net position is
  taken as 0. HR's realised Core net position averages +162 MW with small
  PTDFs, so this understates the model's infeasibility slightly.
- Domain: `jao.final_domain`, `presolved = true`, 112 rows per MTU incl. the
  four Core-hub / ALEGrO equality constraints (satisfied to 0 MW by
  construction on both sides — sanity check of the sign convention).
- Control: the same test on **realised physical flows** (ENTSO-E, BZN both
  sides, hourly). Physical ≠ commercial (loop flows, non-Core transit), so
  the control's violation depth is the noise floor of the test, not zero.

## Result

| | realised physical (control) | **cv37 model** |
|---|---|---|
| constraint rows violated | 1,800 of 74,069 (2.4 %) | 2,841–3,825 (3.8–5.2 %) |
| MTUs with ≥ 1 violation | 505 of 672 (75 %) | 615–647 (92–96 %) |
| median worst margin per MTU | **−74 MW** | **−329 / −542 MW** |
| p05 worst margin | −289 MW | −1,185 / −1,493 MW |
| MTUs with worst margin < −100 / −300 / −500 / −1,000 MW | 43 % / **4 % / 0 % / 0 %** | 83 % / **55 % / 37 % / 9 %** |

(Model ranges: ALEGrO folded into BE/DE / on virtual hubs.) The control puts
the loop-flow noise floor of this test at roughly 100–300 MW. cv37 sits
outside the domain by more than that in **over half the hours**, and by more
than 1 GW in one hour in eleven. Violations are spread across the day (every
hour of the day has ≥ 79 % of its MTUs violated; the deepest median at 08:00
and 23:00 UTC, −1,400 / −1,040 MW).

**Where.** Most-violated constraints (rows violated of 672 MTUs, mean depth):
PSE Mikulowa PST1 (313, 503 MW), RTE Creys–St-Vulbas 400 kV pair (312 + 201,
~200 MW), 50Hertz Röhrsdorf PST (248, 461 MW), RTE Ensdorf–Vigy (219, 298 MW),
50Hertz Vierraden PST (181, 474 MW), TenneT Altheim–Sittling (138 + 94,
105 MW), Amprion Maasbracht–Oberzier/Siersdorf (116 + 110, ~290 MW). The
DE–PL PSTs and the FR–DE/FR–BE corridor: the German transit the model routes
as free bilateral exchange.

**Which hubs push.** Mean PTDF·NP contribution on violated rows: FR +307 MW,
NL +235, ALBE +225 / ALDE +166 (the ALEGrO flow), DE_LU +119, PL +50;
BE −51. The model exports too much out of FR/NL/BE towards the German hub
and through DE to PL relative to what the grid can carry.

**Net-position benchmark (the metric #365 asks for), model vs realised
physical, 959 hours (MW):**

| hub | model mean | realised mean | MAE | bias | corr |
|---|---|---|---|---|---|
| AT | +670 | −2,372 | 3,117 | +3,042 | 0.18 |
| BE | −1,133 | −2,186 | 1,577 | +1,054 | 0.46 |
| CZ | −1,260 | +1,104 | 2,395 | −2,364 | 0.45 |
| DE_LU | −111 | +1,121 | 2,805 | −1,231 | **0.77** |
| FR | +3,425 | +2,666 | 1,978 | +759 | 0.41 |
| HU | −1,777 | −1,999 | 715 | +222 | 0.30 |
| NL | +2,973 | +2,671 | 1,632 | +301 | 0.35 |
| PL | −1,678 | +156 | 2,439 | −1,833 | **0.06** |
| RO | −1,123 | −350 | 972 | −773 | 0.45 |
| SI | +136 | −570 | 1,125 | +706 | −0.46 |
| SK | −124 | −403 | 399 | +279 | 0.51 |

Realised physical is not the auction's commercial net position (that is a
JAO publication the store does not carry yet), so the levels carry loop-flow
and transit bias; the correlations are the honest part: only DE_LU tracks the
realised pattern. AT (+670 vs −2,372) and CZ (−1,260 vs +1,104) have the
wrong sign on average — AT's Core imports that feed its exports to IT/CH, and
CZ's transit role, are absent from the bilateral-exchange picture.

## What this says for #365

- The bilateral MaxBEX scaling does **not** reconstruct the joint domain: the
  model's Core net positions are infeasible in 92–96 % of hours, by a margin
  well above the test's noise floor in more than half of them. This is the
  measurable defect the issue describes, quantified before any solver work.
- The price consequence is not measured here (a re-clear under the domain is
  the experiment). The expected direction: less FR/NL/BE→DE and DE→PL export
  capacity in the tight hours, i.e. more price separation across Core — the
  evening spread error the 2026-09 review put at 50–70 % of the satellites'
  residual.
- Data gate: the domain table covers 2022-06..2023-02 and 2026-01-01..01-28
  only. The backfill request to ceres is filed (see below); until it lands the
  domain-constrained clear can be built and validated on January 2026 only.

## Files

- `scripts/domain_probe.py` → `output/domain_probe.txt` (model, virtual-hub ALEGrO)
- `scripts/domain_control_physical.py` → `output/domain_control_physical.txt` (control + NP benchmark; model with ALEGrO folded)
