# GR strategic bidding — does market power explain the residual?

The model is a **competitive counterfactual**: the price if every unit offered at
short-run marginal cost. On many Greek days the settled price sits *above* that
counterfactual. This experiment asks the obvious question directly: **if the big
incumbents saw the counterfactual and bid a market-power strategy, would the
model reproduce the settled price?** If a plausible strategy closes the residual,
that residual is evidence of exercised market power; if none does, it is
something else (missing cost, network, a data gap).

This is a research probe, not a model change — nothing here bumps
`ENERGY_PRICES_CODE_VERSION` or writes to the product. It runs fully offline on
the DuckDB extract.

## Setup

- **Zone**: Greece. **Players**: the mapped firms in `simulations.unit_firms`.
  PPC (ΔΕΗ) alone is **~69 % of the mapped GR registry** (10.4 of 15.1 GW) and
  the dominant dispatchable owner; `EUPHEMIA_BIG_FIRMS` widens the set toward the
  ~80 % capacity ceiling (e.g. `"PPC,Mytilineos,Elpedison"`).
- **Days**: **60 medium-correlation days** (`days.json`), sampled evenly across
  2024-07…2026-06 from the 154 GR days whose competitive-baseline hourly
  correlation is in **0.6–0.8** — the regime where there is real shape to keep
  *and* real residual to explain. On this set the baseline sits **+12 €/MWh
  (median) below** settled: the candidate market-power signal.
- **Mechanism**: the first-class [`strategist` hook](../../scenario-api.md). It
  receives the fully tagged order book (`unit_code => firm` via `firm_of`) and
  returns a replacement book, so a strategy is a pure function of the competitive
  book. Counterfactual-aware strategies additionally capture the day's baseline
  clearing price (`get_baseline(day)`) — literally "the players see the
  counterfactual".
- **Metric**: paired per day against the *same-day* competitive baseline.
  A strategy works iff it **raises MAE gain (baseline MAE − strategy MAE) > 0
  against settled prices while holding correlation** — i.e. it moves the
  simulated price toward reality without destroying the shape. `resid` =
  mean(actual − sim): the baseline is strongly positive, so a good strategy
  drives it toward 0 without overshooting negative.

## The strategies (one file each — drop in your own the same way)

| file | idea | key params |
|---|---|---|
| `strat_uniform_markup.jl` | flat Lerner markup on all big-firm supply | `markup` |
| `strat_topslice_markup.jl` | mark up only the flexible upper tranches; base at cost | `markup`, `slice_from` |
| `strat_pivotal_markup.jl` | mark up only in hours where the firm is pivotal (RSI<1) | `markup`, `rsi_thresh` |
| `strat_counterfactual_bid.jl` | **see the counterfactual**: lift tranches up to `p₀·(1+headroom)` | `headroom`, `floor_frac` |
| `strat_withholding.jl` | economic withholding — drop the cheapest big-firm capacity | `w` |
| `strat_share_proportional.jl` | Cournot/Lerner markup = share/elasticity, per hour | `elasticity`, `cap` |
| `strat_peak_hour_markup.jl` | mark up only the top-k highest-load hours | `markup`, `topk` |

Each file exposes one factory `name(; params...) -> (day::Date -> strategist)`
and runs standalone (`julia --project=. .../strat_uniform_markup.jl` clears a
2-config demo). `common.jl` holds the harness: day selection, actuals, the
warm-cache day-outer runner, and the paired evaluation. `run_all.jl` runs the
full matrix (~19 configs × 60 days ≈ 20 min, one warm baseline pass) and writes
`results.tsv`.

## Running

```bash
julia --project=. docs/experiments/gr-strategic-bidding/run_all.jl
NDAYS=6 julia --project=. docs/experiments/gr-strategic-bidding/run_all.jl   # quick
EUPHEMIA_BIG_FIRMS="PPC,Mytilineos,Elpedison" julia ... run_all.jl           # ~80% cap
```

## Results

Full 60-day matrix, ranked by paired ΔMAE vs the same-day competitive baseline
(positive = the strategy moved simulated prices **toward** settled). Baseline:
**corr 0.72, MAE 31.96, resid +13.21 €/MWh** — settled sits €13 above the
competitive counterfactual on these days. `results.tsv` has the full table.

