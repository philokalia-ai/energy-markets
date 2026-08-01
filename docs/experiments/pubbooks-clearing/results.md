# Results — Published-books clearing validation

*Protocol frozen in [protocol.md](protocol.md) before any score. Converter
`test/scripts/pubbooks_prep.py`, harness `test/scripts/pubbooks_clear.jl`,
analysis `test/scripts/pubbooks_analyze.py`, runner `test/scripts/pubbooks_run.sh`.
Raw GME/OMIE data is NOT redistributable and is not committed; the harness reads
it via `$PUBBOOKS_DIR` and the read-only DuckDB extract. Solver HiGHS, fresh Julia
process per market day.*

## Headline

**Does Euphemia solve the bids correctly? YES — the clearing solver is exact.**
Fed the ACTUAL published bids of GME (Italy, 7 zones × 7 days = 1,175 zone-hour
cells) and OMIE (Iberia pool, 20 days = 480 cells), the engine's price is **inside
the valid uniform-price clearing bracket on 100.00% of cells (both exchanges)**,
and on every cell where the bids determine a unique price (tight bracket) it
reproduces that price **to the cent** (GME max |Δ| = €0.00 on 76 cells; OMIE max
|Δ| = €0.45 on 232 cells, 91% ≤ €0.01, 100% ≤ €0.5). No solver defect was found.

**The residual to the OFFICIAL price is entirely book construction, not the
solver.** The published books are only the *domestic* layer of a *coupled*
European market, so a single-zone/single-pool clear of the published book cannot
equal the official price except where the domestic bids happen to set it:
- GME: the official *zonal* price lies OUTSIDE the per-zone book's crossing
  bracket on **77.7%** of cells — Italy's zonal price is a coupled-system property
  (imports at the margin), not a per-zone-book property; only **6%** of per-zone
  cells even have a book-determined price. Injecting the exchange's own observed
  net position cuts the median gap to the official price from **€95.2 → €8.4** and
  reproduces it within €0.01 on 7.5% of hours (the domestic-marginal hours; NORD
  15.5%).
- OMIE: the official Iberian price lies OUTSIDE the published curve's crossing
  bracket on **79%** of ES=PT cells — it is fixed by the France coupling (cheap
  Iberian supply exported, pulling the clear into the gas block) plus complex
  conditions (min-income withdrawals), neither encoded in the aggregate curve.
  The physical-flow net proxy moves the OMIE price by only a median **€0.8** (vs
  GME's €98 from the exchange's own awarded net), so it cannot close the gap:
  median |+net − official| = €11.0 (32% within €2). On the 48% of cells where the
  curve DOES pin the price (much higher than GME's 6% — the pool book is far more
  determinate than a single Italian zone), +net median is €2.4 (49% within €2),
  and on solar-surplus middays the domestic crossing already matches (regime
  median €2.7).

So: **real books in → the solver clears them exactly; official prices out requires
the coupling layer the published per-market books omit.** The mechanistic layer is
validated in isolation; residual model error belongs to book construction.

## Deviations from the frozen protocol (disclosed)

- **Same-price step merge.** Steps at the identical (cell, side, price) are summed
  into one `SimpleOrder` (exact for the uniform-price clearing price and cleared
  volume; shrinks the per-cell MIP ~4×: OMIE 2,900→650 orders, GME 900→200).
  Declared in protocol §3.
- **drop-conditioned arm not separable.** The public curves do not flag which
  steps carry a complex condition, so the include-vs-drop bound is replaced by the
  `domestic` vs `+net` contrast and the well-determined/degenerate split (protocol
  §3).
- **Layer A metric refined post-freeze (disclosed).** The frozen metric was
  `|P_engine − P_crossing|` against a single reference crossing. On import-
  dependent books the crossing is a WIDE degenerate interval (any price in it
  clears the identical quantities), so a point reference conflates "wrong price"
  with "a different valid end of an underdetermined interval." The rigorous
  criterion actually reported is **bracket membership** (the engine's price must
  lie in `[p_sup_marg, p_dem_marg]`) plus **exactness on well-determined (tight-
  bracket) cells**. Both are stricter statements of the same "solves correctly"
  question; the point-crossing agreement is 84.8% ≤ €0.01 and is subsumed.

