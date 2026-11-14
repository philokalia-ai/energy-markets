# Held-forward probability results

Window: 2026-09-14..2026-11-13; training starts 2024-07-01. Monthly origins 09-14 / 10-01 / 11-01, labels through origin D−2. Hourly target is mean settled price ≤0; daily target is any hourly mean ≤0 in a complete Athens market day. All classification figures below use threshold 0.5. Latest-D1 proxy timing is unverified; see [timestamp bound](stamp-bound.md).

| Variant | Target | Footprint | Model | n | Events | Brier | Log-loss | AUC | Recall | FP rate |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| pregate_0630 | hour | all39 | climatology | 57111 | 741 | 0.0135 | 0.0769 | 0.6572 | 0.0000 | 0.0000 |
| pregate_0630 | hour | excluding_italy | climatology | 46880 | 615 | 0.0137 | 0.0797 | 0.7112 | 0.0000 | 0.0000 |
| pregate_0630 | hour | all39 | logistic | 57111 | 741 | 0.0105 | 0.0458 | 0.9316 | 0.1215 | 0.0010 |
| pregate_0630 | hour | excluding_italy | logistic | 46880 | 615 | 0.0102 | 0.0458 | 0.9258 | 0.1350 | 0.0009 |
| pregate_0630 | day | all39 | climatology | 2377 | 159 | 0.0731 | 0.2809 | 0.6356 | 0.0000 | 0.0000 |
| pregate_0630 | day | excluding_italy | climatology | 1952 | 123 | 0.0722 | 0.2810 | 0.7230 | 0.0000 | 0.0000 |
| pregate_0630 | day | all39 | logistic | 2377 | 159 | 0.0532 | 0.2025 | 0.8448 | 0.1509 | 0.0095 |
| pregate_0630 | day | excluding_italy | logistic | 1952 | 123 | 0.0491 | 0.1834 | 0.8620 | 0.1789 | 0.0109 |
| gate_1000_latest_proxy | hour | all39 | climatology | 57111 | 741 | 0.0135 | 0.0769 | 0.6572 | 0.0000 | 0.0000 |
| gate_1000_latest_proxy | hour | excluding_italy | climatology | 46880 | 615 | 0.0137 | 0.0797 | 0.7112 | 0.0000 | 0.0000 |
| gate_1000_latest_proxy | hour | all39 | logistic | 57111 | 741 | 0.0084 | 0.0326 | 0.9785 | 0.5439 | 0.0042 |
| gate_1000_latest_proxy | hour | excluding_italy | logistic | 46880 | 615 | 0.0083 | 0.0329 | 0.9764 | 0.5610 | 0.0040 |
| gate_1000_latest_proxy | day | all39 | climatology | 2377 | 159 | 0.0731 | 0.2809 | 0.6356 | 0.0000 | 0.0000 |
| gate_1000_latest_proxy | day | excluding_italy | climatology | 1952 | 123 | 0.0722 | 0.2810 | 0.7230 | 0.0000 | 0.0000 |
| gate_1000_latest_proxy | day | all39 | logistic | 2377 | 159 | 0.0387 | 0.1380 | 0.9354 | 0.5472 | 0.0216 |
| gate_1000_latest_proxy | day | excluding_italy | logistic | 1952 | 123 | 0.0353 | 0.1227 | 0.9479 | 0.5691 | 0.0208 |

## Threshold choice

Fixed settings, no score-driven model search. Test-optimal F1 and matched-FP operating points below are **oracle diagnostics**, never deployment thresholds. The prior-origin F1 threshold is selected using the preceding 28-day held-forward window ending origin D−2.

