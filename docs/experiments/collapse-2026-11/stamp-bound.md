# Gate-time proxy: timestamp-qualified bound

Fixed held-forward predictions, 2026-09-14..11-13. Subsets are selected by source timing only; no refit or threshold tuning. All probabilities below use the same 0.5 threshold. All test delivery dates are already after the audited genuine-load-stamp seam, so the era restriction alone removes no time leakage. The strict row requires load, solar and wind all present and their entire latest stored revisions strictly before 10:00 UTC D−1.

| Subset | Model | n | ≤0 | Brier | Log-loss | AUC | Recall | Precision | FP rate |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| All test cells | pre-gate 06:30 | 57111 | 743 | 0.0098 | 0.0412 | 0.9525 | 0.2288 | 0.5986 | 0.0020 |
| All test cells | gate latest proxy | 57111 | 743 | 0.0080 | 0.0302 | 0.9831 | 0.5451 | 0.6299 | 0.0042 |
| Genuine load-stamp era | pre-gate 06:30 | 57015 | 743 | 0.0098 | 0.0412 | 0.9525 | 0.2288 | 0.5986 | 0.0020 |
| Genuine load-stamp era | gate latest proxy | 57015 | 743 | 0.0080 | 0.0303 | 0.9830 | 0.5451 | 0.6299 | 0.0042 |
| Load stored revision <10:00 | pre-gate 06:30 | 35886 | 310 | 0.0081 | 0.0359 | 0.9306 | 0.1161 | 0.3333 | 0.0020 |
| Load stored revision <10:00 | gate latest proxy | 35886 | 310 | 0.0069 | 0.0271 | 0.9767 | 0.3613 | 0.5000 | 0.0031 |
| Load+solar+wind stored revisions <10:00 | pre-gate 06:30 | 877 | 0 | 0.0000 | 0.0001 | — | — | — | 0.0000 |
| Load+solar+wind stored revisions <10:00 | gate latest proxy | 877 | 0 | 0.0000 | 0.0002 | — | — | — | 0.0000 |

RES update_time belongs to the combined D−1/intraday/current row. A late stamp cannot recover the earlier D−1 value. A whole row already last updated before issuance is a conservative sufficient availability bound, not a D−1 publication timestamp. This table bounds test-feature timing; the original latest-revision training history is not refit here, and full historical source-version proof remains unavailable. Ex-Italy results and threshold-0.3 counts are retained in stamp-bound.json.
