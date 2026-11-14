# Held-forward probability results

Window: 2026-09-14..2026-11-13; training starts 2024-07-01. Monthly origins 09-14 / 10-01 / 11-01; training labels through origin D−2. Hourly target is the mean SDAC settled price ≤0; daily target is any hourly mean ≤0 in a complete Athens market day. Numeric sequences are ordered before deduplication, and hourly means are rounded to eight decimal places. All classification figures in the first table use threshold 0.5.

| Variant | Target | Footprint | Model | n | Events | Brier | Log-loss | AUC | Recall | Precision | FP rate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pregate_0630 | hour | all39 | climatology | 57111 | 743 | 0.0135 | 0.0770 | 0.6575 | 0.0000 | — | 0.0000 |
| pregate_0630 | hour | excluding_italy | climatology | 46880 | 617 | 0.0138 | 0.0798 | 0.7112 | 0.0000 | — | 0.0000 |
| pregate_0630 | hour | all39 | logistic | 57111 | 743 | 0.0105 | 0.0459 | 0.9317 | 0.1211 | 0.6164 | 0.0010 |
| pregate_0630 | hour | excluding_italy | logistic | 46880 | 617 | 0.0102 | 0.0459 | 0.9259 | 0.1345 | 0.6748 | 0.0009 |
| pregate_0630 | day | all39 | climatology | 2377 | 159 | 0.0731 | 0.2809 | 0.6350 | 0.0000 | — | 0.0000 |
| pregate_0630 | day | excluding_italy | climatology | 1952 | 123 | 0.0722 | 0.2810 | 0.7222 | 0.0000 | — | 0.0000 |
| pregate_0630 | day | all39 | logistic | 2377 | 159 | 0.0531 | 0.2026 | 0.8446 | 0.1509 | 0.5333 | 0.0095 |
| pregate_0630 | day | excluding_italy | logistic | 1952 | 123 | 0.0490 | 0.1834 | 0.8618 | 0.1789 | 0.5238 | 0.0109 |
| gate_1000_latest_proxy | hour | all39 | climatology | 57111 | 743 | 0.0135 | 0.0770 | 0.6575 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | hour | excluding_italy | climatology | 46880 | 617 | 0.0138 | 0.0798 | 0.7112 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | hour | all39 | logistic | 57111 | 743 | 0.0084 | 0.0326 | 0.9786 | 0.5437 | 0.6322 | 0.0042 |
| gate_1000_latest_proxy | hour | excluding_italy | logistic | 46880 | 617 | 0.0083 | 0.0330 | 0.9764 | 0.5608 | 0.6528 | 0.0040 |
| gate_1000_latest_proxy | day | all39 | climatology | 2377 | 159 | 0.0731 | 0.2809 | 0.6350 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | day | excluding_italy | climatology | 1952 | 123 | 0.0722 | 0.2810 | 0.7222 | 0.0000 | — | 0.0000 |
| gate_1000_latest_proxy | day | all39 | logistic | 2377 | 159 | 0.0386 | 0.1379 | 0.9353 | 0.5472 | 0.6444 | 0.0216 |
| gate_1000_latest_proxy | day | excluding_italy | logistic | 1952 | 123 | 0.0352 | 0.1226 | 0.9479 | 0.5691 | 0.6481 | 0.0208 |

## Threshold choice

No score-driven model search. Test-optimal F1 and matched-FP points are **oracle descriptions of the held-forward ROC/PR curve**, not deployable thresholds. A separate F1 threshold uses previously issued predictions on the 28-day window ending origin D−2. Later test labels never select an earlier threshold.

