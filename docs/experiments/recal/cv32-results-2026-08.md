# cv32 — winner-input corrections: validation record (2026-08-09)

Owner-ratified adoption principle: "any ex-ante improvement is kept". The
native-path year validations then set the SCOPE with numbers:

## Full 5-zone set (`cv32_fy`): REJECTED

GR +2.03 / corr −0.031, DK1 +2.68 / corr −0.030 (+ SE3 spillover +1.15),
footprint +0.22 — the oracle's co-adaptation geometry reproduced in the
shipped code path: better INPUTS worsen PRICES where the book's calibration
absorbed the TSO's biases (GR, DK1). The false-collapse benefit (−44%) came
from exactly those corrections and goes back on the shelf with them.

## Reduced set (`cv32b_fy`, IT-Sicily + IT-Sardinia): SHIPPED SCOPE

| | ΔMAE | Δcorr |
|---|---:|---:|
| IT-Sicily | **−0.20** | +0.009 |
| IT-Sardinia | −0.01 | +0.007 |
| footprint | −0.06 | — |
| worst zone anywhere | SE3 +0.17 | (envelope ±3.0 ✓) |
| caps | 8 → 6 | zero new |
| GR / DK1 / RO | 0.00 / −0.09 / — | back to baseline ✓ |

## Standing state

- `simulations.input_corrections` carries ALL five winners' series
  (86,822 rows, D-1-legal); only the Sicily/Sardinia profiles CONSUME them.
- GR/RO solar and DK1 wind corrections are proven at the INPUT level
  (−48%/−19%/−21% vs the TSO on the frozen VALID window) and wait for their
  zones' joint mechanism packages — the measured lesson, twice now: input
  upgrades ship WITH mechanism recalibration or not at all.
- Kill-switch EUPHEMIA_DISABLE_CV32; SEE products untouched structurally;
  extract builder/refresher carry the table.
