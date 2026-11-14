# Held-forward probability results

Window: 2026-09-14..2026-11-13; training starts 2024-07-01. Monthly origins 09-14 / 10-01 / 11-01; training labels through origin D−1. The headline/default uses already-public D−1 delivery prices. The [D−2 conservative benchmark](conservative-lag2/results.md) is retained separately. Hourly target is the mean SDAC settled price ≤0; daily target is any hourly mean ≤0 in a complete Athens market day. Numeric sequences are ordered before deduplication, and hourly means are rounded to eight decimal places. All classification figures in the first table use threshold 0.5.

| Variant | Target | Footprint | Model | n | Events | Brier | Log-loss | AUC | Recall | Precision | FP rate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pregate_0630 | hour | all39 | climatology | 57111 | 743 | 0.0135 | 0.0770 | 0.6575 | 0.0000 | — | 0.0000 |
| pregate_0630 | hour | excluding_italy | climatology | 46880 | 617 | 0.0138 | 0.0798 | 0.7112 | 0.0000 | — | 0.0000 |
| pregate_0630 | hour | all39 | logistic | 57111 | 743 | 0.0098 | 0.0412 | 0.9525 | 0.2288 | 0.5986 | 0.0020 |
| pregate_0630 | hour | excluding_italy | logistic | 46880 | 617 | 0.0091 | 0.0386 | 0.9541 | 0.2350 | 0.7360 | 0.0011 |
| pregate_0630 | day | all39 | climatology | 2377 | 159 | 0.0731 | 0.2808 | 0.6365 | 0.0000 | — | 0.0000 |
| pregate_0630 | day | excluding_italy | climatology | 1952 | 123 | 0.0722 | 0.2809 | 0.7244 | 0.0000 | — | 0.0000 |
| pregate_0630 | day | all39 | logistic | 2377 | 159 | 0.0469 | 0.1800 | 0.8928 | 0.2327 | 0.6727 | 0.0081 |
| pregate_0630 | day | excluding_italy | logistic | 1952 | 123 | 0.0414 | 0.1495 | 0.9223 | 0.2520 | 0.7209 | 0.0066 |
| gate_1000_latest_proxy | hour | all39 | climatology | 57111 | 743 | 0.0135 | 0.0770 | 0.6575 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | hour | excluding_italy | climatology | 46880 | 617 | 0.0138 | 0.0798 | 0.7112 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | hour | all39 | logistic | 57111 | 743 | 0.0080 | 0.0302 | 0.9831 | 0.5451 | 0.6299 | 0.0042 |
| gate_1000_latest_proxy | hour | excluding_italy | logistic | 46880 | 617 | 0.0078 | 0.0299 | 0.9818 | 0.5770 | 0.6496 | 0.0042 |
| gate_1000_latest_proxy | day | all39 | climatology | 2377 | 159 | 0.0731 | 0.2808 | 0.6365 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | day | excluding_italy | climatology | 1952 | 123 | 0.0722 | 0.2809 | 0.7244 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | day | all39 | logistic | 2377 | 159 | 0.0353 | 0.1240 | 0.9497 | 0.5535 | 0.7097 | 0.0162 |
| gate_1000_latest_proxy | day | excluding_italy | logistic | 1952 | 123 | 0.0304 | 0.1057 | 0.9610 | 0.5772 | 0.7172 | 0.0153 |

## Threshold choice

No score-driven model search. Test-optimal F1 and matched-FP points are **oracle descriptions of the held-forward ROC/PR curve**, not deployable thresholds. A separate F1 threshold uses previously issued predictions on the 28-day window ending origin D−1. Later test labels never select an earlier threshold.