| strategy | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| **topslice 25%** | **0.76** | **28.81** | +6.36 | **+3.15** | **50/60** |
| topslice 40% | 0.77 | 28.90 | +3.39 | +3.06 | 45/60 |
| withhold 10% | 0.75 | 29.40 | +2.11 | +2.56 | 40/60 |
| uniform 10% | 0.74 | 31.22 | +7.47 | +0.74 | 41/60 |
| cf-bid 10% | 0.74 | 31.23 | +6.66 | +0.73 | 40/60 |
| uniform 20% | 0.75 | 31.43 | +2.34 | +0.53 | 36/60 |
| *baseline* | 0.72 | 31.96 | +13.21 | 0.00 | — |
| pivotal 30% | 0.75 | 33.56 | +2.79 | −1.60 | 22/60 |
| uniform 35% | 0.76 | 33.35 | −4.53 | −1.39 | 28/60 |
| withhold 20% | 0.75 | 34.05 | −10.39 | −2.09 | 29/60 |
| pivotal 80% | 0.76 | 42.47 | −12.11 | −10.51 | 12/60 |
| withhold 35% | 0.75 | 56.13 | −40.36 | −24.17 | 22/60 |

### Verdict — yes, partially, and it localizes to PPC

1. **A moderate top-slice markup is the single best explanation.** Marking up
   only the incumbent's *flexible upper tranches* (base/must-run left at cost)
   by **25–35 %** improves **50/60 days**, cuts MAE €31.96 → €28.8, closes about
   **half** the +€13 residual, and — the tell — **raises correlation 0.72 →
   0.76–0.77**. It doesn't just lift the level; it improves the hour-to-hour
   shape, because the residual lives in the tight hours where PPC's peaking
   tranches set the margin. The result is robust to *where* the slice is cut
   (`slice_from` 1.05/1.10/1.20 are identical — PPC's tranche structure has a
   clean gap between must-run and flexible).

2. **It is PPC-specific, not a whole-market effect.** Re-run with the big-firm
   set widened to **~80 % of capacity** (PPC + Mytilineos + Elpedison + Heron +
   Korinthos Power), the *same* markup **overshoots**: residual flips negative
   (−1.0), correlation *falls* (0.76 → 0.73). `withhold 8 %` lands resid at
   ~0 there but with worse shape. So the above-competitive price localizes to
   the **dominant incumbent's** flexible margin — the competitive fringe marking
   up the same way over-explains it.

3. **It is partial and bounded — this is not "the residual is all market
   power".** The best strategy leaves ~+€5–6 residual, and *aggressive* levers
   overshoot hard: uniform 35 %, pivotal ≥50 %, withhold ≥20 % all drive resid
   negative and MAE up (withhold 35 % is catastrophic — pulling a third of PPC's
   capacity manufactures scarcity spikes). The exercised markup the data
   supports is a **~25–35 % adder on PPC's flexible tranches**, nothing larger.

4. **Hour-targeting failed; tranche-targeting won.** The pivotal-hour and
   peak-hour strategies did *not* help (ΔMAE −1.0…−1.8). The signal is not a
   handful of pivotal spikes — it is a portfolio markup on the flexible tranches
   spread across the tight hours. The RSI proxy rarely flags pivotal here
   (fleet-completed supply + imports usually exceed load in the book), so that
   lever mostly misfired.

**Reading for the research programme.** On medium-correlation GR days the
persistent above-counterfactual residual is *consistent with* a moderate,
PPC-localized markup on flexible capacity — it improves both level and shape,
exactly where market power would bite, and only for the dominant firm. It is a
candidate market-power finding, not proof: a ~€5–6 residual remains, and the
same improvement could in principle come from an unmodeled cost on those same
peaking units. The natural next steps are unit-level (does the implied markup
concentrate on specific PPC CCGT/OCGT units?) and a placebo (does the same
top-slice markup on a *competitive* zone like DE_LU make things worse, as it
should?).

Numbers regenerate with `run_all.jl` (main matrix → `results.tsv`) and
`run_focus.jl` (fine sweep; set `EUPHEMIA_BIG_FIRMS` for the ~80 % pass).
