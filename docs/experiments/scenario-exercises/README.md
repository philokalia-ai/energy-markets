# Scenario exercises — the cv31 ledger (data center & cold ironing)

The two counterfactual demand exercises, **merged and rerun on the current
model (cv31)** via the first-class scenario API (`docs/scenario-api.md`) on the
coupled 39-zone footprint. Earlier iterations (single-zone GR runs, the GR-only
OPS exercise, and the cv16/cv17 EU-coupled results) are superseded: the
single-zone runs were an upper bound without import relief, and GR-only OPS is
a strict subset of the pan-EU exercise. Their write-ups live in this file's git
history (`git log -- docs/experiments/scenario-exercises/README.md`, pre-cv31).

| scenario | clearing_mode | window | hook |
|---|---|---|---|
| GR data center +574 MW | `eu31_dc574` | 2024-07-01..2026-06-30 (730 d) | `Dict("GR" => ZoneScenario(load_modifier = (ts,l) -> l + 574.0))` |
| Pan-EU cold ironing, FLOOR | `eu31_ops_floor_paneu` | 2024-07-01..2025-06-30 (365 d — the AIS window's overlap with the DC one) | per-zone `extra_orders` from `ops_hourly_eu_floor_2023H2_2025H1.csv` (24 zones, 294 TEN-T ports, registry-confirmed >5000 GT passenger ships, demand at the cap) |

## Method — the record is the baseline

Unlike the earlier iterations, **no baseline is re-run**: the scenario arms are
paired against the stored cv31 record (`clearing_mode='multi_zone_eu',
code_version=31` in `data/results.duckdb` — the canonical published
counterfactual). Validity is proven at startup by `eu31_scenarios.jl`'s guard:
one record day is re-cleared with `scenario=nothing` and must match the stored
rows within 1e-9 €/MWh (measured 1.1e-12 — the documented last-ULP
SQL-aggregate class from the record's 50-worker concurrent builds; a real code
change shows at ≥1e-2). Everything else matches the record path: offline
DuckDB extract, HiGHS, scoped `:v3` ex-ante flows, `run_pipelined_backfill`
(50 solver / 10 book workers, ~290–310 days/h).

Day coverage: eu31_dc574 683/730, eu31_ops 349/365 saved; the failures are the
record's own missing days (same source-data/ATC failure mode; record has
681/348 in these windows). All deltas below are computed on inner-joined
(zone, hour) pairs — 680 / 348 common days.

```bash
julia --project=. docs/experiments/scenario-exercises/eu31_scenarios.jl   # guard + both runs (resumable)
python3 docs/experiments/scenario-exercises/scn_analysis.py \
    data/results.duckdb data/extracts/euphemia-live.duckdb \
    multi_zone_eu:31 eu31_dc574 2024-07-01 2026-07-01 dc574
python3 docs/experiments/scenario-exercises/scn_analysis.py \
    data/results.duckdb data/extracts/euphemia-live.duckdb \
    multi_zone_eu:31 eu31_ops_floor_paneu 2024-07-01 2025-07-01 ops \
    docs/experiments/scenario-exercises/ops_hourly_eu_floor_2023H2_2025H1.csv
```

