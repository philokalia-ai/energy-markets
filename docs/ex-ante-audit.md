# Ex-ante audit — is every book input knowable at the D-1 auction?

Iteration 6. The counterfactual clears tomorrow's day-ahead auction, so every
input must be knowable **at D-1 noon** ("would we have this to predict
tomorrow's prices?"). This audit walks every query the merit-order / multi-zone
path issues, classifies each input as D-1-legal or a forward-looking leak, and
measures the accuracy cost of removing the one leak we found.

## Method

Grepped every SQL query in `src/MeritOrderBook.jl`, `src/Network.jl`,
`src/Loads.jl`, `src/Renewables.jl`, `src/Generators.jl` for its date window,
and classified each by whether the data it reads exists at D-1.

## Findings — one leak, everything else legal

| Input | Table | Window | Verdict |
|---|---|---|---|
| Load | `day_ahead_total_load_forecast` | target day | **legal** — DA forecast, published D-1 |
| Wind/solar | `generation_forecasts_for_wind_and_solar` | target day | **legal** — DA forecast, published D-1 |
| Cross-border ATC | `offered_transfer_capacities_implicit` / `_explicit` | target day | **legal** — offered capacities, published D-1 |
| Gas / carbon | `yfinance.ttf_f` / `eua_co2` | last close **before** the day | **legal** — prior close, no lookahead |
| Reservoir dryness | `aggregated_hydro_storage_filling_rate` | weeks **strictly before** the day; prior-year norm | **legal** |
| Reservoir drawdown (iter6) | same table | latest week before + trailing-52-wk max, all **before** the day | **legal** (built ex-ante by design) |
| Fleet / outages | `production_and_generation_units`, `unavailability_*` | as-of the day; outages known D-1 | **legal** |
| Type p95 / hydro availability / recent-gen | `actual_generation_output*` | `>= day-N` and **`< day`** (strictly before) | **legal** — verified upper bound is `< day::date` |
| **Cross-border physical flows** | **`entsoe.physical_flows`** | **the target day itself** | **LEAK (D-0)** |
| Day-ahead prices | `entsoe.energy_prices` | — | only used for **scoring**, never in the book |

**The single leak** is `MeritOrderBook._net_imports_day_relation(day)`, which
reads the *realized* hourly cross-border flows of the target day. Those flows are
the physical outcome of tomorrow's auction — not knowable at D-1. They feed three
book mechanisms:

1. **Non-endogenous border net-import injections** — observed net flow offered as
   €1 price-taking supply / firm demand for borders with no in-set ATC link
   (`get_net_imports`).
2. **Dropped flow-based borders' import-only clamp** — `GREATEST(flow, 0)` supply
   for borders removed from the endogenous network (Nordic, HU–AT/SK, BE Core,
   SE-internal, and now CZ–SK/PL–SK).
3. **Dropped borders' ref-priced exports** — `get_dropped_border_exports`, the
   demand mirror for anchored exporters (NO5, BE, SK).

Every other input is a day-ahead forecast, an offered capacity, a prior close, or
a strictly-before-the-day historical aggregate.

## The `as_of` mechanism (gated, default byte-identical)

`FLOW_ASOF_LAG` (Ref, env `EUPHEMIA_FLOW_ASOF_LAG`, setter
`set_flow_asof_lag!(n)`) shifts the physical-flow read back `n` days:

- `0` (default) — same-day flows; **byte-identical** to the D-0 product. The
  committed counterfactual is unchanged.
- `2` — D-2 flows (recent level, wrong weekday).
- `7` — D-7 same-weekday flows (preserves the weekly hour-of-day shape).

The hour-of-day grouping is preserved, so the lagged day's hourly profile maps
directly onto the target day's hours; the cache keys on the queried day.

## Measured cost on the frozen 36-day sample (39-zone, v1.1 extract)

`D-0` is the committed product; `D-7` replaces same-day flows with the same
weekday one week earlier. (Numbers below: final-code run; see
`iter6_results/exante_d7_final.csv`.)

**Aggregate (39 zones):** mean MAE **45.4 → 50.7** (+5.3), mean corr
**0.513 → 0.50** (−0.01), mean bias **+14.6 → +21.1**.

**Zones that lose ≥ 6 MAE under D-7** (the cost is concentrated here):

| zone | ΔMAE | Δbias | Δcorr |
|---|---:|---:|---:|
| NO2 | +34.1 | +37.3 | −0.11 |
| DK1 | +32.4 | +37.7 | +0.00 |
| HU | +23.1 | +26.3 | −0.22 |
| DE_LU | +20.5 | +20.7 | +0.01 |
| BG | +13.3 | +14.7 | −0.29 |
| RS | +13.1 | +14.6 | −0.26 |
| DK2 | +12.3 | +15.1 | −0.00 |
| CZ | +12.1 | +11.8 | +0.02 |
| RO | +9.8 | +11.2 | +0.01 |
| SE3 | +8.2 | +11.5 | −0.05 |
| AT | +7.3 | +8.0 | +0.01 |
| **GR** | **+7.3** | **+8.3** | **−0.33** |
| EE | +6.6 | +10.9 | +0.01 |
| LT | +6.4 | +10.3 | +0.01 |
| FI | +6.0 | +12.0 | −0.09 |
| SE4 | +6.0 | +8.3 | −0.02 |

**Zones that *improve* under D-7:** NO1 (−26.2 MAE), SI (−14.0) — their D-0
observed injection was itself noisy, so a lagged flow is closer.

The GR correlation collapse (0.83 → 0.50) is the headline: GR's own borders are
mostly endogenous, so the hit propagates entirely through the coupled solve from
its neighbours' shifted observed injections. The cost exceeds the "small" bar
(< 5 MAE / < 0.03 corr) for ~15 of 39 zones — it is **not** negligible.

**D-2 variant** (recent level, *wrong weekday*): mean MAE **45.4 → 59.2**
(+13.8), mean bias +14.6 → +30.0 — markedly worse than D-7. Scrambling the
weekday (a Tuesday's flows dropped onto a Sunday) hurts more than the two-day-
older level helps. **D-7 same-weekday is the better forward lag**; the ordering
is D-0 (45.4) < D-7 (50.7) < D-2 (59.2).

**Read:** same-day observed flows are **load-bearing for accuracy**, and unevenly
so. The aggregate cost of D-7 is modest (mean MAE +~5, mean corr −~0.02), but it
is concentrated: the flows carry cross-border signal that propagates through the
whole coupled solve, so even zones whose own borders are endogenous move. The
well-calibrated SEE core and several continental zones lose the most (GR
correlation collapses), while a few starved/dropped-border zones (NO1, SI)
actually *improve* under D-7 — a sign their D-0 observed injection was itself
noisy.

## Recommendation

- **Keep D-0 as the default for the analytical counterfactual.** The product is a
  *backward-looking* competitive counterfactual over historical days — for that
  use the realized flows are legitimately "known", and they materially sharpen
  the coupled solution. This is the committed, byte-identical default.
- **For a true forward (D-1 predictive) product**, the same-day flows are not
  available and the D-lag cost must be paid. D-7 (same-weekday) is the better
  lag (preserves the daily shape). The exposed zones to flag are the
  dropped-border / non-endogenous-injection ones — Nordic (NO*), HU, BE,
  SE3/SE4, FI, and now SK — plus the SEE core, whose apparent skill partly rests
  on the observed injection.
- **Do not flip the default** here — this audit measures and documents the cost;
  the product owner chooses per use-case. A proper forward product would replace
  the naive D-lag with a genuine flow forecast (its own model), which is out of
  scope for iteration 6.
