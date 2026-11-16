# #431 saved-file benchmark results

All prices/errors are EUR/MWh; ratios/shares are fractions. Primary tables use complete paired Athens zone-days and the site's equal-zone-day mean estimator. Each saved line is compared with the weekday naive on **its own paired mask**. Rows with different masks do not rank models against each other; source publication classes remain those in the manifests. Both targets are shown explicitly.

The [three-naive table](primary-three-naives.csv) gives D−1/D−7/weekday comparisons with each denominator and n. All per-zone, per-lead, both-aggregation and partial-cell outputs are in the six contract directories. Leads2–7 emit D−7 only. The [mask index](mask-index.csv) pins every paired cohort; `all_models` is a separate optional cohort, demonstrated on Timestral.

## live_saved

| Target | Saved line | n | Dates | MAE | Bias | EPF MAE | rMAE EPF | Mean price | MAE/mean | Share≤0 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| highest_seq | gbm_overlay | 19560 | 21 | 64.5176 | -27.082 | 44.3231 | 1.45562 | 144.864 | 0.445367 | 0.0206544 |
| highest_seq | physics | 54231 | 58 | 81.5486 | -51.1927 | 47.0189 | 1.73438 | 174.664 | 0.466888 | 0.0130447 |
| highest_seq | stats_overlay | 11712 | 14 | 46.907 | -5.02594 | 48.935 | 0.958559 | 144.767 | 0.324016 | 0.0198941 |
| sdac | gbm_overlay | 19560 | 21 | 64.7245 | -27.0289 | 44.923 | 1.44079 | 144.811 | 0.446959 | 0.0209611 |
| sdac | physics | 54231 | 58 | 81.6616 | -51.218 | 47.3136 | 1.72597 | 174.69 | 0.467467 | 0.0131045 |
| sdac | stats_overlay | 11712 | 14 | 47.232 | -4.95946 | 49.7485 | 0.949416 | 144.701 | 0.326411 | 0.0204918 |

Window: 2026-09-14..11-13. GBM/stats are reconstructed overlays with missing independent issuance/fit metadata; especially higher-lead values are not authenticated multi-day forecasts. Their much smaller masks cannot be used to rank them directly against all-cell physics. No 06:30 publication claim is inferred.

## live_since_cv43

| Target | Saved line | n | Dates | MAE | Bias | EPF MAE | rMAE EPF | Mean price | MAE/mean | Share≤0 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| highest_seq | physics | 1872 | 2 | 42.6618 | -19.2519 | 78.9716 | 0.540217 | 183.37 | 0.232655 | 0.00534188 |
| sdac | physics | 0 | 0 | — | — | — | — | — | — | — |

Only two complete highest-sequence lead1 dates, November16/17, mixed cv43/44. November17's DA prices were already in the fetched public snapshot; physical delivery need not be complete for a settled DA-price target. The older raw extract supplies only39 partial SDAC cells (one hour per zone), so **zero complete SDAC zone-days** are scored. Their secondary partial-cell MAE below is not a comparable two-day estimate. Both DM cohorts are insufficient data; no new-cv generalization claim.

## timestral_ontime

| Target | Saved line | n | Dates | MAE | Bias | EPF MAE | rMAE EPF | Mean price | MAE/mean | Share≤0 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| highest_seq | physics | 47631 | 51 | 81.7442 | -49.0425 | 48.203 | 1.69583 | 176.061 | 0.464295 | 0.0133829 |
| highest_seq | timestral_0630_prices | 47631 | 51 | 28.2319 | -3.45759 | 48.203 | 0.585688 | 176.061 | 0.160353 | 0.0133829 |
| highest_seq | timestral_postsim | 47631 | 51 | 25.2817 | -2.68484 | 48.203 | 0.524484 | 176.061 | 0.143596 | 0.0133829 |
| highest_seq | timestral_prices_matched_context | 47631 | 51 | 28.8396 | -3.63571 | 48.203 | 0.598293 | 176.061 | 0.163804 | 0.0133829 |
| sdac | physics | 47631 | 51 | 81.8692 | -49.0711 | 48.5214 | 1.68728 | 176.09 | 0.464929 | 0.013451 |
| sdac | timestral_0630_prices | 47631 | 51 | 28.4885 | -3.48617 | 48.5214 | 0.587133 | 176.09 | 0.161784 | 0.013451 |
| sdac | timestral_postsim | 47631 | 51 | 25.4916 | -2.71342 | 48.5214 | 0.525368 | 176.09 | 0.144765 | 0.013451 |
| sdac | timestral_prices_matched_context | 47631 | 51 | 29.0868 | -3.66429 | 48.5214 | 0.599464 | 176.09 | 0.165182 | 0.013451 |

