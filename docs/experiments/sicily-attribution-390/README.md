# Sicily, 24 February 2026: the spike is a silent registry read failure

**Date:** 2026-09-13 · **Issue:** #390 §2 (cv39 review §2, cv40 review "Sicily:
a three-day attribution run") · **Verdict:** explained, repaired with a guard,
**no calibration change**

## The cluster

The cv39 record priced IT-Sicily at €541–932/MWh on 24 February 2026, 17:00–20:00
UTC, against a settled €124–148 — a four-hour MAE of **€564.43**, the largest
outlier in the 795-day record.

## What the book actually did

From the cv39 book capture (`data/backfill_books_cv39/2026-02-24.parquet`), at
18:00 UTC:

| | MW | €/MWh |
|---|---:|---:|
| demand, firm | 2,459.8 | 3,000 (cap) |
| demand, elastic | 50.2 | 250 |
| demand, export to Malta (out-of-footprint, fixed schedule) | 134.8 | 3,000 (cap) |
| supply, RES | 214.3 | 1 |
| supply, **AGG**-IT-Sicily-Fossil_Gas srmc_base | 574.8 | 97.65 |
| supply, **AGG**-IT-Sicily-Hydro_Pumped_Storage | 206.0 | 149.90 |
| supply, **AGG**-IT-Sicily-Fossil_Oil srmc_base | 74.3 | 176.60 |
| supply, gas peak tranches 2/3/4 | 209.0 / 156.8 / 104.5 | 515.57 / 613.78 / 785.63 |
| supply, **oil peak tranche 2 — the price-setting offer** | 27.0 | **932.44** |
| supply, oil peak tranches 3/4 | 20.3 / 13.5 | 1,110.04 / 1,420.85 |

The clearing price €932.44 is exactly the oil peak-tranche-2 offer. Working back
through the offer construction (`price = gmc × mⱼ × scarcity`, tranche
multipliers 0.95/1.05/1.25/1.60):

- gas SRMC × the 1.20 Italian thermal multiplier = €102.79/MWh;
- 515.57 / (102.79 × 1.05) ⇒ **scarcity multiplier 4.78**;
- 4.78 = 1 + 3·max(0, 1.4 − margin)² + 1.2·norm_demand⁴ at the evening peak
  ⇒ **margin ≈ 0.47**, i.e. dispatchable capacity ≈ **1,150 MW** against a net
  demand of 2,431 MW.

## The missing MW

Every supply owner in that book is an `AGG-…` block — an **aggregate fleet
completion** block, not a unit. IT-Sicily has **zero unit-level owners** in the
cv39 book for 24 February, and 12–15 on every other February day:

| market date | unit owners | aggregate owners | offered supply (Σ MW over slots) |
|---|---:|---:|---:|
| 2026-02-23 | 13 | 0 | 92,310 |
| **2026-02-24** | **0** | **3** | **33,265** |
| 2026-02-25 | 14 | 0 | 99,624 |

The registry query returned nothing, and `create_merit_order_book` fell through
to aggregate completion at roughly a third of the zone's capability without
saying so. Re-reading the same zone-day today: **14 units, 3,598 MW installed,
3,352 MW dispatchable, margin 1.38, scarcity multiplier 2.20.**

So the shortage is not physical. Reality for that hour: Sicily generated
**1,576 MW** (752 gas, 391 pumped storage, 334 wind, 99 other) and imported
**990 MW** over Calabria–Sicily; the model, once it reads its fleet, offers
3,352 MW dispatchable and imports 1,028 MW against a 1,050 MW limit. The border
**was** genuinely congested — settled IT-Sicily decoupled from IT-Calabria
(148.02 vs 132.90 at 18:00) — but a congested Sicily with its own fleet prices
at €161, not €932.

## This is not one zone, and not one day

Auditing all 795 days × 39 zones of the cv39 book capture for "zero unit owners
in a zone that normally has ≥ 5": **33 zone-days**, and they cluster on four
market days —

