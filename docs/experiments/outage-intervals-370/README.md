# Outage readers per time-series interval (issue #370)

**Defect.** An ENTSO-E outage message is stored as one row per time-series
interval; all rows of a message share `(instance_code, version)`. Both outage
readers (`get_day_outages`, `tx_outage_caps`) selected "the latest version"
with `ROW_NUMBER() OVER (PARTITION BY instance_code ORDER BY version DESC)`
and kept `rn = 1` — with ties, whichever interval the scan produced. The
unit's capacity for the day, and a border's NTC cap, were therefore a random
pick among the message's intervals, fixed per process by the day cache.
Measured (docs/experiments/asof-contract §3.4b): 1,445 of 9,634
message-versions overlapping 2026-08-20 disagree on capacity across their
rows (transmission grid: 7,902 of 28,792); two runs of unchanged `main`
gave different DE_LU books and different `tx_outage_caps` totals.

Interval integrity (2026-08-20, 198,530 rows): every row carries
`start/end_time_series_utc`, none outside its message window; consecutive
intervals of a version are contiguous in 188,126 cases, 762 gaps, 8
overlaps, 8 exact duplicates.

**Fix (`fix/outage-intervals-370`).**
- `get_day_outages`: keep every row of the latest version (`version =
  MAX(version) OVER (PARTITION BY instance_code)`, same cv34 gate clause);
  per asset derive the hourly available capacity (MIN over the intervals of
  any message covering the hour, +Inf where none); the day-level value is the
  **12th-smallest hourly value** — the same ≥ 12 h majority rule as before,
  applied on hours: ≤ 11 affected hours ⇒ no outage; a single interval
  covering ≥ 12 h ⇒ its capacity (legacy result); a multi-interval message ⇒
  the level that holds for at least 12 hours. Stale-message override
  unchanged in rule (unit produced > 1 MW after the outage began, trailing
  7 d), now in explicit UTC and from the zero-capacity interval's start.
- `tx_outage_caps`: all rows of the latest version; each border-hour capped
  by the intervals covering it (the existing MIN loop).
- Kill-switch `EUPHEMIA_DISABLE_OUTAGE_INTERVALS` restores the legacy query
  for A/B arms. Legacy and interval paths share the cache key space, so an
  arm is a separate process.

**Determinism.** Three-zone book fingerprints (DE_LU/GR/NO4 × 2026-08-20 and
2025-08-20) plus `tx_outage_caps`: bit-identical across two processes on the
fix; on `main` DE_LU and the caps differed (`output/../asof-contract/output/07_*`).
Legacy vs interval on 2026-08-20: same asset set shape, capacities differ where
messages have several intervals; tx caps total 2.54–2.61 M (legacy, varies)
→ 2.94 M MW·h (interval; less over-capping, because an interval's NTC no
longer applies over the whole message window).

**Tests.** `test/test_outage_intervals.jl`: the majority rule on hourly
values (the 368/90/20/87 example → 87; two 8-h messages → outage; 4-h
zero on a 20-h derate → the derate), fresh-query determinism of both
readers, legacy kill-switch path.

## A/B (paired, live Postgres, Gurobi, 39 zones)

52 Wednesdays 2025-09-03..2026-08-26 (pre- and post-seam), pipelined runner
(`scripts/ab_arm.jl`), labels `ab370_legacy` (kill-switch set) and
`ab370_intervals` in `simulations.energy_prices` at cv37. Scored with
`scripts/score_ab.py` against settled hourly prices on paired days (all 39
zones × 24 h present in both arms). Note the legacy arm is itself one random
draw; its own run-to-run spread (main vs main on the three-zone fingerprint)
is the noise the delta must exceed.

_Results: appended below when the arms complete._
