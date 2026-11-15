# Scenario exercises — the cv31 ledger (data center & cold ironing)

## cv43 rerun (Nov 2026): data center, cold ironing, "bring your own power"

Rerun on **cv43** (feed-anchored Italian fleet, in-merit truthing, deterministic
JAO scaling), Julia 1.13.4, HiGHS 1.27 (canonical per-period decomposition), the
offline extract of 2026-11-14 (read-only). Driver: `eu43_scenarios.jl`. BYOP
ledger: `scn_byop.py`. DC and cold-ironing ledgers: `scn_analysis.py`
(unchanged). Each arm is paired with a **fresh `eu43_base`** cleared by the same
code; no stored cv43 record exists.

**Sampling and coverage.** To fit one night of compute, every arm runs on a
deterministic stratified day sample, not the full window:
- **Stride 4:** every 4th day of 2024-07-01..2026-06-29, 183 days covering all
  seasons and weekdays. Used for base, DC and BYOP s = 0/50/100 %.
- **Stride 4, year 1 only:** the sample days ≤ 2025-06-30, 92 days (the AIS
  window). Used for cold ironing.
- **Stride 8:** every 8th day, 92 days, a subset of the stride-4 days. Used for
  the s = 150/200 % bracket arms.

Every saved day solved 24/24 periods optimal, with 0 failed days. **€ sums cover
the sampled days only:** multiply by 4 (stride 4) or 8 (stride 8) for a
full-window estimate. Price Δs are means and need no scaling. Paired cells are
inner-joined (zone, hour); BYOP tables use complete days only (39 zones,
≥ 24 h). The stride-4 DC ledger reproduces the cv37 full-window run below
within 2 % (GR +6.98 vs +7.10 €/MWh; extra cost ×4 ≈ €1,556m vs €1,555m), so
the sample is representative.

### GR data center +574 MW (`eu43_dc574` − `eu43_base`)
183/183 days, 4,392 paired hours, 171,044 zone-hour cells.

| | value |
|---|---|
| GR LW Δ | **+6.98 €/MWh** (base 94.19) |
| EU-wide LW Δ | +0.289 €/MWh (+0.33 %) |
| extra cost to everyone else (sample) | **€388.9m** (GR 178.1, outside GR 210.8); ×4 ≈ €1.56bn / 2 yr |
| DC's own bill (sample) | 2.52 TWh, €251.0m (€234.1m at baseline prices) |
| the ledger | **every €1 the DC spends raises others' bills by ~€1.55** |

Spill: BG +2.73, RO +1.84, RS +1.09, IT-SOUTH +0.28; all other zones ≤ +0.23 €/MWh.

### Pan-EU cold ironing, FLOOR (`eu43_ops_floor_paneu` − `eu43_base`)
92/92 days (year 1), 2,208 paired hours, 86,015 cells.

| | value |
|---|---|
| EU-wide LW Δ | **+0.166 €/MWh** (+0.19 % on 88.48) |
| extra cost to everyone else (sample) | **€111.7m** (GR 7.0, outside GR 104.7); ×4 ≈ €447m / yr |
| ships' bill (sample) | 0.615 TWh, €50.5m (OPS-weighted €82.08/MWh); ×4 ≈ 2.46 TWh |
| the ledger | **every €1 of shore power raises others' bills by ~€2.21** |

Top per-MWh: IT-Sardinia +0.84, GR +0.54, IT-CSOUTH +0.40, IT-CNORTH +0.40,
ES +0.39 (largest €, 23.1m), IT-SOUTH +0.35, PT +0.31. Vs cv37 (365 d): EU LW
+0.139 → +0.166 and multiplier 1.87 → 2.21. The cause is not attributed: the
model and the sample both differ.

### "Bring your own power": the DC brings a share s of its load as a new GR CCGT
**Setup.** The DC (+574 MW flat) plus a new **merchant** CCGT in GR that offers
s × 574 MW every hour (nameplate = offered / 0.90 availability) at its own
SRMC = TTF/0.59 + 0.202/0.59 · EUA + 2 €/MWh. That is the fleet's gas formula
with an H-class efficiency, using the same ex-ante closes. It enters through
the `extra_orders` hook on both passes.

**Question.** At which s is the GR load-weighted price with DC + plant no higher
than the no-DC baseline ("lower than today")? Also: the EU-wide consumer cost at
each s.

Stride-8 subset, **89 complete common days** across all arms, 2,136 GR hours.
€ sums cover those 89 days.

| s | GR LW Δ (€/MWh) | EU LW Δ | EU extra cost €m | GR €m | outside GR €m | plant TWh | plant CF |
|---|---|---|---|---|---|---|---|
| 0 % (DC only) | +6.96 | +0.273 | +178.5 | +86.6 | +91.9 | 0 | — |
| 50 % | +4.82 | +0.187 | +122.1 | +60.0 | +62.1 | 0.41 | 0.68 |
| 100 % | +3.04 | +0.111 | +72.3 | +37.8 | +34.5 | 0.80 | 0.66 |
| 150 % | +1.42 | +0.038 | +24.8 | +17.6 | +7.2 | 1.18 | 0.64 |
| 200 % | **−0.22** | **−0.031** | **−20.2** | −2.7 | −17.5 | 1.54 | 0.63 |

(The stride-4 sample, 175 complete days, gives +6.97 / +4.85 / +3.09 for
s = 0 / 50 / 100 %, which agrees with the subset to within 0.05 €/MWh.)

- **s\* ≈ 193 %** (linear interpolation between the bracketing arms 150 % and
  200 %). A merchant CCGT must offer about **1.9× the DC's load** (~1,110 MW,
  ~1,230 MW nameplate) before the Greek price is no higher than today's.
- The EU-wide consumer cost crosses zero earlier, at ≈ 178 % (interpolated).
- **Why ~2×:** the plant runs only when the GR price exceeds its SRMC (capacity
  factor 0.63–0.68, falling as it grows). In the other third of hours the DC is
  an unhedged +574 MW load.
- **Merchant vs behind the meter:** the arms measure the **merchant** case. If
  the plant were **behind the meter** (self-supply netted against the DC load
  whenever the DC runs), s = 100 % gives Δ ≈ 0 by construction, and "lower than
  today" then requires s > 100 % with the surplus sold into the market.
- Plant dispatch in `scn_byop.py` is inferred from the GR clearing price vs the
  plant's SRMC (marginal hours counted half), not read from the solver.

**Not run:** s = 25 % / 75 % (refine the curve inside 0–100 %, irrelevant to s\*).
**Reproduce:** see the header of `eu43_scenarios.jl` (`SCN_ARMS`, `SCN_STEP`,
`SCN_SOLVERS`/`SCN_BOOKS`/`SCN_INFLIGHT`). Then run:

```bash
python3 scn_analysis.py RESULTS EXTRACT eu43_base:43 eu43_dc574:43 2024-07-01 2026-07-01 dc574
python3 scn_analysis.py RESULTS EXTRACT eu43_base:43 eu43_ops_floor_paneu:43 2024-07-01 2025-07-01 ops ops_hourly_eu_floor_2023H2_2025H1.csv.gz
BYOP_ARMS=eu43_dc574,eu43_byop_s50,eu43_byop_s100,eu43_byop_s150,eu43_byop_s200 python3 scn_byop.py RESULTS EXTRACT 0.59 43
```

---

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
