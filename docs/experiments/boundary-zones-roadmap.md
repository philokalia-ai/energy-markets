# Virtual boundary zones — consolidated roadmap after waves 1 & 2

Program: replace exogenous boundary-flow *predictions* with **modeled boundary
counterparties** — elastic supply/demand books so the coupled clearing prices
the boundary exchange endogenously ("model the country, not the flow").
Experiments: `docs/experiments/boundary-zones/` (wave 1 — GR/BG vs TR/AL/MK,
branch `exp/boundary-zones`) and `docs/experiments/boundary-zones-w2/`
(wave 2 — GB and UA, branch `exp/boundary-zones-w2`). 134 + 72 coupled
39-zone solves, zero failures. This document is the decision record and the
iteration plan.

## What the two waves established

1. **The mechanism works — the elasticity does the work.** Where the July-2026
   regime flip lived (SEE), the fundamental neighbor book (Mechanism A) cut
   evening bias 66–73% (GR +57→−16, BG +45→−15; 21 zones better / 0 worse),
   with **no pool and no forecasting**: when the heatwave lifts our price, the
   ladder delivers imports; the price decides. UA confirmed on its pocket:
   HU July corr 0.73→**0.83**, MAE 68→55; July footprint mean MAE 33.1→32.3
   (24 better / 9 worse).
2. **Fixed anchors are the disease.** Every failure mode traces to the
   hand-picked anchor level, not the mechanism: TR's 0.65×gas is €10–20 low
   in normal months (wave-1 March: GR evening → −20); GB's CCGT anchor
   understates its pull (BE March evening −2→−21, and July improves
   monotonically toward the +15% anchor). **Anchors must be daily
   fundamentals of the NEIGHBOR** (its own fuel/carbon costs), never a fixed
   multiple of ours.
3. **Empirical revealed-behavior curves (Mechanism B) are a dead end** — they
   inherit the training-pool problem and reduce to a smarter climatology.
   Measured, rejected, documented.
4. **Not every weak border is a boundary problem.** The BE/NL/PL/SK/HU/CZ
   negative-evening-bias family is **Core-FBMC coupling**, not the GB
   boundary — GB treatment moved BE/NL evenings only 4–5%. That family needs
   the flow-based-domain story, not a virtual neighbor.
5. **A real product bug found: FR–GB flows are double-counted.** The `GB`
   flow code is the AGGREGATE of `GB_IFA` + `GB_IFA2` + `GB_ElecLink`; the
   loader sums all four ≈ 2× the true flow. The pure data fix reproduces
   ~80% of FR's July treatment effect — but shipping it alone costs FR +5.3
   July MAE because the double-count accidentally compensates a missing GB
   evening scarcity premium. Compensating errors: the fix ships PAIRED with
   the GB premium mechanism, never alone.
6. **Endogenize, don't model, where data exists**: AL / MK / ME / HR have DA
   prices, load & RES forecasts, unit registries and ATC in ENTSO-E — they
   belong in the footprint as real zones. Only TR / UA / GB / MT (no usable
   ENTSO-E presence) genuinely need behavioral books.

## The iteration plan (ordered, each with its gate)

| # | item | gate | status |
|---|---|---|---|
| 1 | **UA treatment, firm-slice refinement** — war-constrained scarcity buyer: firm cap-priced base slice + elastic tail (fixes the HU March breach) | re-pass the same 24-day A/B, no March breach | prototype ready (wave-2) |
| 2 | **DK1/Viking cherry-pick** — the GB arm's one clean winner (July eve −70.6→−48.4; March MAE 27.1→24.9, corr 0.60→0.83) | DK1-scoped confirm on both windows | candidate |
| 3 | **AL/MK/ME/HR endogenization** ("iteration-9") — real books from real data; extends the footprint to 43 zones | standard footprint gates + SEE guard | data inventory done |
| 4 | **TR fundamental anchor** — EPİAŞ/EXIST transparency ETL (MCP, load, generation; administered BOTAŞ gas pricing) | wave-1 A/B re-run, March guard clean | needs new ETL |
| 5 | **GB done right** — UK fundamentals feed (Elexon/BMRS + UKA carbon), daily GB SRMC anchor + evening scarcity premium, **paired with the FR–GB double-count fix** | BE/NL/FR/DK1 windows, March guard clean | needs new ETL |
| 6 | Core-FBMC family (BE/NL/PL/SK/HU/CZ evenings) | separate program — not a boundary problem | out of scope here |

Ship vehicle: items 1–2 are candidates for the next model cv after cv19;
items 3–5 are each their own cv with the full protocol (coupled A/B, guards,
backfill, Metabase). The `NET_IMPORT_EXCLUDE_EXTRA` / `BACKSTOP_EXCLUDE_EXTRA`
hooks (default-inert, byte-identical unused) are already in the experiment
branches and move to src/ with whichever item ships first.

## Standing rules (learned, non-negotiable)

- Coupled mechanisms are validated on the full coupled footprint from day
  one (the cv18 rule) — both waves ran 39-zone A/Bs throughout.
- Anchors from the neighbor's fundamentals, never fitted to prices, never a
  fixed multiple of our SRMC.
- Every treatment carries a stable-window guard next to its target window;
  a July win that costs March does not ship until the March cost is
  understood and fixed.
- Negative results (Mechanism B, the GB gate fail) stay in the record.