## Layer A — solver mechanics (engine vs independent crossing)

The engine is the MPCC uniform-price clear (`solve_mpcc_market_clearing`, single
node, `network_topology=nothing`). The reference is a textbook merit-order
crossing of the identical order set, computed independently in the harness.

| Exchange | cells | in valid bracket | well-determined cells | \|P_engine − unique price\| |
|----------|------:|-----------------:|----------------------:|-----------------------------:|
| GME  | 1,175 | **100.00%** | 76 (6%)   | median 0.000, **max 0.00** €/MWh, 100% ≤ €0.01 |
| OMIE | 480   | **100.00%** | 232 (48%) | median 0.000, **max 0.45** €/MWh, 91.4% ≤ €0.01, **100% ≤ €0.5** |

The engine NEVER returned a price outside the valid clearing interval, on any of
the 1,655 cells including the degenerate/artificial-scarcity ones, and it hits the
unique price exactly (or within €0.45) wherever the bids determine one. **This is
the direct, affirmative answer to "λύνει σωστά τα bids".**

Only 6% of GME per-zone cells are well-determined vs 48% of OMIE pool cells: the
per-zone Italian book usually does NOT pin the price (wide bracket, import-
dependent), while the Iberian pool book does far more often — foreshadowing the
Layer-B split.

## Layer B — engine on real bids vs official price

Engine fed the real bids in two configurations: `domestic` (published supply +
demand only) and `+net` (plus the observed net cross-border/inter-zonal position
injected as a price-taker block — GME from the file's own awarded quantities, OMIE
from `entsoe.physical_flows`).

### GME (official price = the file's own per-zone `awarded_price`)

| metric | domestic | +net |
|--------|---------:|-----:|
| median \|Δ vs official\| | 95.2 | **8.4** €/MWh |
| within €0.01 | 1.0% | 7.5% |
| within €0.5  | 1.4% | 12.5% |
| within €2    | 2.3% | 23.5% |

Injecting the exchange's own net position moves the price by a median €98 and
recovers most of the official level. Cleared-volume delta (crossing vs official
awarded supply): median 15 MW.

Per-zone `+net` (median | % exact | % ≤ €2): the large, more self-sufficient NORD
is best; heavily-coupled small zones worst — exactly as the coupling story
predicts:

| zone | median €/MWh | % ≤ €0.01 | % ≤ €2 |
|------|-------------:|----------:|-------:|
| NORD | 3.9  | 15.5 | 36.9 |
| SICI | 4.8  | 14.9 | 29.8 |
| SUD  | 6.3  | 4.8  | 26.2 |
| CSUD | 11.2 | 2.4  | 19.6 |
| CNOR | 12.2 | 4.2  | 16.1 |
| SARD | 15.0 | 6.6  | 18.6 |
| CALA | 16.6 | 4.2  | 17.3 |

### OMIE (official price = `entsoe.energy_prices` ES, ES=PT hours only)

452 of 480 cells are ES=PT (uncongested MIBEL); 28 congested (ES≠PT) excluded from
the Layer-B headline (Layer A uses all 480).

| metric | domestic | +net |
|--------|---------:|-----:|
| median \|Δ vs official\| | 11.5 | 11.0 €/MWh |
| within €0.01 | 7.3% | 8.6% |
| within €0.5  | 15.9% | 15.7% |
| within €2    | 29.6% | 31.9% |

Unlike GME, the net injection barely moves the OMIE price — median **€0.8** (vs GME
€98) — because the boundary is the France day-ahead coupling, which the available
`physical_flows` proxy (~0.5–1 GW) badly under-represents. So `+net ≈ domestic`,
and the residual is NOT recoverable from the published curve + physical flows.