| Variant | Target | Choice | Threshold | Recall | Precision | F1 | TP | FP | FP rate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pregate_0630 | hour | fixed_0.2 | 0.2000 | 0.2974 | 0.4070 | 0.3437 | 221 | 322 | 0.0057 |
| pregate_0630 | hour | fixed_0.3 | 0.3000 | 0.2557 | 0.5292 | 0.3448 | 190 | 169 | 0.0030 |
| pregate_0630 | hour | fixed_0.5 | 0.5000 | 0.1211 | 0.6164 | 0.2025 | 90 | 56 | 0.0010 |
| pregate_0630 | hour | oracle_test_max_f1 | 0.1379 | 0.3903 | 0.3620 | 0.3756 | 290 | 511 | 0.0091 |
| pregate_0630 | hour | oracle_test_matched_zero_fpr | 0.8698 | 0.0013 | 1.0000 | 0.0027 | 1 | 0 | 0.0000 |
| pregate_0630 | hour | lag2_indicator | 0.5000 | 0.1575 | 0.1548 | 0.1561 | 117 | 639 | 0.0113 |
| pregate_0630 | hour | oracle_test_matched_lag2_fpr | 0.1124 | 0.4266 | 0.3316 | 0.3732 | 317 | 639 | 0.0113 |
| pregate_0630 | day | fixed_0.2 | 0.2000 | 0.3459 | 0.4135 | 0.3767 | 55 | 78 | 0.0352 |
| pregate_0630 | day | fixed_0.3 | 0.3000 | 0.2642 | 0.5000 | 0.3457 | 42 | 42 | 0.0189 |
| pregate_0630 | day | fixed_0.5 | 0.5000 | 0.1509 | 0.5333 | 0.2353 | 24 | 21 | 0.0095 |
| pregate_0630 | day | oracle_test_max_f1 | 0.1856 | 0.3899 | 0.4189 | 0.4039 | 62 | 86 | 0.0388 |
| pregate_0630 | day | oracle_test_matched_zero_fpr | 0.9807 | 0.0000 | — | 0.0000 | 0 | 0 | 0.0000 |
| pregate_0630 | day | lag2_indicator | 0.5000 | 0.1761 | 0.1707 | 0.1734 | 28 | 136 | 0.0613 |
| pregate_0630 | day | oracle_test_matched_lag2_fpr | 0.1352 | 0.4340 | 0.3366 | 0.3791 | 69 | 136 | 0.0613 |
| pregate_0630 | hour | prior_origin_selected_f1 | 0.5000 | 0.3244 | 0.3555 | 0.3392 | 241 | 437 | 0.0078 |
| gate_1000_latest_proxy | hour | fixed_0.2 | 0.2000 | 0.7254 | 0.3699 | 0.4900 | 539 | 918 | 0.0163 |
| gate_1000_latest_proxy | hour | fixed_0.3 | 0.3000 | 0.6729 | 0.4730 | 0.5556 | 500 | 557 | 0.0099 |
| gate_1000_latest_proxy | hour | fixed_0.5 | 0.5000 | 0.5437 | 0.6322 | 0.5847 | 404 | 235 | 0.0042 |
| gate_1000_latest_proxy | hour | oracle_test_max_f1 | 0.4607 | 0.5707 | 0.6083 | 0.5889 | 424 | 273 | 0.0048 |
| gate_1000_latest_proxy | hour | oracle_test_matched_zero_fpr | 0.9991 | 0.0471 | 1.0000 | 0.0900 | 35 | 0 | 0.0000 |
| gate_1000_latest_proxy | hour | lag2_indicator | 0.5000 | 0.1575 | 0.1548 | 0.1561 | 117 | 639 | 0.0113 |
| gate_1000_latest_proxy | hour | oracle_test_matched_lag2_fpr | 0.2752 | 0.6864 | 0.4439 | 0.5391 | 510 | 639 | 0.0113 |
| gate_1000_latest_proxy | day | fixed_0.2 | 0.2000 | 0.7296 | 0.4312 | 0.5421 | 116 | 153 | 0.0690 |
| gate_1000_latest_proxy | day | fixed_0.3 | 0.3000 | 0.6792 | 0.5373 | 0.6000 | 108 | 93 | 0.0419 |
| gate_1000_latest_proxy | day | fixed_0.5 | 0.5000 | 0.5472 | 0.6444 | 0.5918 | 87 | 48 | 0.0216 |
| gate_1000_latest_proxy | day | oracle_test_max_f1 | 0.4090 | 0.6038 | 0.6115 | 0.6076 | 96 | 61 | 0.0275 |
| gate_1000_latest_proxy | day | oracle_test_matched_zero_fpr | 0.9769 | 0.0943 | 1.0000 | 0.1724 | 15 | 0 | 0.0000 |
| gate_1000_latest_proxy | day | lag2_indicator | 0.5000 | 0.1761 | 0.1707 | 0.1734 | 28 | 136 | 0.0613 |
| gate_1000_latest_proxy | day | oracle_test_matched_lag2_fpr | 0.2171 | 0.7044 | 0.4516 | 0.5504 | 112 | 136 | 0.0613 |
| gate_1000_latest_proxy | hour | prior_origin_selected_f1 | 0.5000 | 0.4697 | 0.6686 | 0.5518 | 349 | 173 | 0.0031 |

## Eight zones with most hourly collapses

Ranking is for presentation only; ties use zone name. Each row has 1,465 held-forward hours. The main table gives per-zone precision and recall at 0.5; the adjacent CSVs cover every zone and thresholds 0.2/0.3.

