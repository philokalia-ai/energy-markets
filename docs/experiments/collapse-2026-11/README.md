# Collapse probabilities and RES offers — November 2026 experiment

Two independent, experimental mechanisms. The RES ladder defaults off and the
probability tools produce labelled local artifacts. The forecast schema and
model version stay unchanged. This branch also carries the analyst's active
fleet-rescue correction as the shared baseline dependency described below.
The physical counterfactual remains a market model; the statistical probability
predicts the settled market and must not be interpreted as a competitive price.

## Budget and frozen choices

Six hours total. One physical candidate against cv42 on eight days, no parameter
search. Monthly expanding logistic origins 2026-09-14, 10-01 and 11-01; history
starts 2024-07-01, tests end 2026-11-13. Per-zone logistic regression, L2 `C=1`,
no class weights, 300 L-BFGS iterations, 0.5 decision threshold. No tuning on
test labels. A one-class training set uses a Laplace-smoothed constant.

The analyst's day set is 09-16, 09-20, 09-27, 10-06, 10-19, 11-02, 11-04,
11-13 (2026). November 9 is excluded because Spain's RES input is absent.
The four inner-loop inspection days are 09-20, 10-19, 11-04, 11-13.

## Physical mechanism

`EUPHEMIA_RES_OFFER_LADDER=1` replaces **only** the aggregated RES offer's
solar-regime gate with a two-tranche ladder:

| Generation share | Offer price | Interpretation |
|---|---:|---|
| `1 - supported_share` | 0 €/MWh | Near-zero variable cost; merchant or support suspended at negative prices |
| `supported_share` | `-support_eur_mwh` | A known per-MWh production incentive remains payable when prices are negative |

Supply MW is preserved. Thermal, hydro, must-run and demand bidding rules stay fixed; coupled prices and the second-pass anchors can still respond.
The flag defaults off. Supported shares default to **zero in every zone**;
set a zone explicitly with `EUPHEMIA_RES_SUPPORTED_SHARE_DE_LU=...` (hyphens
become underscores). `EUPHEMIA_RES_SUPPORT_EUR` defaults to 20 €/MWh. This is a
declared scenario parameter, not an estimate of a country's subsidy. The share
is a share of forecast generation, not of nameplate capacity, and must be
documented and fixed before issuance. Configuring a share does not implement
contract-specific multi-hour suspension rules.

The measured candidate uses zero supported shares everywhere: the smallest
change removing the artificial +1 €/MWh RES floor. We do not infer supported
shares from settled negative-price frequency. The extract has no contract/cohort
register, so a national support ladder with asserted official shares would be
unsupported. The existing six-zone solar gate still governs the other affected
blocks; this experiment changes RES alone and can reveal a thermal/hydro wall.
With zero supported shares it also replaces the gated negative RES offer with
zero; the existing negative must-run floor rule stays in place.

Sources consulted on 2026-11-14 (mechanism evidence, not calibration inputs):

