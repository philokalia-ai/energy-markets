# cv26 — hyperbolic scarcity tail: measured NO-SHIP

Run 2026-07-30 per the ratified `docs/cv26-scarcity-prereg.md` (#231). One
treatment: the scarcity term's quadratic replaced by
`κ_h·(θ−margin)/(margin−m₀)`, m₀ = 1.0 (capacity == demand), κ_h pinned by
continuity at the midpoint — implemented on `feat/cv26-scarcity` behind
`EUPHEMIA_DISABLE_CV26`, switch-off guard bit-identical to main (1032/1032).
Baseline arm = the Phase-4 `recal` cells (same clearing physics as merged main
— declared reuse). 14,976 scored cells, 16/16 ratified Set-A days, none
truncated.

## Verdict: FAIL — every falsifier fired

| arm | MAE | corr | evening (16–21 UTC) MAE | cap hours |
|---|---|---|---|---|
| cv25 | 33.44 | 0.602 | 47.65 | 2 |
| hyper | **89.87** | **0.320** | **142.93** | **296** |

- **294 new cap hours** across 18 zones (FI 66, RO 46, IT-CNORTH 45, …).
- **19 per-zone envelope breaches** (worst RO +311, IT-CNORTH +326, FI +490
  all-day MAE).
- **GR evening MAE worsens 68.7 → 132.0** — the named falsifier.

Set B was not scored (protocol: only on a Set-A pass).

## The structural finding (why the form is wrong, not just the parameter)

The book's effective margin — (dispatchable + import credit + backstop
credit) / net demand — routinely sits at **1.00–1.05 in tight evening hours**
across the footprint (FI essentially all day). A divergence anchored at
m₀ = 1.0 therefore lands ON the operating range: hours at margin 1.005–1.02
draw multipliers 3–12× and slam into the cap, which is exactly the measured
wreckage. Anchoring m₀ lower is no cure: with κ_h pinned by midpoint
continuity, m₀ ≤ 0.85 reproduces the quadratic to within a few percent over
the whole observed margin range — the hyperbola only differs from the
quadratic near its own asymptote.

The deeper diagnosis stands unchanged from the GR evening analysis: the
model's evening residual is a **moderate LEVEL under-bias (−35 to −48 €/MWh)
spread across many hours**, not a tail of near-cap spikes. A divergence form
can only add huge markups on the very tightest hours; it cannot add +40 to a
broad shoulder. Closing it needs a level/conduct mechanism (the
zone-diagnoses evening program), not a sharper scarcity curve.

## Disposition

- `feat/cv26-scarcity` stays UNMERGED (cv stays 25); the branch and this
  record are the experiment's artifact, cv18-style.
- The prereg's out-of-scope list (midday negatives, conduct residuals) is
  unchanged; the next evening candidate should be preregistered as a level
  mechanism on the coupled footprint.
- Raw cells: `scratchpad/p6/` (hyper), `scratchpad/p4/` (baseline); scorer
  `score_cv26.py`; transcript `cv26_scores_A.txt`.