Saved physics provenance in the eligible original cohort: 936 cv39, 36,447 cv40, 10,296 cv42. The physics model and post-sim base share these versions; prices-only models have no physics base. These counts precede target-policy and complete-zone-day restrictions.

The original on-time cohort has exactly47,679 paired cells. Highest-sequence all-paired MAE is25.2647108 for post-sim versus28.8190692 for its matched-context prices-only control; replay is exact. Complete paired zone-days leave47,631 cells, hence slightly different primary estimates. The SDAC retarget also changes the targets, while saved model contexts stay unchanged. On-time refers to the physics-input cutoff, not authenticated first public release.

## Secondary: all paired cells, pooled estimator

Partial zone-days and DST hours are retained here. Mean-daily values on this same partial cohort are also present in headlines.csv, so estimator and coverage changes can be separated.

| Window | Target | Saved line | n | Dates | MAE | Bias | EPF MAE | rMAE EPF | Mean price | MAE/mean | Share≤0 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| live_saved | highest_seq | gbm_overlay | 19585 | 21 | 64.6484 | -27.2605 | 44.2861 | 1.45979 | 144.938 | 0.446041 | 0.020628 |
| live_saved | highest_seq | physics | 54256 | 58 | 81.5658 | -51.2095 | 47.0225 | 1.73461 | 174.629 | 0.46708 | 0.0130861 |
| live_saved | highest_seq | stats_overlay | 14388 | 18 | 47.4889 | -4.4451 | 47.6128 | 0.997398 | 143.275 | 0.331452 | 0.0221018 |
| live_saved | sdac | gbm_overlay | 19585 | 21 | 64.855 | -27.2075 | 44.8852 | 1.44491 | 144.885 | 0.44763 | 0.0209344 |
| live_saved | sdac | physics | 54256 | 58 | 81.6783 | -51.235 | 47.3171 | 1.72619 | 174.655 | 0.467657 | 0.0131414 |
| live_saved | sdac | stats_overlay | 14388 | 18 | 47.7868 | -4.43759 | 48.2667 | 0.990059 | 143.268 | 0.333549 | 0.0225188 |
| live_since_cv43 | highest_seq | physics | 1872 | 2 | 42.6618 | -19.2519 | 78.9716 | 0.540217 | 183.37 | 0.232655 | 0.00534188 |
| live_since_cv43 | sdac | physics | 39 | 1 | 37.6087 | -18.3646 | 61.4903 | 0.611621 | 136.036 | 0.276462 | 0 |
| timestral_ontime | highest_seq | physics | 47679 | 51 | 81.7895 | -49.1065 | 48.19 | 1.69723 | 176.034 | 0.464625 | 0.0134231 |
| timestral_ontime | highest_seq | timestral_0630_prices | 47679 | 51 | 28.2131 | -3.44637 | 48.19 | 0.585456 | 176.034 | 0.160271 | 0.0134231 |
| timestral_ontime | highest_seq | timestral_postsim | 47679 | 51 | 25.2647 | -2.67613 | 48.19 | 0.524273 | 176.034 | 0.143522 | 0.0134231 |
| timestral_ontime | highest_seq | timestral_prices_matched_context | 47679 | 51 | 28.8191 | -3.62258 | 48.19 | 0.59803 | 176.034 | 0.163714 | 0.0134231 |
| timestral_ontime | sdac | physics | 47679 | 51 | 81.914 | -49.1352 | 48.5081 | 1.68867 | 176.062 | 0.465256 | 0.013486 |
| timestral_ontime | sdac | timestral_0630_prices | 47679 | 51 | 28.4687 | -3.4751 | 48.5081 | 0.586886 | 176.062 | 0.161697 | 0.013486 |
| timestral_ontime | sdac | timestral_postsim | 47679 | 51 | 25.4736 | -2.70486 | 48.5081 | 0.525141 | 176.062 | 0.144685 | 0.013486 |
| timestral_ontime | sdac | timestral_prices_matched_context | 47679 | 51 | 29.0653 | -3.6513 | 48.5081 | 0.599186 | 176.062 | 0.165086 | 0.013486 |

## Original historical estimators; raw-cell reconciliation unavailable

These are separately labelled original protocols, not new comparable cell scores. The record's rounded zone metrics reproduce the original energy-weighted summary to its printed precision. Its rMAE is a weighted mean of zone ratios after a row-offset weekly mask; this pack's new rMAE is a ratio of paired aggregate errors using keyed lags. GroupKFold ML rows are nonchronological. Rolling-origin values are read from the committed report, not recalculated from absent predictions.