| market day | zones with a collapsed registry read |
|---|---|
| 2024-09-12 | BE, CH, CZ, ES, GR, IT-CNORTH, IT-CSOUTH, NO3, NO4, PT, SE1, SE4 (12) |
| **2026-02-24** | BE, EE, GR, IT-CNORTH, IT-CSOUTH, IT-SOUTH, **IT-Sicily**, NL, SE3 (9) |
| 2026-02-26 | DE_LU, DK2, IT-CSOUTH, SE2 (4) |
| 2024-09-08 | DK2 (1) |
| 2025-08-29 … 09-04 | EE (7) — a genuine registry gap, supply 0 |

Nine zones failing on the same market day is a read-time failure, not a property
of any zone: `entsoe.production_and_generation_units` is re-ingested wholesale
(every one of IT-Sicily's 470 rows carries `update_time_utc` of 2026-09-13
09:16–09:18), and a backfill that reads during a reload sees an empty table for
whichever zone-days it happens to be building.

**Cost in the record:** those 26 zone-days that have cv39 prices score a mean
MAE of **32.34** against the record's 24.96, with four zone-days over €290 peak
error and IT-Sicily's 119.80 / €784 the worst.

## The re-clear (23–26 February 2026, 39 zones, Gurobi)

Same footprint, same code as this branch, today's registry:

| cells | cv39 MAE | re-clear MAE | Δ |
|---|---:|---:|---:|
| collapsed zone-days (312) | 32.44 | **15.24** | **−17.20** |
| every other zone-day on those days (3,432) | 19.35 | 19.47 | +0.12 |

The control group is flat, which is what makes the first row attributable to the
registry read rather than to the code that changed between cv39 and here.

Per collapsed zone-day: IT-Sicily 119.80 → 12.00, GR 49.34 → 29.50, IT-CNORTH
41.59 → 13.58, IT-SOUTH 41.46 → 11.99, IT-CSOUTH 33.02 → 12.95; the 26 February
ones are flat (DE_LU 16.66 → 18.24, DK2 14.52 → 16.15), which fits — a zone with
161 registry units loses less to aggregate completion than one with 14.

And the cluster itself:

| hour UTC | cv39 | re-clear | settled |
|---|---:|---:|---:|
| 17:00 | 567.62 | 176.60 | 142.44 |
| 18:00 | 932.44 | 161.09 | 148.02 |
| 19:00 | 773.45 | 147.20 | 142.51 |
| 20:00 | 541.19 | 120.76 | 124.03 |
| **4-hour MAE** | **564.43** | **13.80** | |

## The repair

A guard, not a calibration (`src/generators/registry.jl`): when the registry
query returns **zero** units, ask one more question — does this zone have
registry rows anywhere in the surrounding fortnight? If it does, the empty read
is a failed read and `get_generators` raises, naming the zone and day. If it
does not, the zone genuinely has no registry coverage (EE for a week in 2025,
and small zones) and the aggregate-completion path runs as before, with a
warning. `EUPHEMIA_ALLOW_EMPTY_REGISTRY=1` restores the old silence.

This cannot hide genuine scarcity: nothing about the offer curve, the scarcity
margin or any threshold moved. A day that really is tight still prices tight;
a day whose inputs failed to load now stops instead of inventing a shortage.

Tests: `test/test_registry_guard.jl`.

## What is NOT claimed, and what is left

- **The record is not repaired.** cv39 still carries the 26 defective zone-days.
  Re-clearing four market days is minutes of compute, but it would mix vintages
  inside the canonical record — a labelled refill is the owner's call.
- **The scarcity margin ignores import capability in Italy.** `ITALY_PROFILE`
  has `scarcity_import_credit = 0`, while CONTINENTAL and BALTIC set it to 1.0
  for exactly this reason ("the scarcity margin ignored those imports and priced
  +78–87"). IT-Sicily imports ~40% of its energy over a 1,050 MW border it
  reaches; its margin is computed from domestic capacity alone. On 24 February
  this did not matter (margin 1.38 is above the 1.4 threshold only just, and the
  markup was 2.20 = essentially the peak term), but it is a live structural gap.
  Measuring it needs its own arm and its own days — **not** merged into this
  attribution.
- **Malta's export enters as cap-priced firm demand** (134.8 MW at €3,000 in the
  hour above), the treatment already identified as wrong for the Nordic
  flow-based borders and fixed there with `import_only_counterparties`. Also a
  separate arm.
