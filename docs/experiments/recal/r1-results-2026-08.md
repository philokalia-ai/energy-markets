# R1 results — the input instrument per zone-target (2026-08-09)

Per the ratified harness R1 policy (dual-target by trust tier), measured on
the frozen VALID window 2026-06-15..07-27, all scored vs ACTUALS.

## Instrument 1: actuals-target LightGBM retrain (train_actuals.py — same
features/vintages as #301, y = hourly actuals)

| zone-target | actuals-ML | TSO fc | old fc-model | verdict |
|---|---:|---:|---:|---|
| GR solar | **274.9** | 525.4 | 468.6 | **ML (−48%)** |
| IT-Sicily solar | **79.4** | 144.6 | 106.6 | **ML (−45%)** |
| IT-Sardinia solar | **31.8** | 46.6 | 43.0 | **ML (−32%)** |
| RO solar | **193.5** | 238.7 | 190.7 | **ML (−19%)** |
| (13 others incl. DK1 wind, GR wind, IT-NORTH/CSOUTH solar) | worse | — | — | TSO fc stays |

The winners are exactly the audited true-overshoot zones. Where the TSO fc
is good, our weather model's variance loses — the policy self-validates in
both directions.

## Instrument 2: trailing debias ON the TSO fc (fc × trailing-30d median
act/fc, 2-day lag, clip [0.5, 2.0]) — for biased-fc zones where the ML lost

| zone-target | raw fc | debiased fc | gain |
|---|---:|---:|---|
| **DK1 wind** | 354.1 | **280.4** | **−21%** |
| IT-CSOUTH solar | 248.9* | 169.0 | −32%* |
| IT-NORTH solar | 251.2* | 216.4 | −14%* |
| GR wind / RO wind / IT-CNORTH | — | — | ≈0, keep raw |

*Caveat: the debias table uses an fc>30 all-hours filter that differs from
the scorecard's row conventions — reconcile before freezing these two in
the package (DK1's is robust across conventions).

## The verdict table feeding R2 packages

- **actuals-ML**: GR/RO/IT-Sicily/IT-Sardinia solar.
- **debiased-fc**: DK1 wind (firm); IT-NORTH/IT-CSOUTH solar pending the
  convention reconciliation.
- **raw TSO fc**: everything else (including NL solar — its actuals are
  garbage and its fc-target design is CORRECT, per the audit).

Artifacts: models in the session scratchpad `models39_actuals/` (NOT
committed to bin/input_models — package ship decisions govern), scorecard
`scorecard_actuals.csv`, trainer committed as
`docs/experiments/input-upgrade/train_actuals.py`.
