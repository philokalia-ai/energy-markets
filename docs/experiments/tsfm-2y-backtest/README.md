# 2-year Timestral + physics backtest (#431)

Lead 1, SDAC target, D-1 naive, Athens market days 2024-11-16 .. 2026-11-15, 39 zones. Offline:
the read-only DuckDB extract (`euphemia-live-20261115.duckdb`), no DB writes.

Arms:

- **(a) Timestral alone.** `run_tsfm.py --mode pregate0630`: the production `overlay()` of
  `bin/emit_tsfm_overlay.py` in pre-gate mode. The context is 8,192 h of settled prices strictly
  before D (`prices_duckdb`, EUPHEMIA_DA_INPUT default `highest_seq`), with issue time D-1 06:30 UTC.
- **(b) cv44 physics.** The offline cv44 backfill: one CSV per market day (zone, time, price).
- **(c) Timestral + physics, as live.** `run_tsfm.py --mode postsim`: the same `overlay()` in post-sim
  mode (what `bin/emit_tsfm_refresh.sh` runs).
  - The lead-1 physics is a known-future covariate.
  - The runner passes 60 days of sim history.
  - Each physics day stands in for the sim made at D-1 06:30 UTC, so `sim_known` sees D and earlier
    days only.
  - A day runs once its full 60-day physics history exists. `--loop` keeps scanning while the
    physics run is still landing days.

Each (mode, day) produces one CSV. Writes are atomic, and per-day claim files let several runner
instances share an output root. Run the jobs pinned with `taskset`; weights load from the HF cache
with `HF_HUB_OFFLINE=1`.

```
taskset -c 72-79 python run_tsfm.py --mode pregate0630 --workers 2 --threads 4 --out RESULTS --extract X.duckdb
taskset -c 40-79 python run_tsfm.py --mode postsim --loop --workers 10 --threads 4 --out RESULTS --phys-dir PHYS
python score_2y.py --tsfm RESULTS [--c-root ROOT] [--phys-dir PHYS] [--physics weather|record] --json o.json --md o.md
```

`score_2y.py` follows the physics scorer's conventions and reproduces its numbers:

- actual = `da_target.hourly_actuals(target="sdac")`;
- naive = actual at t-24 h;
- rMAE = MAE / naive MAE on the same cells.

It reports each arm on its own cells and on the common cells, split by pooled, month, region, zone,
and the period before or after the Timestral release (2026-10-15).

Results and the in-sample caveats are in the team report (`em-team/reports/tsfm-2y-backtest.md`).