`scn_analysis.py` was validated by reproducing the published cv17 pan-OPS
numbers exactly (EU LW Δ +0.214, €1,110.3m, ships' bill €398.7m / 4.878 TWh)
before being applied to the cv31 labels. Load weights everywhere = the hourly
ENTSO-E D-1 load forecast (the model's own, unmodified demand series).

## Scenario 1 — GR data center +574 MW (Δ = eu31_dc574 − record)

| window | paired h | GR LW Δ €/MWh | GR extra €m | EU extra €m | outside-GR €m |
|---|---:|---:|---:|---:|---:|
| 2024-07..2025-06 | 8,352 | **+7.69** | 376.7 | 910.2 | 533.5 |
| 2025-07..2026-06 | 7,968 | **+7.18** | 332.1 | 659.2 | 327.1 |
| **TOTAL (2 yr)** | 16,320 | **+7.44** | **708.8** | **1,569.4** | **860.6** |

**The data center's own bill:** 9.368 TWh over the paired hours, **€975.1m**
at scenario prices (time-avg €104.09/MWh; at baseline prices it would be
€908.2m — €66.9m of the bill is the price increase it causes itself).

**The ledger:** consumers EU-wide pay **€1,569m** extra so the data center can
buy €975m of energy — **every €1 it buys raises other consumers' bills by
~€1.61**. More than half of the extra cost lands outside Greece, carried down
the SEE coupling corridor and dying at the congested borders beyond it:

| zone | LW Δ €/MWh | extra €m (2 yr) |
|---|---:|---:|
| GR | +7.44 | 708.8 |
| BG | +3.74 | 265.6 |
| RO | +3.12 | 312.9 |
| RS | +1.52 | 97.7 |
| IT-SOUTH | +0.33 | 12.0 |
| HU | +0.28 | 22.1 |
| (all others) | ≤ +0.24 | — |

Versus the cv16 measurement (+8.46 GR Δ on 2025-26): the cv31 model shows a
slightly softer +7.18 on that window — consistent direction, the newer model's
import machinery (cv23 backstops, cv26 DA-preference ATC, cv27 demonstrated
capability) relieves marginally more.

## Scenario 2 — pan-EU cold ironing, FLOOR (Δ = eu31_ops_floor_paneu − record)

One year, 2024-07-01..2025-06-30, 348 paired days:

| | value |
|---|---|
| EU-wide LW Δ | **+0.201 €/MWh** (+0.24% on LW base 84.84) |
| extra cost, EU-wide | **€511.9m** — GR €31.3m, outside GR €480.6m |
| ships' own bill | 2.330 TWh, **€195.5m** (OPS-weighted €83.91/MWh) |
| the ledger | **every €1 of shore power raises other consumers' bills by ~€2.62** |

The multiplier is stronger than the DC's (€2.62 vs €1.61) because the demand
lands in 24 zones at once and lifts many marginals together, while each MWh is
bought at berth-profile prices (overnight-heavy, below the load-weighted
average). Highest per-MWh deltas are the ferry/cruise zones that carry the
demand: IT-Sardinia +0.88, SE4 +0.70, GR +0.64, SE3 +0.55, SK +0.48 — note the
Nordic zones now move (the cv17 run had them ≈0): the cv26/cv27 ATC treatments
transmit the Baltic/Nordic shock where the old intraday-contaminated
capacities blocked it.

### OPS profile provenance (unchanged)

`ops_hourly_eu_floor_2023H2_2025H1.csv` (274,376 rows; zone, UTC hour, MW) is
built by `build_eu_ops_profiles.py` from the `pan-european-cold-ironing-data/`
AIS dataset: 3.57M port-call dwell events over 294 TEN-T ports, GT-binned EMSA
at-berth loads (2.5/5/12 MW), per-call MW × hourly berth overlap aggregated per
bidding zone; explicit UN/LOCODE→zone mapping for multi-zone countries.
**FLOOR** = registry-confirmed >5000 GT passenger ships only (~2,494 GWh/yr
in-footprint); excluded: IE/HR/MT/CY (outside footprint) and non-coupled
island systems (Canaries, Ceuta/Melilla, Madeira/Azores, Corsica, Mayotte,
~540 GWh/yr). Per-country energies validated ±1% against
`eu_cold_ironing_by_country.csv`.

## Caveats

- **Wholesale day-ahead only** — no grid fees, taxes, PPAs, or capacity
  markets on either side of the ledger.
- **OPS floor + full uptake**: undercounts ship coverage but every in-scope
  ship connects (pre-AFIR-phase-in bounds in both directions); container OPS
  not in the dataset.
- **DC is a flat 574 MW** with no demand response and no co-located PPA/RES.
- The record baseline is the ENTSO-E-input (announced-input) counterfactual;
  scenario-on-the-weather-track is not wired into the pipeline scenario path
  (raised as a gap — would need `bin/ml_inputs.jl` threading into the book
  stages).

## cv37 re-run (2026-08-30) — fresh-baseline pairing

Both exercises re-run at cv37 (JAO flow-based network, graded tranches,
wet-adjusted Nordic water values) via `eu37_scenarios.jl`. The record-pairing
guard FAILED at cv37 (re-clearing record day 2025-04-15 differs by up to
23.15 €/MWh on 85/936 cells — run-to-run nondeterminism that crept in between
cv31, which passed at 1e-12, and cv37; open ledger issue). The method
therefore adds a fresh `eu37_base` arm cleared by the same process, and all
deltas pair against it. Results (labels in data/results.duckdb):

- **eu37_dc574** (730 d): GR LW +7.10 €/MWh (+7.4%); EU +0.29 (+0.34%);
  extra consumer cost €1,554.6m/2y (€834m outside GR); DC bill 10.03 TWh /
  €1,019m. Import relief absorbs ~64% of the single-zone impact.
- **eu37_ops_floor_paneu** (365 d): EU LW +0.139 €/MWh (+0.16%); extra cost
  €370.8m/yr; OPS bill 2.44 TWh / €197.8m (€1 of shore power → ~€1.87 to
  everyone else). Top zones IT-Sardinia +0.79, GR +0.60.