| Variant | Target | Choice | Threshold | Recall | Precision | F1 | TP | FP | FP rate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pregate_0630 | hour | fixed_0.2 | 0.2000 | 0.4172 | 0.4593 | 0.4372 | 310 | 365 | 0.0065 |
| pregate_0630 | hour | fixed_0.3 | 0.3000 | 0.3607 | 0.5296 | 0.4291 | 268 | 238 | 0.0042 |
| pregate_0630 | hour | fixed_0.5 | 0.5000 | 0.2288 | 0.5986 | 0.3311 | 170 | 114 | 0.0020 |
| pregate_0630 | hour | oracle_test_max_f1 | 0.1575 | 0.4657 | 0.4341 | 0.4494 | 346 | 451 | 0.0080 |
| pregate_0630 | hour | oracle_test_matched_zero_fpr | 0.9352 | 0.0148 | 1.0000 | 0.0292 | 11 | 0 | 0.0000 |
| pregate_0630 | hour | lag1_indicator | 0.5000 | 0.2598 | 0.2601 | 0.2599 | 193 | 549 | 0.0097 |
| pregate_0630 | hour | oracle_test_matched_lag1_fpr | 0.1282 | 0.4886 | 0.3980 | 0.4387 | 363 | 549 | 0.0097 |
| pregate_0630 | day | fixed_0.2 | 0.2000 | 0.4654 | 0.5103 | 0.4868 | 74 | 71 | 0.0320 |
| pregate_0630 | day | fixed_0.3 | 0.3000 | 0.3648 | 0.5577 | 0.4411 | 58 | 46 | 0.0207 |
| pregate_0630 | day | fixed_0.5 | 0.5000 | 0.2327 | 0.6727 | 0.3458 | 37 | 18 | 0.0081 |
| pregate_0630 | day | oracle_test_max_f1 | 0.1450 | 0.5472 | 0.4531 | 0.4957 | 87 | 105 | 0.0473 |
| pregate_0630 | day | oracle_test_matched_zero_fpr | 0.9779 | 0.0189 | 1.0000 | 0.0370 | 3 | 0 | 0.0000 |
| pregate_0630 | day | lag1_indicator | 0.5000 | 0.3082 | 0.3082 | 0.3082 | 49 | 110 | 0.0496 |
| pregate_0630 | day | oracle_test_matched_lag1_fpr | 0.1377 | 0.5472 | 0.4416 | 0.4888 | 87 | 110 | 0.0496 |
| pregate_0630 | hour | prior_origin_selected_f1 | — | 0.4011 | 0.4448 | 0.4218 | 298 | 372 | 0.0066 |
| gate_1000_latest_proxy | hour | fixed_0.2 | 0.2000 | 0.7214 | 0.4033 | 0.5174 | 536 | 793 | 0.0141 |
| gate_1000_latest_proxy | hour | fixed_0.3 | 0.3000 | 0.6689 | 0.4921 | 0.5670 | 497 | 513 | 0.0091 |
| gate_1000_latest_proxy | hour | fixed_0.5 | 0.5000 | 0.5451 | 0.6299 | 0.5844 | 405 | 238 | 0.0042 |
| gate_1000_latest_proxy | hour | oracle_test_max_f1 | 0.4067 | 0.6137 | 0.5794 | 0.5961 | 456 | 331 | 0.0059 |
| gate_1000_latest_proxy | hour | oracle_test_matched_zero_fpr | 0.9998 | 0.0363 | 1.0000 | 0.0701 | 27 | 0 | 0.0000 |
| gate_1000_latest_proxy | hour | lag1_indicator | 0.5000 | 0.2598 | 0.2601 | 0.2599 | 193 | 549 | 0.0097 |
| gate_1000_latest_proxy | hour | oracle_test_matched_lag1_fpr | 0.2833 | 0.6743 | 0.4771 | 0.5588 | 501 | 549 | 0.0097 |
| gate_1000_latest_proxy | day | fixed_0.2 | 0.2000 | 0.7547 | 0.4688 | 0.5783 | 120 | 136 | 0.0613 |
| gate_1000_latest_proxy | day | fixed_0.3 | 0.3000 | 0.6604 | 0.5585 | 0.6052 | 105 | 83 | 0.0374 |
| gate_1000_latest_proxy | day | fixed_0.5 | 0.5000 | 0.5535 | 0.7097 | 0.6219 | 88 | 36 | 0.0162 |
| gate_1000_latest_proxy | day | oracle_test_max_f1 | 0.4869 | 0.5723 | 0.7109 | 0.6341 | 91 | 37 | 0.0167 |
| gate_1000_latest_proxy | day | oracle_test_matched_zero_fpr | 0.9828 | 0.1006 | 1.0000 | 0.1829 | 16 | 0 | 0.0000 |
| gate_1000_latest_proxy | day | lag1_indicator | 0.5000 | 0.3082 | 0.3082 | 0.3082 | 49 | 110 | 0.0496 |
| gate_1000_latest_proxy | day | oracle_test_matched_lag1_fpr | 0.2463 | 0.7170 | 0.5089 | 0.5953 | 114 | 110 | 0.0496 |
| gate_1000_latest_proxy | hour | prior_origin_selected_f1 | — | 0.5626 | 0.6049 | 0.5830 | 418 | 273 | 0.0048 |

