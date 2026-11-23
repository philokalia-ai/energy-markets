# epftoolbox SOTA baselines on the tsfm backtest cells (#431)

LEAR-Ens and DNN-Ens from [epftoolbox](https://github.com/jeslago/epftoolbox) (Lago et al. 2021),
run on the same cells as the tsfm 2-year backtest (`../tsfm-2y-backtest/`): Athens market days
2024-11-16..2026-11-15, lead 1, SDAC target, daily recalibration, scored against the D-1 naive and the
Lago weekly naive.

| file | what |
|---|---|
| `epf_data.py` | per-zone epftoolbox frame from the read-only extract: SDAC price, ENTSO-E 6.1.B load forecast, 14.1.D wind+solar forecast; Athens wall-clock grid; ex-ante gap filling |
| `lear_run.py` | LEAR-Ens (windows 56/84/1092/1456), resumable, one process per zone; `--exog full / load / load_res_lag1` (paper inputs / gate-clean variants) |
| `score_sota.py` | common-cell and paired rMAE tables vs the tsfm arms (a), (b), (c) |

Deviations from the package, all documented in `lear_run.py`:
- LassoLarsIC `noise_variance=var(y)`: the paper's scikit-learn AIC, which sklearn ≥ 1.1 refuses for
  the short windows otherwise.
- A scalar `predict` for current NumPy.
- A zero-MAD guard in the Invariant scaling. It is inert wherever the original scaling is finite.

Ex-ante: day D's frame holds prices to the end of D-1 plus the day-ahead forecasts for D. 14.1.D is
due by 18:00 D-1, after the 12:00 gate, so `full` may look ahead. `load` and `load_res_lag1` use only
inputs published before the gate.

```
OMP_NUM_THREADS=1 python lear_run.py --zones DE_LU FR BE NL AT --procs 5 --out OUT/lear [--exog load]
python score_sota.py --lear OUT/lear [--lear-gl OUT/lear-gate-load --lear-gr OUT/lear-gate-reslag1] \
    --zones DE_LU FR BE NL AT --arms lear lear_gl lear_gr a b --md OUT/scores.md
```

Results: em-team report `tsfm-sota-baseline.md`.
