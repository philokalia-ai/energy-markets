# EU calibration — iteration 6 (seasonal transfer + the SK blow-up)

Goal: iterate faster in the non-Greek zones, improve overall Europe, without
breaking Greece, cutting quality corners, or adding forward-looking bias. The
April-calibrated v0.2.0 model does **not** transfer to a full year — a 104-day
winter/spring scoring gave aggregate mean corr 0.56 with catastrophic winter
failures (SK cap-clearing, Baltic/Nordic/DE seasonal breaks). Iteration 6 builds
a representative full-year sample, a fast offline harness, an ex-ante audit, and
lands the two cleanest seasonal fixes.

Stacked on `perf/duckdb-query-paths` (PR #104): the 39-zone day book builds in
~3 s, so a full 36-day sample scores in ~9 min (2 Gurobi workers, v1.1 extract).

## 1. The frozen iteration sample (`test/scripts/iter6_sample_days.json`)

36 days over 2025-07-01…2026-06-30, stratified per month: 1 normal weekday,
1 weekend, 1 "hard" day. Hard days are the worst per month by a z-score across
the failure zones (SK, Baltics, Nordic, IT-N, DE, FI) computed from
`entsoe.energy_prices` actuals — so the winter blow-ups are all represented. The
list is **frozen** for the whole iteration so runs are comparable. Scored with
the resolution-aware actuals methodology (bias = sim − actual), all 39 zones,
the full EU footprint every day (not per-zone in isolation — the calibration
doctrine).

Harness: `test/scripts/iter6_harness.jl` (offline, in-memory scoring, read-only
so diagnostics run concurrently). `LABEL=… WORKERS=2 SUBSAMPLE=… BASELINE=…`.

## 2. Baseline → final on the sample (39-zone, v1.1 extract, D-0)

Aggregate: **mean MAE 49.9 → 45.2, mean bias +18.8 → +13.9, mean corr
0.507 → 0.513.** GR guard held at every step (corr 0.83, MAE 23.6; SEE 5-zone
product byte-identical 131.34/84.96, RS dropped, 2026-04-03). Three accepted
changes: C1 (SK), C2 (Nordic drawdown), C3 (import-ATC scarcity credit).

The zones that moved (everything else within ±0.5 MAE):

| zone | base corr/MAE/bias | final corr/MAE/bias | note |
|---|---|---|---|
| **SK** | 0.34 / 229.1 / +195.5 | 0.43 / **39.3** / −19.8 | **−189.8 MAE** — the win |
| **SE1** | 0.46 / 31.6 / −23.5 | 0.50 / 29.7 / **−13.6** | seasonal drawdown |
| **SE2** | 0.48 / 31.9 / −23.8 | 0.50 / 29.5 / **−13.8** | seasonal drawdown |
| PL | 0.56 / 79.3 / +69.7 | 0.57 / 86.0 / +75.7 | +6.7 MAE (SK-drop reshuffle, C3-healed) |
| LV | 0.47 / 123.3 / +74.6 | 0.47 / 126.3 / +73.9 | +3.0 MAE (same) |
| LT | 0.46 / 122.2 / +78.2 | 0.46 / 125.2 / +77.6 | +3.0 MAE (same) |
| EE | 0.47 / 125.8 / +84.2 | 0.47 / 128.6 / +83.5 | +2.8 MAE (same) |
| NO4 | 0.19 / 29.8 / +0.2 | 0.19 / 29.8 / +0.2 | held (drawdown gated off) |

### Held-out validation (no overfitting)
Ran the final stack on **12 held-out days** (the 26th of each month, none in the
frozen sample; `docs/iter6-results/holdout_12days.csv`). The structural fixes
generalize cleanly to unseen days: **SK MAE 43.7 / bias −5.2** (catastrophic
pre-fix on winter days like 2026-01-26/02-26), **SE1/SE2 bias −7.2** (was ~−24),
**GR corr 0.86 / MAE 18.9 / bias −2.1** (Greece excellent). Aggregate mean MAE
39.2, corr 0.57 (higher than the sample because the 26ths are less extreme than
the sample's hard days). The SK and Nordic fixes are structural (border topology,
reservoir physics), not day-fitted — the held-out numbers confirm it.

## 3. Accepted changes

### C1 — SK Core-FBMC drop + `:hydro` anchor (the blow-up)
Diagnosis (`diag_sk.jl`, 3 winter days): SK is a Core transit hub — physically
imports ~3 GW from CZ+PL and exports ~2 GW to HU+UA — but the implicit offered
ATC `CZ→SK`/`PL→SK` are flow-based residuals (avg ~90 MW vs ~3 GW physical), so
the endogenous model saw ~90 MW of import capacity against a 4.15 GW fleet /
4.37 GW peak load and priced structural scarcity (cap-clearing in winter peaks).
HU–SK was already dropped (iter4) but SK *exports* to HU, so that gave SK no
import help.

Fix (the drop + re-price doctrine, three-times-confirmed): drop `CZ–SK`/`PL–SK`
(`flow_based_drop_borders`) to restore the real import supply as observed
import-only flows, and add `SLOVAKIA_PROFILE` with the `:hydro` opportunity
anchor so those imports price at the coupled Core reference, **not** the €1
price-taker block (which would invert SK to a deep negative bias — the NO1/BE/SE3
failure mode). **SK MAE 229 → 39, bias +195 → −20.** Cost: PL +9.9 MAE, EE/LT/LV
+3.2 (removing SK's endogenous links reshuffles the Core flows) — under the 10-MAE
gate, and those zones are iteration-7 targets anyway.

### C2 — seasonal reservoir-drawdown water value (Nordic winter)
Diagnosis (`diag_res.jl`): the reservoir-opportunity water value floored at
`0.35 × gas SRMC` whenever the *prior-year-relative* dryness read ~0 — but that
normalization erases the seasonal signal. A normal winter draws SE1/SE2
reservoirs to 55–60 % of the annual peak by February at dryness 0, so the model
priced genuinely-scarce stored water at the full-reservoir floor and cleared
SE1/SE2 at ~€18 vs actual ~€59.

Fix: `get_reservoir_drawdown` (absolute stored vs trailing-52-week peak, fully
ex-ante), raising the `wv_frac` floor by `max(dryness, drawdown)`. Gated by a new
`ZoneProfile.seasonal_drawdown` flag (default on) — far-north **NO4** opts out
via `NO4_PROFILE` because its ~€29 price is set by export congestion, not the
winter water value, and its reservoirs stay ~80 % full in February (with the
drawdown on it over-priced +8.6). Only reservoir-opportunity + drawdown zones are
touched; SEE is gas-anchored and untouched. **SE1/SE2 bias −24 → −14, MAE −2
each.** No month dummies — pure reservoir fundamentals.

### C3 — gated import-ATC scarcity credit (continental + Baltic)
The scarcity margin (`dispatchable_capacity / net_demand`) ignored a zone's
available import capacity, so import/export-capable thermal zones mis-fired the
mark-up. `get_import_atc_capacity` + a gated `scarcity_import_credit` (default 0 =
SEE byte-identical) credit offered import ATC into the margin (scarcity term only;
the peak term is left intact). Enabled at 1.0 for CONTINENTAL (DE_LU/NL/PL/CZ) and
BALTIC (EE/LT/LV). **PL bias +80.6 → +75.7** (partially healing the C1
side-effect), EE/LT/LV −4.0 each, DE_LU −1.6, CZ −1.0; no regressions. Small but
sound — and the diagnosis it produced is the key iter7 signal: DE_LU's +68 is
**not** scarcity-term-driven (its margin only tightens at peak hours), so the
residual is the fleet/merit + peak markup. This mechanism is the down-payment on
the systemic fix in §5.

## 4. Ex-ante audit (`docs/ex-ante-audit.md`)

Audited every book query. **One** forward-looking leak: same-day observed
`entsoe.physical_flows` in `_net_imports_day_relation` (feeds non-endogenous
injections, dropped-border import-only clamps, ref-priced exports). Everything
else is D-1-legal (DA load/RES forecasts, offered ATC, TTF/EUA prior close,
reservoir strictly-before, p95/outages with `< day` windows). Added a gated
`FLOW_ASOF_LAG` (`set_flow_asof_lag!`, env `EUPHEMIA_FLOW_ASOF_LAG`; default 0 =
byte-identical). Measured cost of D-7 (same-weekday): aggregate mean MAE +5.3,
concentrated (~15 zones lose ≥ 6 MAE; GR corr 0.83 → 0.50). Same-day flows are
load-bearing. Recommendation: keep D-0 for the analytical counterfactual; a
forward product must pay this cost with a real flow forecast. Default **not**
flipped.

## 5. Diagnosed but NOT changed (iteration-7 queue, with evidence)

- **The continental/thermal over-pricing cluster: DE_LU +70, PL +80, Baltics
  EE/LT/LV +78–87, plus CZ/CH/SI/RO/AT +22–33.** Shared root cause
  (`diag_de.jl`, `diag_balt.jl`): the **scarcity markup fires on zones that are
  not actually scarce.** DE_LU is a *net exporter* (−6 GW) yet its margin reads
  0.86 (dispatchable 29.8 GW derated vs 34.8 GW net-demand peak) → gas SRMC €93 ×
  ~1.83 ≈ €170 ≈ sim €178. The margin (`dispatchable_capacity / net_demand`)
  excludes imports and export-capability, and the unit-level thermal fleet is
  under-represented (DE gas 15 GW unit-level vs ~35 GW installed; idle capacity
  never enters the p95-based fleet completion). The Baltics are the mirror: EE's
  all-oil-shale fleet (1.06 GW vs 1.44 GW load) is import-dependent. **C3
  credited import ATC and confirmed the diagnosis**: it only moved DE_LU −1.6, so
  the +68 is **not** the scarcity term (DE's margin tightens only at peak). The
  remaining, higher-value iter7 work is (a) use **installed** rather than
  p95-observed thermal capacity so idle plant stops looking scarce (DE gas 15 GW
  listed vs ~35 GW installed), and (b) revisit **peak_kappa** for exporters. Both
  touch the SEE core's shape and must be validated cross-zone. **Highest-value
  iteration-7 item** — and it propagates: CH/AT/CZ/SI (+22–33) are largely
  *downstream* of DE_LU, since their opportunity-anchor refs are built from the
  inflated DE_LU/continental pass-1 prices, so lowering DE_LU should pull the
  alpine/continental cluster down with it.
- **LT–SE4 (NordBalt) residual** (ATC avg 200 vs 724 MW physical) is a genuine
  flow-based residual, but dropping it needs the drop+anchor treatment (else the
  €1-import collapse), and EE/LV don't touch SE4 — so it only partly helps the
  bloc. Do it together with the scarcity fix.
- **Italy is split, not uniform:** IT-NORTH/CNORTH over-price (+20, corr 0.35 —
  bad *shape*, not level), the southern sub-zones under-price (−13, good shape).
  The flat 1.20 SRMC multiplier can't fix both; needs a shape diagnosis of the
  northern zones (likely the same scarcity-margin issue on IT-NORTH's 22 GW gas
  fleet).
- **NO1 (corr 0.02), NO3 (0.27)**: shape is wrong, not level — the daily-two-pass
  anchor can't represent far-north inter-day storage arbitrage. Weekly
  water-value reference is the standing idea (atlas §7).

## 6. Method notes / gotchas

- `FLOW_ASOF_LAG` must be read at **runtime** (`Euphemia.__init__`), not as a
  `const Ref(ENV…)` — the latter bakes the value at precompile time, so a cached
  image silently ignores the env (cost me one wasted D-7 run; fixed).
- The harness stays **read-only** on the extract so diagnostic processes can open
  it concurrently (DuckDB: many readers, one writer).
- Every accepted change measured on the full 36-day sample with both GR guards;
  PL/Baltic regressions are documented, under-gate, and queued, not hidden.