## Eight zones with most hourly collapses

Ranking is for presentation only; ties use zone name. Each row has 1,465 held-forward hours. The main table gives per-zone precision and recall at 0.5; probability-by-zone.csv covers every zone, top8-thresholds.csv adds 0.2/0.3/0.5 for these eight zones, and selected-thresholds-by-origin.csv records the preceding-window F1 thresholds.

| Zone | Events | Pre-gate Brier | AUC | TP | FP | Recall .5 | Precision .5 | Recall .2 | Precision .2 | Proxy Brier | Proxy AUC |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GR | 140 | 0.0494 | 0.9549 | 62 | 22 | 0.4429 | 0.7381 | 0.6714 | 0.6395 | 0.0217 | 0.9945 |
| ES | 54 | 0.0185 | 0.9727 | 22 | 5 | 0.4074 | 0.8148 | 0.6667 | 0.6102 | 0.0128 | 0.9920 |
| PT | 45 | 0.0153 | 0.9716 | 25 | 8 | 0.5556 | 0.7576 | 0.7111 | 0.5424 | 0.0108 | 0.9921 |
| IT-Calabria | 41 | 0.0303 | 0.8963 | 7 | 20 | 0.1707 | 0.2593 | 0.2927 | 0.2143 | 0.0162 | 0.9866 |
| IT-Sicily | 41 | 0.0304 | 0.9205 | 9 | 26 | 0.2195 | 0.2571 | 0.2927 | 0.2182 | 0.0187 | 0.9801 |
| IT-SOUTH | 40 | 0.0272 | 0.8940 | 9 | 16 | 0.2250 | 0.3600 | 0.3250 | 0.2453 | 0.0190 | 0.9819 |
| DE_LU | 31 | 0.0162 | 0.9154 | 7 | 0 | 0.2258 | 1.0000 | 0.3548 | 0.3929 | 0.0144 | 0.9787 |
| NL | 31 | 0.0137 | 0.9809 | 9 | 4 | 0.2903 | 0.6923 | 0.5806 | 0.6000 | 0.0094 | 0.9992 |

Coverage: 57,111 of 57,135 possible hours (24 missing Sardinia prices); 2,377 of 2,379 complete zone-days (the gap straddles two Athens days). All 39 zones are scored; ex-Italy n=46,880 hours / 1,952 days. Complete physical features: pre-gate 44,759 hours, proxy 52,304 hours. Other cells retain calendar/history features and missing indicators.

On 54,303 exact common live cells there are **710 canonical collapse labels**, with no disagreement after normalizing both sources to eight decimals. The immutable sim has zero ≤0 predictions. Published lead-1 weather forecasts were frozen 08:16–10:06 UTC D−1, later than 06:30; seven days were a few minutes after the summer auction gate.

## Leakage and calibration limits

The [timestamp-bound table](stamp-bound.md) prevents a gate-time performance claim: only 877 cells have load+solar+wind stored revisions all before 10:00, containing zero collapse events. Latest-D1 scores measure potential information, not a verified gate-time replay. Pre-gate raw revisions are filtered before resolution selection. No ERA5, target-day observations or future labels enter the 06:30 model.