- [Bundesnetzagentur / SMARD explanation](https://www.smard.de/page/en/topic-article/5892/15618/negative-electricity-prices): production-linked premia can justify negative offers; costs and technical restrictions can keep conventional plants operating. Its €30 example is from 2020, not a 2026 estimate.
- [German EEG §51](https://www.gesetze-im-internet.de/eeg_2014/__51.html): negative-price support suspension and exemptions; transition provisions mean current law alone does not identify all existing-cohort bidding incentives.
- [French CRE support contracts, 2024 tender annex §9.3](https://www.cre.fr/fileadmin/Documents/Appels_d_offres/2024/20241129_AO7_Cahier_des_charges__Annexe_4.pdf): remuneration is suspended in negative hours, with conditional non-production compensation.
- [Italian FER1 decree, GSE official copy](https://www.gse.it/documenti_site/Documenti%20GSE/Servizi%20per%20te/FER%20ELETTRICHE/NORMATIVE/DM%204%20luglio%202019%20-%20Incentivazione%20dell%E2%80%99energia%20elettrica%20prodotta%20dagli%20impianti.pdf): support is subject to zero/negative-price suspension rules; it does not establish a uniform negative bid for all Italian RES.
- [Spanish RD413/2014](https://www.boe.es/eli/es/rd/2014/06/06/413/con/20250625): investment and operating remuneration are distinct, so investment support cannot simply be converted into a negative €/MWh offer.

## Probability target and feature timing

Target: **hourly mean settled day-ahead price ≤ 0 €/MWh**. A negative
quarter-hour whose hourly mean is positive is not an event under this target.
Actuals follow the repository's resolution-aware policy: latest sequence per
zone/timestamp, then average subhours. All dates are Europe/Athens market days;
the output retains UTC hours, including the repeated hour at the DST transition.
Hourly means are rounded to eight decimal €/MWh places before classification:
decimal-price cancellations can otherwise leave a mathematical zero at ±10⁻¹⁸,
changing a ≤0 label with DuckDB's parallel reduction order. This is far below
the settlement price tick and makes the event definition reproducible.

| Feature | 06:30 UTC D−1 variant (`pregate_0630`) | ~10:00 D−1 variant (`gate_1000_latest_proxy`) |
|---|---|---|
| Hour, weekday, annual sine/cosine | Known before issuance | Same |
| Same-hour DA price and ≤0 indicator, lags 1 and 7 market days | Default: D−1 prices, already auctioned/published on D−2; `--settled-lag 2` retains D−2 conservative history | Same public price-history cutoff |
| Settled collapse frequency, 7 / 28 days | Window ends D−1, weighted by observed hours (D−2 in the conservative variant) | Same |
| D−1 load forecast | Only audited genuine-stamp era (delivery ≥2025-11-01) and stored update <06:30 issuance; otherwise D−2 same-hour forecast persistence if its stored update <issuance | Latest stored D−1 revision; **not proven available by 10:00** |
| Wind and solar | D−2 same-hour forecast persistence only; older row's last update must be <issuance and source delivery in genuine-stamp era | Latest D−1 forecast column; D−1-specific publication **unverifiable** |
| Load, solar/wind/RES share, residual-load share | From the accepted forecasts/persistence above; no actual D load or actual D RES | From latest D−1 forecast proxy |
| Weekend × RES share | Same accepted RES/load inputs | Same proxy inputs |
| Neighbour residual share and collapse frequency | Unweighted geographic/trading-neighbour means, under the same issuance contract; fixed topology | Same topology, proxy residuals |
| Counterfactual price / surplus at floor | **Excluded from fitted features**: no historical issued model/surplus series in extract | Same; published live model ≤0 is a held-out comparator only |
| ERA5 / retrospective weather | Excluded: `weather.cell_hourly` is ERA5 | Excluded |
| Weather `city_forecast_vintage` | Excluded: Greek cities only; run date is not a proven 06:30 issue timestamp | Excluded |

RES persistence is conservative: an older complete row last updated before
issuance demonstrably existed by issuance; a later update is rejected rather
than misread as the D−1 publication time. Pre-2025-11 physical values fail this
test and are missing. Missing features are imputed to **training-only** means
with explicit missing indicators. All-missing training columns are inactive.
Missing national wind or solar series are not asserted to be measured zero.
The 06:30 reader filters **raw rows before resolution selection and hourly
aggregation**, grouping coverage by local market day. Otherwise an unpublished
more-complete resolution could suppress an earlier available series, leaking
future coverage through missingness. Direct-load and D−2-persistence snapshots
have separate issuance cutoffs. A synthetic early-hourly/late-quarterly fixture
guards this ordering.

Per-zone scaling and fitting use only already-public DA price labels through
**origin D−1** by default. Those prices were auctioned on D−2 ([Nord Pool daily
process](https://www.nordpoolgroup.com/en/the-power-market/Day-ahead-market/)).
Features for later days can use their own already-public D−1 price history, but fitted
coefficients stay frozen until the next monthly origin. There are no random
splits, future labels, resampling or test-fit calibration. The settled-price
history is a latest-settled reconstruction, not an archive of initial auction-price
revisions. The labelled `--settled-lag 2` variant remains available and its
[frozen benchmark](conservative-lag2/results.md) is retained separately.

The gate-time proxy measures informational value of the D−1 forecast fields,
not an honest replay at the auction gate. The clearing experiment also uses
latest revisions; `ForecastContext` records availability problems but does
not rewind a source to an unavailable revision. Do not relabel either proxy
as an operational 06:30 result.

The physical runner puts **both arms** inside a fixed 10:00 issuance context.
This also applies the existing publication-latency cutoffs to recent-generation
statistics; it is not just a logging wrapper. D−1 forecast revisions still
cannot be reconstructed. Its absolute baseline should therefore not be pooled
with a legacy/no-context experiment; compare each treatment with its own
same-input baseline. Physical coverage is the selected UTC delivery days,
whereas the probability target uses complete Europe/Athens market days.

Both physical arms include the analyst's feed-anchored fleet rescue correction
(`ac0ab5bfe079`; same patch retained on this branch). Without it, missing Italian
per-unit telemetry removes roughly 40 GW from several September–November day
books. It is an upstream data correction, not part of the RES treatment.

## Reproduce

Python dependencies are isolated from the Julia market engine. Install the
versions in `requirements.txt` in a private venv. Pin heavy work to your assigned
cores (the sprint assigned collapse 36–51).

```bash
export EUPHEMIA_DATA_STORE=duckdb
export EUPHEMIA_DUCKDB_PATH=/path/to/euphemia-live-20261114.duckdb
export EUPHEMIA_DUCKDB_READONLY=true  # literal true, not 1
export EUPHEMIA_RESULTS_DB=/private/path/collapse.duckdb
export JULIA_DEPOT_PATH=/private/path/depot-collapse
export JULIA_NUM_THREADS=8
export EUPHEMIA_DUCKDB_THREADS=4
export EUPHEMIA_DUCKDB_MEMORY=8GB
export EUPHEMIA_DUCKDB_TEMP=/private/path/duckdb-tmp

taskset -c 36-43 julia +1.12 --project=. bin/collapse_clearing.jl
taskset -c 44-47 env OPENBLAS_NUM_THREADS=4 python bin/collapse_probability.py \
  --extract "$EUPHEMIA_DUCKDB_PATH" --output /private/path/probabilities \
  --live-dir /path/to/frozen/live-json
python -m unittest discover -s test -p test_collapse_probability.py
julia +1.12 --project=. test/test_res_offers.jl
```

The Python reader opens the source explicitly read-only; the Julia runner
refuses to load the engine unless `EUPHEMIA_DUCKDB_READONLY=true` and confirms
the library's read-only flag. All results go to labelled CSV/JSON artifacts,
not Postgres, R2 or source tables. Model artifacts store coefficients, train-only
scaling, feature order and monthly origins; inference is the exported
`predict_logistic(model, features)` function. Scores include pooled and per-zone
Brier, clipped log-loss (ε=10⁻⁶), AUC, recall, false-positive rate and reliability
bins; AUC/recall are null when undefined. Climatology is per-zone expanding
training frequency with Laplace smoothing. The live comparator is paired on the
same UTC zone-hours; timestamps after 06:30 are counted, not silently called
pre-gate forecasts.

Tomorrow's experimental output can be generated explicitly, without publishing:

```bash
python bin/predict_collapse.py --extract "$EUPHEMIA_DUCKDB_PATH" \
  --delivery 2026-11-15 --output /private/path/tomorrow
python bin/collapse_diagnostics.py --extract "$EUPHEMIA_DUCKDB_PATH" \
  --probability-dir /private/path/probabilities --live-dir /path/to/frozen/live-json \
  --output /private/path/diagnostics
```

The first command writes both hourly probabilities and a separately fitted
**any-hour-tomorrow ≤0** day-event probability per zone. The latter uses only
complete local market days (23/24/25 hours), with the minimum settled price as
its label. It fits the same fixed L2 logistic model on day-level summaries of
the accepted ex-ante features: mean/min/max of lagged prices, frequencies and
forecast shares, season and weekday. It does not multiply independent hourly
non-event probabilities. This prediction is statistical and experimental; it is
not sent to the live product.
The inference CLI refits at the requested as-of date using its then-known
history. Reported backtest scores use monthly frozen coefficients; they do
not measure a daily-retraining policy. The output records its generation time
and labels itself an offline as-of reconstruction. Metadata distinguishes the legal
training cutoff from the last observed training date, and counts available target
price-history/load/RES features, so an extract gap is visible.

Threshold diagnostics report 0.2 / 0.3 / 0.5, test-set maximum-F1 and test-set
matched-false-alarm operating points. The latter two are explicitly **oracle
descriptions of the ROC/precision-recall curve**, not thresholds deployable
from this test. A separate F1 threshold uses preceding-origin predictions on
the 28 days ending origin D−1 (D−2 in the conservative variant). An additional frozen 2026-08-16 origin supplies
the first pre-test calibration window; later origins use previously issued
held-forward predictions. No current test labels enter threshold selection.

## Results

[Probability results](results.md), [per-zone scores](probability-by-zone.csv),
[thresholds](thresholds.csv), [reliability](reliability.csv), and the
[timestamp-qualified leakage bound](stamp-bound.md) are complete. The 06:30
default uses already-public **D−1 price history**: hourly Brier is **0.00983** on
57,111 cells; directly fitted day-event Brier is **0.04693** on 2,377
complete zone-days. The stronger latest-D1 proxy is **not** verified at 10:00:
only 877 fully stamped cells survive, containing no collapse events.

The headline and CLI default are `--settled-lag 1`. Both issuance variants use
the same public price-history cutoff; this does not admit unissued load/RES.

| Forecast inputs / public price history | Hourly Brier | Hourly AUC | Day-event Brier | Day-event AUC |
|---|---:|---:|---:|---:|
| **06:30 / D−1 (default)** | **0.009827** | **0.95247** | **0.046930** | **0.89276** |
| 06:30 / D−2 (conservative) | 0.010485 | 0.93165 | 0.053149 | 0.84458 |
| Latest-D1 gate proxy / D−1 (unverified timing) | 0.007966 | 0.98307 | 0.035341 | 0.94965 |
| Latest-D1 gate proxy / D−2 (conservative history, unverified timing) | 0.008382 | 0.97857 | 0.038644 | 0.93535 |

The corrected-fleet physical matrix is complete: 16 full vectors, eight paired
UTC days, 7,486 matched cells per arm (two Sardinia actual hours absent). The
zero-cost RES candidate is **NO-SHIP as a default change**: MAE rises **55.7234→58.1904 €/MWh**,
while collapse detection changes from 1 TP / 1 FP to 46 TP / 20 FP out of 253
events. Excluding Italy, MAE rises 56.4224→58.9731. November 2 drives the level
regression (65.0088→85.3316 MAE; both arms hit time limits). Baseline/candidate
include 5,616/3,744 time-limit cells; same-cell final-wrapper-optimal evidence is
only 934 cells on September 20 (0→6 hits, no false alarms). Keep the RES flag off.
**Six of eight baseline days and four of eight RES days hit solver time limits
on old HiGHS** (HiGHS.jl 1.24.0 / native 1.15.0, Julia 1.12.7), so the MAE
verdict is **low confidence**, not a certified economic comparison.
The existing-log audit also finds an automatic `p95` fleet fallback on November
2's baseline only, which materially confounds that day's level difference.
Excluding it from the existing outputs leaves MAE 54.3966→54.3119 over 6,550
cells. This diagnostic slice is not another arm or an independent test.

Blocks' independent RES-only arm on September 27 + November 2, using its
Italy + in-merit base, reports MAE Δ **−0.01 €/MWh**, hits **1→10**, false
alarms **1→13** (`em-team/reports/blocks.md`, 20:55 UTC;
[archived excerpt](independent-res.md)). Its legacy/no-context inputs differ
from this context-bound matrix; these are two separate measurements. They
support retaining the current default while leaving the mechanism verdict open.
Their later seven-day relay excludes cap/floor cells: 6,523 cells, MAE Δ+0.30,
hits 1→27, false alarms 1→16; one September 20 RES incumbent priced all zones
at the 3000 cap. Our retained per-period log audit instead shows 20→16
nonoptimal outcomes across 384 periods/arm and mean engine solve time
19.34→18.57 seconds/period, so it does not show an aggregate RES slowdown.
Individual native HiGHS timings were not logged; exact tail comparisons remain
unavailable. No further arms were run.
Full [physical tables](results.md#physical-price-ablation),
[per-zone scores](clearing-by-zone.csv) and [run timings/status](clearing-runs.csv)
are retained. The team report is `em-team/reports/collapse.md`.

The physical scorer uses only complete paired day/arm price vectors. It includes
full returned time-limit incumbents explicitly, counts those cells separately,
and also reports a final-wrapper-optimal subset. Neither the incumbent scores
nor a final optimal status certify an earlier anchor pass. Per-run wall time
and both pass solve times come from the logs: the engine's `solve_time` field
alone is **only the final pass**, not the full day's solver cost.

`bin/report_collapse.py --probability-dir ... --diagnostics-dir ... --output ...`
renders the frozen evaluation artifacts into the CSVs and Markdown tables.
Primary artifacts are labelled `collapse-probability-primary`,
`collapse-diagnostics-primary` and `collapse-tomorrow-priceL1` in team results.
The earlier `*-final` D−2 artifacts are the labelled conservative benchmark.
Raw-floating-point / pre-snapshot artifacts remain superseded diagnostics.