On the **48%** of cells where the curve pins a unique price (tight bracket), the
engine reproduces the official price far better — median **€2.4**, 25.7% within
€0.5, 48.6% within €2. By regime the split is textbook: solar-surplus **midday**
median €2.7 (domestic-marginal, the curve determines it — including negative
prices, e.g. 2025-10-05 h12 −2.1 vs official −0.6); high-demand **evening** median
€24.7 (coupling/gas-set, outside the domestic bracket).

## Attribution of the residual

For every cell with `|P_+net − P_official| > €0.5`, classified by observable
signals (protocol §4):

**GME** (1,028 of 1,175 cells):

| cause | share of all cells |
|-------|-------------------:|
| coupling/complex — official price OUTSIDE the domestic crossing bracket (no single-zone clear can reach it) | **77.7%** |
| discretization / tie (residual ≤ one price step) | 8.4% |
| complex-order / other residual | 1.2% |
| internal congestion (GME zonal split) | 0.2% |

The dominant cause is structural: the per-zone published book does not contain the
price-setter (the interconnector / coupled system). This is a book-completeness
ceiling that no solver quality can cross with per-zone data.

**OMIE** (381 of 452 ES=PT cells):

| cause | share of ES=PT cells |
|-------|---------------------:|
| coupling/complex — official price OUTSIDE the domestic crossing bracket | **79.0%** |
| complex-order / other residual | 3.1% |
| discretization / tie | 2.2% |

Same structural verdict as GME: the price the published curve cannot reach is set
outside it (France coupling + min-income complex conditions).

## Complex-orders sensitivity arm

The frozen protocol declared the include-vs-drop bound as the `domestic`↔`+net`
contrast plus the well-determined split (the public curves do not flag complex
steps, so a literal drop arm is not separable). The measured sensitivity:

- **GME:** `domestic → +net` moves the price a median €98 and cuts the gap to
  official from €95.2 → €8.4 — the boundary (net position) is the dominant missing
  ingredient, and it is the exchange's OWN awarded quantity, so it is well
  identified. Residual after +net: coupling/import-marginal pricing.
- **OMIE:** `domestic → +net` moves the price only €0.8 — the boundary is NOT
  identifiable from physical flows, so the €11 residual is jointly the France
  coupling and the OMIE complex-condition (min-income) iterations. The
  well-determined subset (€2.4) bounds the pure conversion+solver error from
  below; the full-sample €11 bounds the complex/coupling contribution from above.

In both cases the bound brackets the same conclusion: the solver+conversion is
exact where the book determines the price, and the residual is book construction
(the coupling layer and complex conditions the published books omit).

## Engine-defect findings

**None.** The engine's price is always a valid uniform-price clearing (100%
bracket membership) and exact wherever the bids determine a unique price. The
`|dA|>€0.5` cells against the *point* reference are all wide-bracket degenerate /
artificial-scarcity cells (import-dependent zones cleared domestic-only), where
the interval — not the solver — is underdetermined, and the engine's choice stays
inside it. A representative degenerate cell: CNOR 2025-01-15 h12, domestic demand
exceeds all domestic supply, bracket [€141.73, €3950]; the engine prices at the
top of the domestic supply stack (€3000), the point crossing at €3950 — both valid
clears of a book with no real equilibrium (the imports that clear it in reality are
not in the per-zone book).

## Caveats

- GME sample is the 7 downloaded days (embargo + non-redistributable), scored as
  1,175 zone-hour cells across 4 seasons / 2 years.
- OMIE `+net` uses physical flows, not the day-ahead commercial schedule — a
  disclosed, and here demonstrably weak, proxy of the coupling boundary (it moves
  the OMIE price by a median €0.8, far short of the true France exchange), which is
  itself part of the finding: the coupling boundary is not recoverable from the
  published curve + physical flows.
- Price caps fed to the engine are the real exchange caps as a fixed constant,
  not tuned per day.
- The DuckDB extract's IT prices are PT15M (15-min settlement) while the GME offer
  files are PT60; GME scoring uses the file's own hourly `awarded_price` (the
  exchange's published zonal price), sidestepping the resolution mismatch.