| Variant | Target | Choice | Threshold | Recall | Precision | F1 | TP | FP | FP rate |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| pregate_0630 | hour | fixed_0.2 | 0.2000 | 0.2969 | 0.4067 | 0.3432 | 220 | 321 | 0.0057 |
| pregate_0630 | hour | fixed_0.3 | 0.3000 | 0.2564 | 0.5278 | 0.3451 | 190 | 170 | 0.0030 |
| pregate_0630 | hour | fixed_0.5 | 0.5000 | 0.1215 | 0.6164 | 0.2029 | 90 | 56 | 0.0010 |
| pregate_0630 | hour | oracle_test_max_f1 | 0.1118 | 0.4305 | 0.3316 | 0.3746 | 319 | 643 | 0.0114 |
| pregate_0630 | hour | oracle_test_matched_zero_fpr | 0.8697 | 0.0013 | 1.0000 | 0.0027 | 1 | 0 | 0.0000 |
| pregate_0630 | hour | lag2_indicator | 0.5000 | 0.1579 | 0.1550 | 0.1564 | 117 | 638 | 0.0113 |
| pregate_0630 | hour | oracle_test_matched_lag2_fpr | 0.1123 | 0.4278 | 0.3319 | 0.3738 | 317 | 638 | 0.0113 |
| pregate_0630 | day | fixed_0.2 | 0.2000 | 0.3648 | 0.4234 | 0.3919 | 58 | 79 | 0.0356 |
| pregate_0630 | day | fixed_0.3 | 0.3000 | 0.2642 | 0.4941 | 0.3443 | 42 | 43 | 0.0194 |
| pregate_0630 | day | fixed_0.5 | 0.5000 | 0.1509 | 0.5333 | 0.2353 | 24 | 21 | 0.0095 |
| pregate_0630 | day | oracle_test_max_f1 | 0.1745 | 0.4088 | 0.3988 | 0.4037 | 65 | 98 | 0.0442 |
| pregate_0630 | day | oracle_test_matched_zero_fpr | 0.9804 | 0.0000 | — | 0.0000 | 0 | 0 | 0.0000 |
| pregate_0630 | day | lag2_indicator | 0.5000 | 0.1761 | 0.1707 | 0.1734 | 28 | 136 | 0.0613 |
| pregate_0630 | day | oracle_test_matched_lag2_fpr | 0.1342 | 0.4340 | 0.3366 | 0.3791 | 69 | 136 | 0.0613 |
| pregate_0630 | hour | prior_origin_selected_f1 | 0.5000 | 0.3090 | 0.3823 | 0.3418 | 229 | 370 | 0.0066 |
| gate_1000_latest_proxy | hour | fixed_0.2 | 0.2000 | 0.7260 | 0.3685 | 0.4889 | 538 | 922 | 0.0164 |
| gate_1000_latest_proxy | hour | fixed_0.3 | 0.3000 | 0.6721 | 0.4694 | 0.5527 | 498 | 563 | 0.0100 |
| gate_1000_latest_proxy | hour | fixed_0.5 | 0.5000 | 0.5439 | 0.6307 | 0.5841 | 403 | 236 | 0.0042 |
| gate_1000_latest_proxy | hour | oracle_test_max_f1 | 0.4613 | 0.5709 | 0.6086 | 0.5891 | 423 | 272 | 0.0048 |
| gate_1000_latest_proxy | hour | oracle_test_matched_zero_fpr | 0.9991 | 0.0472 | 1.0000 | 0.0902 | 35 | 0 | 0.0000 |
| gate_1000_latest_proxy | hour | lag2_indicator | 0.5000 | 0.1579 | 0.1550 | 0.1564 | 117 | 638 | 0.0113 |
| gate_1000_latest_proxy | hour | oracle_test_matched_lag2_fpr | 0.2764 | 0.6856 | 0.4433 | 0.5384 | 508 | 638 | 0.0113 |
| gate_1000_latest_proxy | day | fixed_0.2 | 0.2000 | 0.7296 | 0.4312 | 0.5421 | 116 | 153 | 0.0690 |
| gate_1000_latest_proxy | day | fixed_0.3 | 0.3000 | 0.6792 | 0.5373 | 0.6000 | 108 | 93 | 0.0419 |
| gate_1000_latest_proxy | day | fixed_0.5 | 0.5000 | 0.5472 | 0.6444 | 0.5918 | 87 | 48 | 0.0216 |
| gate_1000_latest_proxy | day | oracle_test_max_f1 | 0.4090 | 0.6038 | 0.6115 | 0.6076 | 96 | 61 | 0.0275 |
| gate_1000_latest_proxy | day | oracle_test_matched_zero_fpr | 0.9769 | 0.0943 | 1.0000 | 0.1724 | 15 | 0 | 0.0000 |
| gate_1000_latest_proxy | day | lag2_indicator | 0.5000 | 0.1761 | 0.1707 | 0.1734 | 28 | 136 | 0.0613 |
| gate_1000_latest_proxy | day | oracle_test_matched_lag2_fpr | 0.2171 | 0.7044 | 0.4516 | 0.5504 | 112 | 136 | 0.0613 |
| gate_1000_latest_proxy | hour | prior_origin_selected_f1 | 0.5000 | 0.4710 | 0.6699 | 0.5531 | 349 | 172 | 0.0031 |

