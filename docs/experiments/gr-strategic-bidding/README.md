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

> **Revision note (July 2026).** A full adversarial code review of the first
> version of this experiment found real flaws — a mislabeled winning strategy,
> a no-op parameter rung, selection-bias/winner's-curse exposure, an asymmetric
> evaluation metric on 15-minute days, and a stale-baseline Europe argument.
> Everything below reflects the **corrected instruments**; the changelog at the
> bottom lists what changed and why. The headline finding survived the review;
> its *mechanism* changed.

## Setup

- **Zone**: Greece. **Players**: the mapped firms in `simulations.unit_firms`.
  PPC (ΔΕΗ) alone is **~69 % of the mapped GR registry** (10.4 of 15.1 GW);
  `EUPHEMIA_BIG_FIRMS` widens the set (e.g. `"PPC,Mytilineos,Elpedison"`).
- **Days**: **60 medium-correlation days** (`days.json`), sampled evenly across
  2024-07…2026-06 from the 154 GR days whose competitive-baseline hourly
  correlation is in **0.6–0.8**; the remaining **94 band days**
  (`heldout_days.json`) are a held-out validation set that no parameter was
  tuned on. On the 60-day set the baseline sits **+13.2 €/MWh below** settled —
  the candidate market-power signal. (Because the days were *selected* for
  mediocre fit on a mostly-underpriced band, any upward perturbation gains MAE
  by construction — which is why every claim below is checked against the
  held-out set and an additive level-shift null.)
- **Mechanism**: the first-class [`strategist` hook](../../scenario-api.md). It
  receives the fully tagged order book (`unit_code => firm` via `firm_of`) and
  returns a replacement book. Counterfactual-aware strategies additionally
  capture the day's baseline clearing price (`get_baseline(day)`) — literally
  "the players see the counterfactual".
- **Metrics**: paired per day vs the same-day competitive baseline, hourly,
  with the sim **hour-averaged** before pairing (symmetric on 15-minute days).
  `resid` = mean(actual − sim). Correlations are means of per-day hourly
  correlations. Two nulls frame every result: the **additive level-shift null**
  (the best flat +c €/MWh on the same days — the strongest trivial competitor;
  it cannot change correlation) and the baseline itself.

## The strategies (one file each — drop in your own the same way)

| file | idea | key params |
|---|---|---|
| `strat_uniform_markup.jl` | flat markup on all big-firm supply | `markup` |
| `strat_topslice_markup.jl` | **two variants**: `topslice_markup` (true top slice — only tranches above the unit-hour's quantity-weighted median, i.e. >~1.05×SRMC) and `nearuniform_markup` (everything above the deep must-run block — what a running unit's whole dispatchable range would do) | `markup`, `slice_from` |
| `strat_pivotal_markup.jl` | mark up only when the firm is pivotal (RSI<1) | `markup`, `rsi_thresh` |
| `strat_counterfactual_bid.jl` | lift tranches near the competitive price p₀ up to `p₀·(1+headroom)` | `headroom`, `floor_frac` |
| `strat_withholding.jl` | economic withholding — drop the cheapest big-firm capacity | `w` |
| `strat_share_proportional.jl` | Cournot/Lerner markup = share/elasticity, per hour | `elasticity`, `cap` |
| `strat_peak_hour_markup.jl` | mark up only the top-k highest-load hours | `markup`, `topk` |
| `strat_tiered_markup.jl` | per-firm markup map (PPC vs fringe vs combined) | `markups`, `slice_from` |

Each file exposes a factory `name(; params...) -> (day::Date -> strategist)` and
runs standalone. `common.jl` holds the harness; `run_corrected.jl` is the
authoritative evaluation (main matrix + held-out + paired-coupled);
`run_all.jl` / `run_focus.jl` / `run_fringe_combined.jl` are the original
(pre-review) sweeps kept for provenance.

## Results (corrected instruments)

Main 60-day matrix (`results_corrected.tsv`), ranked by paired ΔMAE:

| strategy | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| **nearuniform 25%** | **0.76** | **28.59** | +6.36 | **+3.10** | **50/60** |
| withhold 10% | 0.76 | 29.13 | +2.11 | +2.56 | 40/60 |
| *additive null (+12.5 flat)* | *0.73* | *29.06* | *+0.71* | *+2.63* | — |
| uniform 20% | 0.75 | 31.23 | +2.34 | +0.46 | 35/60 |
| *baseline* | 0.73 | 31.69 | +13.21 | 0.00 | — |
| ts_true 15/25/35/50% | 0.73 | 31.8–31.9 | +12.1–12.4 | −0.1–−0.2 | ~9/60 |
| cfbid_fix 20% | 0.75 | 31.94 | **+0.10** | −0.25 | 36/60 |
| cfbid_fix 35% | 0.77 | 34.84 | −7.65 | −3.15 | 24/60 |

**Held-out validation (94 untouched band days, `results_heldout.tsv`):**

| strategy | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| **nearuniform 25%** | **0.75** | **29.82** | +3.45 | **+3.05** | **75/94** |
| *additive null (+11.25 flat)* | *0.72* | *30.86* | *+0.11* | *+2.00* | — |
| *baseline* | 0.72 | 32.86 | +11.36 | 0.00 | — |
| ts_true 25% | 0.72 | 33.27 | +10.16 | −0.41 | 13/94 |

### What the corrected experiment actually shows

1. **The effect is real and replicates.** The winning configuration — a **~25 %
   markup on the full dispatchable range of the incumbent's *running* units**
   (everything above the deep must-run block; idle units keep their entry
   tranche at cost) — transfers to the 94 held-out days essentially unchanged:
   **ΔMAE +3.05, better on 75/94 days, corr 0.72 → 0.75**. No winner's curse:
   nothing was tuned on these days.
2. **It beats the strongest trivial null, out of sample.** A post-hoc optimal
   flat level shift achieves +2.00 on the held-out set; the markup achieves
   **+3.05** *and* raises correlation, which no additive shift can do. About
   two-thirds of the raw MAE gain is level, one-third is genuine shape — the
   markup lands in the right hours. (Caveat kept from the review: most book
   perturbations on these days raise the daily-corr mean somewhat, so the corr
   gain alone is weak evidence; the *combination* — beats-null + corr + 75/94
   consistency — is the finding.)
3. **The mechanism is NOT peak-tranche sniping.** The literal "top slice" —
   marking up only tranches priced above ~1.05×SRMC — does **nothing**
   (ΔMAE ≈ −0.2 on both day sets): those expensive tranches are rarely
   marginal. What reproduces settled prices is marking up the **at-cost and
   below-cost mid-range** of committed units — the region that actually sets
   the price. The economically natural reading: *scheduled units bid their
   entire dispatchable range ~25 % above cost; reserve units stay competitive
   to get scheduled.* (The first version of this README mislabeled this
   configuration "top-slice" — see the changelog.)
4. **Firm attribution is weaker than first claimed.** A fringe-only markup
   (PPC at cost) achieves comparable consistency on the main set — the fit
   alone cannot cleanly attribute the markup to PPC vs the fringe; both sit at
   the flexible margin in the relevant hours. What the data *do* support:
   applying the markup to ~all of the market's flexible capacity at once
   (PPC + fringe at the same rate) **overshoots** — the exercised-markup
   "budget" the settled prices support is roughly one large portfolio's worth,
   however you attribute it.
5. **The residual is not fully explained.** ~+6 €/MWh remains on the 60-day
   set (+3.5 held-out) at the optimum, deeper markups saturate, and the
   fixed counterfactual-bid strategy can *center* the residual (resid +0.10 at
   headroom 20 %) but not reduce MAE — level-perfect, shape-neutral. The
   remaining gap points to unmodelled peaker costs / scarcity hours, not more
   markup.

### Robustness — import response (coupled 39-zone, paired days)

`run_coupled.jl` + `run_coupled_topslice_seq.jl` re-clear the winning
configuration on the full coupled footprint; `eval_coupled.py` evaluates, and
`run_corrected.jl` part C provides the single-zone comparison **on the same 24
days** (`coupled_days.json`; the earlier version juxtaposed mismatched subsets):