| Window | Model | Evidence | MAE | rMAE | Original n | Original estimator |
| --- | --- | --- | --- | --- | --- | --- |
| record | physics_cv37 | replayed rounded zone summaries | 23.0816 | 0.813784 | — | energy-weighted mean of zone MAE and zone rMAE, after original row-shift mask |
| record | hybrid_groupkfold_cv37 | replayed rounded zone summaries | 14.9332 | 0.515814 | — | energy-weighted mean of zone MAE and zone rMAE, after original row-shift mask |
| record | stats_groupkfold_cv37 | replayed rounded zone summaries | 14.4936 | 0.488934 | — | energy-weighted mean of zone MAE and zone rMAE, after original row-shift mask |
| rolling_cv39 | physics (cv39) | original reported summary only | 23.3 | — | 341256 | pooled unweighted cells |
| rolling_cv39 | hybrid retrained (cv39) | original reported summary only | 24.7 | — | 341256 | pooled unweighted cells |
| rolling_cv39 | hybrid frozen (cv37) | original reported summary only | 15.66 | — | 341256 | pooled unweighted cells |
| rolling_cv39 | stats retrained (cv39) | original reported summary only | 21.05 | — | 341256 | pooled unweighted cells |

| Window | Requested target | New cells scored | Status |
| --- | --- | --- | --- |
| record | highest_seq | 0 | raw-cell reconciliation unavailable |
| record | sdac | 0 | raw-cell reconciliation unavailable |
| rolling_cv39 | highest_seq | 0 | raw-cell reconciliation unavailable |
| rolling_cv39 | sdac | 0 | raw-cell reconciliation unavailable |

A keyed local-hour lag can differ from a row168 shift around gaps/DST; SDAC retargets AT/DE_LU and applies complete-hour rules. Their new numerical effect cannot be recovered without the raw historical predictions. No invented masks, naive denominators, per-zone new targets or DM p-values are attached to the summary-only windows.

## Daily-vector DM versus the weekday naive

One-sided p favors the saved model; it is exploratory and unadjusted. Require30 complete, non-DST, balanced24-hour daily vectors. Footprints use absolute errors before zone averaging. Daily HAC keeps calendar gaps, bandwidth max(7,lead−1). Missing/short windows say insufficient data rather than manufacturing significance.

| Window | Target | Saved line | Balanced dates | DM | p(model better) | Status |
| --- | --- | --- | --- | --- | --- | --- |
| live_saved | highest_seq | gbm_overlay | 17 | — | — | insufficient data |
| live_saved | highest_seq | physics | 53 | -7.31893 | 1 | ok |
| live_saved | highest_seq | stats_overlay | 7 | — | — | insufficient data |
| live_saved | sdac | gbm_overlay | 17 | — | — | insufficient data |
| live_saved | sdac | physics | 53 | -7.30462 | 1 | ok |
| live_saved | sdac | stats_overlay | 7 | — | — | insufficient data |
| live_since_cv43 | highest_seq | physics | 2 | — | — | insufficient data |
| live_since_cv43 | sdac | physics | 0 | — | — | insufficient data |
| timestral_ontime | highest_seq | physics | 44 | -6.29904 | 1 | ok |
| timestral_ontime | highest_seq | timestral_0630_prices | 44 | 6.72915 | 8.53293e-12 | ok |
| timestral_ontime | highest_seq | timestral_postsim | 44 | 7.55452 | 2.10209e-14 | ok |
| timestral_ontime | highest_seq | timestral_prices_matched_context | 44 | 6.43885 | 6.01906e-11 | ok |
| timestral_ontime | sdac | physics | 44 | -6.27217 | 1 | ok |
| timestral_ontime | sdac | timestral_0630_prices | 44 | 6.72573 | 8.73595e-12 | ok |
| timestral_ontime | sdac | timestral_postsim | 44 | 7.55853 | 2.03829e-14 | ok |
| timestral_ontime | sdac | timestral_prices_matched_context | 44 | 6.43197 | 6.29782e-11 | ok |

The six per-contract manifests identify source/helper/evaluator hashes, fit/cutoff limitations and every output hash. Public snapshot fetch times span2026-11-16T19:28..19:29UTC. The overlap audit records differences from the older extract; it is not an issue-time revision archive. See the parent README for the contract, exact filenames, reproducibility and licence check. No external paper scores are placed beside these results.