## Eight zones with the most hourly collapse events

Ranking uses test-event counts only for presentation; ties are ordered by zone name. It is not a feature or a selection filter for fitted models. Each row has 1,465 test hours.

| Zone | Events | Pre-gate Brier | AUC | TP / FP at .5 | Recall at .2 | Precision at .2 | Proxy Brier | Proxy AUC |
|---|---:|---:|---:|---:|---:|---:|---:|
| GR | 140 | 0.0668 | 0.9167 | 29 / 29 | 0.5214 | 0.4932 | 0.0249 | 0.9933 |
| ES | 54 | 0.0226 | 0.9508 | 16 / 5 | 0.5741 | 0.5082 | 0.0161 | 0.9849 |
| PT | 45 | 0.0172 | 0.9547 | 20 / 2 | 0.6000 | 0.5294 | 0.0124 | 0.9834 |
| IT-Calabria | 41 | 0.0253 | 0.8980 | 0 / 2 | 0.1707 | 0.2059 | 0.0167 | 0.9859 |
| IT-Sicily | 41 | 0.0257 | 0.9224 | 7 / 11 | 0.2683 | 0.2200 | 0.0169 | 0.9801 |
| IT-SOUTH | 40 | 0.0260 | 0.8889 | 0 / 3 | 0.1750 | 0.1795 | 0.0187 | 0.9813 |
| DE_LU | 31 | 0.0176 | 0.7988 | 0 / 0 | 0.2903 | 0.6000 | 0.0139 | 0.9804 |
| NL | 31 | 0.0162 | 0.9397 | 2 / 0 | 0.3226 | 0.5000 | 0.0076 | 0.9995 |

Coverage: 57,111 of 57,135 possible hourly cells (24 missing Italian Sardinia hours); 2,377 of 2,379 possible complete zone-days (the gap straddles two Athens days). Physical feature completeness: pre-gate 44,709 hours; proxy 52,304 hours. Other cells retain calendar/settled-history features with missing indicators. All 39 zones are scored. Ex-Italy hourly n=46,880; daily n=1,952.

On 54,303 common published lead-1 weather cells, extract labels contain 708 events and live JSON contains 709 (one binary disagreement after a 24-hour LT revision). The live sim indicator has zero positives. Its forecasts were frozen 08:16–10:06 UTC D−1, later than the nominal 06:30 variant; seven days were a few minutes after the summer 10:00 gate.

Reliability bins and every zone/model/target are in the adjacent CSVs. Under 0.5, undefined AUC/recall/precision are blank/null rather than fabricated zeros. No uncertainty interval or seasonal-generalization claim is made from these two months.

## Physical-price ablation

Pending the corrected-fleet eight-day run. UTC delivery-day clearing is labelled separately from the Athens market-day probability evaluation. Both physical arms include analyst patch ac0ab5bfe079; no pre-fix numbers enter final tables.