| (same 24 days) | corr | MAE | resid | ΔMAE | days↑ |
|---|---:|---:|---:|---:|---:|
| single-zone baseline | 0.73 | 34.45 | +19.10 | — | — |
| single-zone nearuniform 25% | 0.76 | 31.01 | +11.94 | **+3.44** | 23/24 |
| coupled baseline | 0.73 | 28.72 | +17.64 | — | — |
| coupled nearuniform 25% | 0.75 | 26.87 | +14.73 | **+1.85** | 22/24 |

Paired on identical days, endogenous imports absorb **(3.44 − 1.85)/3.44 ≈ 46 %**
of the markup's price impact — consistent with the ~57 % import relief measured
for demand shocks. The single-zone estimate is an upper bound; the direction and
day-consistency (22/24) survive coupling.

### Across zones (recomputed on the cv17 baseline)

The first version argued zone eligibility from cv16 residuals; cv17's import
fixes changed exactly the zones cited. Recomputed on `eu17_base` (cv17,
2023-07…2025-06, medium-corr band per zone): **GR +0.8, HU +8.5, BG −8.6,
RO −7.9, RS −7.1** — RO's −26 collapsed to −8 (it was mostly the cv16 phantom
scarcity), and GR's *band-average* coupled residual is ≈ 0. Two consequences:

- **The signal is regime-level, not zone-level.** GR's +13 residual is a
  property of the *selected* medium-fit days, not of the zone in aggregate. A
  transferable strategy must be **regime-gated** — markup only under an
  *ex-ante observable* tightness signal (scarcity margin, net-load percentile),
  not "always in zone X", and validated held-out exactly as here.
- **Wrong-signed zones remain wrong-signed** (BG/RO/RS ≈ −7…−9): there the
  model *over*prices and a markup worsens the fit; their residual is a model
  problem (imports/costs), not candidate market power. HU is the one other
  positive-residual zone, but 88 % of its capacity is unmapped in
  `unit_firms`. A genuine pan-European sweep needs firm maps beyond the five
  SEE zones — the natural next data step.

## Running

```bash
julia --project=. docs/experiments/gr-strategic-bidding/run_corrected.jl   # authoritative
julia --project=. docs/experiments/gr-strategic-bidding/run_all.jl         # original sweep (provenance)
python3 docs/experiments/gr-strategic-bidding/eval_coupled.py              # coupled juxtaposition
```

## Changelog — what the code review found and what changed

1. **"Top-slice" was mislabeled** (near-uniform on committed units: the deep
   must-run block at 0.05×SRMC made the slice threshold vacuous). Fixed
   `topslice_markup` to a quantity-weighted-median anchor; the original
   behavior is preserved honestly as `nearuniform_markup`. Re-running showed
   the true top slice does nothing and the near-uniform variant is the real
   winner — the headline *mechanism* changed from "flexible upper tranches" to
   "the running units' whole dispatchable range".
2. **`counterfactual_bid` was a provable no-op at headroom ≥ 0.33** (band floor
   anchored to target, not base) — `cf_bid_35% ≡ baseline` in the original
   table was an artifact. Fixed; the strategy now centers the residual but
   does not beat the null on MAE.
3. **Selection bias / winner's curse / missing null** — addressed with the
   94-day held-out set and the additive level-shift null; the winner survives
   both.
4. **15-minute days evaluated asymmetrically** — sim is now hour-averaged
   before pairing (changes headline MAE ~0.2–0.3).
5. **Coupled comparison was subset-mismatched** ("same 60 days" vs 24) — now
   paired on `coupled_days.json`; import relief restated as ~46 %.
6. **Europe argument used stale cv16 residuals** — recomputed on cv17
   (`eu17_base`); conclusion reframed regime-level.
7. **"PPC-specific" overclaim** — softened; fit cannot attribute between PPC
   and fringe (finding 4 above).
8. `eval_coupled.py` now filters `code_version` and aborts on duplicate
   generations under a label.
9. Known cosmetic debt: the coupled runners carry a hand-copy of the strategy
   closure (worker-serialization constraint); pivotal-RSI rarely fires by
   construction (fleet-completed supply + imports usually exceed load) — both
   documented, not fixed.