Reliability is imperfect: the pre-gate day model's lowest bin averages 1.1% risk while observing 3.2% over 2139 zone-days; higher bins have few samples. This is a candidate for a prospective archived-input pilot, not a claim of calibrated operational alerts. Reliability counts are in reliability.csv; undefined AUC/recall/precision are null. No seasonal-generalization claim or uncertainty interval is inferred from two months.

## Foundation-model comparator

Chronos-2 prices-only D−1 forecasts match the headline settled-information cutoff, verified from every context_end_utc and the prior auction's price availability. Both models are scored on exactly 57,111 cells; the logistic model additionally uses calendar and accepted load/RES persistence. This compares these pipelines, not model families in isolation. Quantile-interpolated Chronos probabilities are clipped to [0.005, 0.995] by its author.

| Footprint | Model | n | Events | Brier | Log-loss | AUC | Recall .5 | Precision .5 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| all39 | logistic_pregate_D1 | 57111 | 743 | 0.0098 | 0.0412 | 0.9525 | 0.2288 | 0.5986 |
| all39 | Chronos2_uni_D1 | 57111 | 743 | 0.0103 | 0.0455 | 0.8993 | 0.0633 | 0.8246 |
| excluding_italy | logistic_pregate_D1 | 46880 | 617 | 0.0091 | 0.0386 | 0.9541 | 0.2350 | 0.7360 |
| excluding_italy | Chronos2_uni_D1 | 46880 | 617 | 0.0099 | 0.0426 | 0.9371 | 0.0762 | 0.8246 |

## Default D−1 history and conservative D−2 comparison

D−1 delivery day-ahead prices are auctioned/published on D−2, so they are normally known by the D−1 morning issue ([Nord Pool daily process](https://www.nordpoolgroup.com/en/the-power-market/Day-ahead-market/)). The default uses this price history, recent price-event frequencies and training labels through D−1. Forecast-publication rules and physical D−2 forecast persistence stay unchanged. C=1 and monthly origins are identical in the labelled conservative D−2 benchmark. This is additional public information, with no model-parameter search. Initial price revisions are not archived in the extract.

| Price history | Target | Footprint | n | Events | Brier | Log-loss | AUC | Recall .5 | Precision .5 | FP rate .5 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| price_L1 | hour | all39 | 57111 | 743 | 0.0098 | 0.0412 | 0.9525 | 0.2288 | 0.5986 | 0.0020 |
| price_L1 | hour | excluding_italy | 46880 | 617 | 0.0091 | 0.0386 | 0.9541 | 0.2350 | 0.7360 | 0.0011 |
| price_L2_frozen | hour | all39 | 57111 | 743 | 0.0105 | 0.0459 | 0.9317 | 0.1211 | 0.6164 | 0.0010 |
| price_L2_frozen | hour | excluding_italy | 46880 | 617 | 0.0102 | 0.0459 | 0.9259 | 0.1345 | 0.6748 | 0.0009 |
| price_L1 | day | all39 | 2377 | 159 | 0.0469 | 0.1800 | 0.8928 | 0.2327 | 0.6727 | 0.0081 |
| price_L1 | day | excluding_italy | 1952 | 123 | 0.0414 | 0.1495 | 0.9223 | 0.2520 | 0.7209 | 0.0066 |
| price_L2_frozen | day | all39 | 2377 | 159 | 0.0531 | 0.2026 | 0.8446 | 0.1509 | 0.5333 | 0.0095 |
| price_L2_frozen | day | excluding_italy | 1952 | 123 | 0.0490 | 0.1834 | 0.8618 | 0.1789 | 0.5238 | 0.0109 |

The inference CLI defaults to --settled-lag 1 and writes priceL1 artifacts. Use --settled-lag 2 for the labelled conservative variant. Threshold-0.2/0.3 metrics are in price-history-sensitivity.csv; every zone is in price-history-by-zone.csv.

## Physical-price ablation

Corrected-fleet eight-day run pending. It clears UTC delivery days under a 10:00 issuance context (recent-generation latency cutoffs active), with latest-revision ENTSO-E forecasts. Both arms include analyst patch ac0ab5bfe079. It is separate from the Athens market-day probability evaluation.
