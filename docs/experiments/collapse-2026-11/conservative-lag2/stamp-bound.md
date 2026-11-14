# Gate-time proxy: timestamp-qualified bound

Fixed held-forward predictions, 2026-09-14..11-13. Subsets are selected by source timing only; no refit or threshold tuning. All probabilities below use the same 0.5 threshold. All test delivery dates are already after the audited genuine-load-stamp seam, so the era restriction alone removes no time leakage. The strict row requires load, solar and wind all present and their entire latest stored revisions strictly before 10:00 UTC D−1.

| Subset | Model | n | ≤0 | Brier | Log-loss | AUC | Recall | Precision | FP rate |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| All test cells | pre-gate 06:30 | 57111 | 743 | 0.0105 | 0.0459 | 0.9317 | 0.1211 | 0.6164 | 0.0010 |
| All test cells | gate latest proxy | 57111 | 743 | 0.0084 | 0.0326 | 0.9786 | 0.5437 | 0.6322 | 0.0042 |
| Genuine load-stamp era | pre-gate 06:30 | 57015 | 743 | 0.0105 | 0.0460 | 0.9317 | 0.1211 | 0.6164 | 0.0010 |
| Genuine load-stamp era | gate latest proxy | 57015 | 743 | 0.0084 | 0.0327 | 0.9785 | 0.5437 | 0.6322 | 0.0042 |
| Load stored revision <10:00 | pre-gate 06:30 | 35886 | 310 | 0.0079 | 0.0368 | 0.9141 | 0.0290 | 0.3333 | 0.0005 |
| Load stored revision <10:00 | gate latest proxy | 35886 | 310 | 0.0072 | 0.0291 | 0.9709 | 0.3774 | 0.5087 | 0.0032 |
| Load+solar+wind stored revisions <10:00 | pre-gate 06:30 | 877 | 0 | 0.0000 | 0.0001 | — | — | — | 0.0000 |
| Load+solar+wind stored revisions <10:00 | gate latest proxy | 877 | 0 | 0.0000 | 0.0002 | — | — | — | 0.0000 |

RES update_time belongs to the combined D−1/intraday/current row. A late stamp cannot recover the earlier D−1 value. A whole row already last updated before issuance is a conservative sufficient availability bound, not a D−1 publication timestamp. This table bounds test-feature timing; the original latest-revision training history is not refit here, and full historical source-version proof remains unavailable. Ex-Italy results and threshold-0.3 counts are retained in stamp-bound.json.