| Zone | Events | Pre-gate Brier | AUC | TP | FP | Recall .5 | Precision .5 | Recall .2 | Precision .2 | Proxy Brier | Proxy AUC |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GR | 140 | 0.0668 | 0.9168 | 29 | 29 | 0.2071 | 0.5000 | 0.5214 | 0.4932 | 0.0249 | 0.9933 |
| ES | 54 | 0.0226 | 0.9507 | 16 | 5 | 0.2963 | 0.7619 | 0.5741 | 0.5082 | 0.0161 | 0.9849 |
| PT | 45 | 0.0172 | 0.9547 | 20 | 2 | 0.4444 | 0.9091 | 0.6000 | 0.5294 | 0.0124 | 0.9834 |
| IT-Calabria | 41 | 0.0253 | 0.8979 | 0 | 2 | 0.0000 | 0.0000 | 0.1707 | 0.2059 | 0.0167 | 0.9859 |
| IT-Sicily | 41 | 0.0257 | 0.9223 | 7 | 11 | 0.1707 | 0.3889 | 0.2683 | 0.2200 | 0.0169 | 0.9801 |
| IT-SOUTH | 40 | 0.0260 | 0.8889 | 0 | 3 | 0.0000 | 0.0000 | 0.1750 | 0.1795 | 0.0187 | 0.9813 |
| DE_LU | 31 | 0.0176 | 0.8002 | 0 | 0 | 0.0000 | — | 0.2903 | 0.5625 | 0.0140 | 0.9803 |
| NL | 31 | 0.0163 | 0.9376 | 2 | 0 | 0.0645 | 1.0000 | 0.3226 | 0.5000 | 0.0076 | 0.9995 |

Coverage: 57,111 of 57,135 possible hours (24 missing Sardinia prices); 2,377 of 2,379 complete zone-days (the gap straddles two Athens days). All 39 zones are scored; ex-Italy n=46,880 hours / 1,952 days. Complete physical features: pre-gate 44,759 hours, proxy 52,304 hours. Other cells retain calendar/history features and missing indicators.

On 54,303 exact common live cells there are **710 canonical collapse labels**, with no disagreement after normalizing both sources to eight decimals. The immutable sim has zero ≤0 predictions. Published lead-1 weather forecasts were frozen 08:16–10:06 UTC D−1, later than 06:30; seven days were a few minutes after the summer auction gate.

## Leakage and calibration limits

The [timestamp-bound table](stamp-bound.md) prevents a gate-time performance claim: only 877 cells have load+solar+wind stored revisions all before 10:00, containing zero collapse events. Latest-D1 scores measure potential information, not a verified gate-time replay. Pre-gate raw revisions are filtered before resolution selection. No ERA5, target-day observations or future labels enter the 06:30 model.

Reliability is imperfect: the pre-gate day model's <0.1 bin predicts about 1.5% risk while observing about 3.7%; higher bins have few samples. This is a candidate for a prospective archived-input pilot, not a claim of calibrated operational alerts. Reliability counts are in reliability.csv; undefined AUC/recall/precision are null. No seasonal-generalization claim or uncertainty interval is inferred from two months.

## Foundation-model comparator

Chronos-2 prices-only D−2 forecasts match the conservative settled-information cutoff, verified from every context_end_utc. Both models are scored on exactly 57,111 cells; the logistic model additionally uses calendar and accepted load/RES persistence. This compares these pipelines, not model families in isolation. Quantile-interpolated Chronos probabilities are clipped to [0.005, 0.995] by its author.

| Footprint | Model | n | Events | Brier | Log-loss | AUC | Recall .5 | Precision .5 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| all39 | logistic_pregate_D2 | 57111 | 743 | 0.0105 | 0.0459 | 0.9317 | 0.1211 | 0.6164 |
| all39 | Chronos2_uni_D2 | 57111 | 743 | 0.0112 | 0.0503 | 0.8985 | 0.0229 | 0.3469 |
| excluding_italy | logistic_pregate_D2 | 46880 | 617 | 0.0102 | 0.0459 | 0.9259 | 0.1345 | 0.6748 |
| excluding_italy | Chronos2_uni_D2 | 46880 | 617 | 0.0110 | 0.0492 | 0.9170 | 0.0276 | 0.3469 |

## Physical-price ablation

Corrected-fleet eight-day run pending. It clears UTC delivery days under a 10:00 issuance context (recent-generation latency cutoffs active), with latest-revision ENTSO-E forecasts. Both arms include analyst patch ac0ab5bfe079. It is separate from the Athens market-day probability evaluation.
