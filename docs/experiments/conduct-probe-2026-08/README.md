# Conduct probe (2026-08-26): is the residual physics or conduct?

Owner mode: explore ("think outside the box"), approved "Let's go". Budget:
one pass — dataset + probe models + book inversion, **no re-clearing**.

## Reframing

The program's purpose is evidence about market conduct; cv35 put the
counterfactual on the market's own network (JAO flow-based capacities), so the
residual `settled − counterfactual` is now worth studying as an object, not
chasing as error. The recalibration (recal-2026-08) showed bidding knobs are
inert on import-set zones — so WHAT is the remaining residual? Two independent
probes:

1. **Feature probe (GBM)**: per zone, predict the residual from ex-ante
   features; measure the incremental out-of-sample R² of *conduct* features
   (top-firm share, HHI, RSI, pivotality) over *physics* features (calendar,
   load, RES/import shares, margin, fuels, net position, JAO headroom).
   Grouped 5-fold CV by day. Residual predictable from physics → missing
   mechanism; predictable only with conduct features → markup candidate.
2. **Book inversion**: for each zone-hour, clear the zone's captured
   competitive order book standalone at the *actual* net position; implied
   markup = settled − that price. Studied via *within-zone* structure (peak
   premium vs own off-peak, seasonal), never levels.

## Data and coverage

- 48/52 Wednesdays 2025-07..2026-06 (4 missing book days: 2025-11-12,
  2026-03-18, 2026-06-03, 2026-06-24); 39 zones; 44,928 zone-hours; all with
  settled, cv35 counterfactual (`ab_jao_np`), and actual net position joined.
- Books: `data/web/v1/books/*.parquet` — **cv31 vintage** (per-unit tagged
  ladders; the counterfactual price is cv35 — a stated vintage mismatch,
  second-order for supply-curve shape).
- Actual net positions: `entsoe.physical_flows` BZN↔BZN.
- Firm attribution (`simulations.unit_firms`): **tier 1** = GR 99%, HU 88%,
  BG/RS 86%, FR 83%, RO 75% of named MW; Italy/ES/DE partial (39–61%);
  elsewhere zero → conduct features fall back to owner(unit)-level
  concentration, a lower bound. **Caveat**: non-tier-1 zones lean on synthetic
  `AGG-*` fleet-completion units, so firm-level claims are tier-1 only.

## Known artifacts (stated before results)

- The standalone inversion overstates p_comp for anchored/exporting zones
  (FR nuclear anchor, IT-Calabria) → markup LEVELS are biased low there; only
  within-zone temporal structure is used.
- The pivotal-hours markup split is contaminated by the same artifact (p_comp
  explodes exactly in tight hours) → not used for verdicts.
- `resid` inherits cv35's model error; a conduct verdict needs BOTH probes to
  agree and the physics R² to be low.

## Implied-markup structure (probe 2)

Within-zone peak premium of implied markup (evening 16–19 UTC vs own
off-peak), top of the table: **HU +137** (winter premium +105), **DK2 +63**
(winter +123), **PL +57**, **DK1 +57**, **DE_LU +52**, **EE +47** (winter
+150), **RS +45**. Bottom (negative, consistent with the known IT/ES over-bid
finding): IT zones −64..−124, BG −92, SI −46, FR −42. Full table:
`probe_markup_structure.csv`.

## Feature probe (probe 1) — results

All 39 zones, GroupKFold(5) by day, out-of-sample R².

**Headline: conduct FEATURES add ~nothing out-of-sample anywhere** (mean
ΔR² = −0.02; best RS/NO2 +0.07, SI +0.05, GR +0.03). Static concentration does
not explain the residual — with the honest caveat that within-zone
concentration barely varies in time, so this probe only detects conduct that
*moves* (with outages/RES); a constant markup level is invisible to ΔR² and
shows up in the inversion instead.

**But the residual is strongly PHYSICS-predictable in a specific belt**
(top features margin / res_sh / D): DE_LU 0.58, IT-NORTH 0.59, IT-CSOUTH 0.51,
IT-SOUTH 0.46, NL 0.45, IT-CNORTH 0.44, HU 0.35, PL 0.34, BE 0.33, ES 0.32.
The model leaves systematic, forecastable structure on the table.

## The conduct map (probes joined)

Classes: **tightness-marked** = residual physics-predictable AND settled rises
above the zone's own competitive book at the peak (both probes agree the market
prices tight hours above the competitive stack) · **model-gap** = physics-
predictable but settled is at/below our book (our model over-prices — our
problem, not the market's) · **concentration-linked** = conduct features carry
real OOS ΔR² · **unexplained** = neither.

| zone | klass | r2_phys | d_r2 | top_phys | top_cond | mk_pk_prem | mk_win_prem | resid_pk | piv_share | tier1 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SI | concentration-linked | 0.09 | 0.05 | co2 | rsi | -46.2 | 22.3 | 41.9 | 0.22 | 0 |
| GR | concentration-linked | 0.05 | 0.03 | month | top1_sh | -11.5 | -16.9 | -4.54 | 0.54 | 1 |
| RS | concentration-linked | 0.01 | 0.07 | month | top1_sh | 45.2 | 4.0 | 13.67 | 1.0 | 1 |
| NO2 | concentration-linked | -0.07 | 0.07 | gas | top1_sh | 4.5 | 3.0 | 6.29 | 0.81 | 0 |
| IT-NORTH | model-gap | 0.59 | 0.01 | D | rsi | -64.2 | 9.9 | -38.56 | 0.14 | 0 |
| IT-SOUTH | model-gap | 0.46 | -0.03 | margin | rsi | -73.8 | -53.2 | -29.1 | 0.88 | 0 |
| IT-CNORTH | model-gap | 0.44 | -0.0 | D | rsi | 20.1 | 28.4 | -36.5 | 0.96 | 0 |
| ES | model-gap | 0.32 | -0.01 | month | top1_sh | -21.3 | -16.2 | -19.95 | 0.06 | 0 |
| FI | model-gap | 0.31 | -0.06 | res_sh | top1_sh | 5.3 | 72.5 | -1.86 | 0.24 | 0 |
| IT-Calabria | model-gap | 0.3 | 0.02 | hour | rsi | -124.2 | -26.8 | -15.2 | 0.8 | 0 |
| PT | model-gap | 0.29 | -0.0 | month | hhi | -17.3 | -72.5 | -23.48 | 0.08 | 0 |
| DK1 | peak-premium (weak model signal) | 0.17 | -0.02 | res_sh | hhi | 56.5 | -35.0 | 16.72 | 0.59 | 0 |
| DK2 | peak-premium (weak model signal) | 0.14 | -0.01 | res_sh | top1_sh | 62.7 | 122.8 | 29.7 | 0.2 | 0 |
| DE_LU | tightness-marked | 0.58 | -0.02 | res_sh | rsi | 52.4 | -53.3 | 25.27 | 0.01 | 0 |
| IT-CSOUTH | tightness-marked | 0.51 | -0.01 | margin | rsi | 26.1 | 12.7 | -31.42 | 0.01 | 0 |
| NL | tightness-marked | 0.45 | -0.03 | res_sh | top1_sh | 26.4 | -30.3 | 27.49 | 0.18 | 0 |
| HU | tightness-marked | 0.35 | -0.01 | margin | hhi | 137.2 | 104.7 | 53.66 | 0.31 | 1 |
| PL | tightness-marked | 0.34 | 0.01 | margin | rsi | 56.6 | 6.7 | 40.33 | 0.01 | 0 |
| BE | tightness-marked | 0.33 | -0.09 | res_sh | hhi | 35.3 | -34.5 | 5.09 | 0.03 | 0 |
| EE | tightness-marked | 0.3 | 0.0 | res_sh | top1_sh | 46.5 | 150.4 | 27.15 | 0.32 | 0 |
| SK | tightness-marked | 0.28 | -0.02 | margin | top1_sh | 25.7 | 6.6 | 36.13 | 0.66 | 0 |
| CZ | unexplained | 0.24 | -0.03 | margin | rsi | -26.4 | -33.7 | 27.22 | 0.47 | 0 |
| LT | unexplained | 0.24 | 0.02 | co2 | top1_sh | 18.1 | 137.2 | 39.18 | 0.37 | 0 |
| SE3 | unexplained | 0.22 | -0.03 | gas | hhi | 30.5 | 46.7 | 13.13 | 0.06 | 0 |
| NO3 | unexplained | 0.21 | 0.02 | gas | hhi | -2.7 | 58.2 | -8.42 | 0.12 | 0 |
| RO | unexplained | 0.18 | -0.05 | res_sh | hhi | 20.5 | -12.3 | 9.23 | 0.43 | 1 |
| LV | unexplained | 0.16 | 0.01 | res_sh | top1_sh | 37.4 | 0.4 | 42.07 | 0.31 | 0 |
| IT-Sardinia | unexplained | 0.16 | 0.01 | margin | top1_sh | -120.8 | 32.9 | -30.13 | 0.55 | 0 |
| SE4 | unexplained | 0.14 | 0.01 | res_sh | hhi | 32.0 | 66.2 | 16.08 | 0.0 | 0 |
| SE2 | unexplained | 0.12 | -0.11 | gas | top1_sh | 6.6 | -98.7 | -17.91 | 1.0 | 0 |
| IT-Sicily | unexplained | 0.11 | -0.05 | margin | hhi | 44.2 | -14.1 | -9.79 | 0.06 | 0 |
| NO5 | unexplained | 0.1 | -0.09 | gas | hhi | -39.5 | 38.3 | 14.15 | 0.84 | 0 |
| BG | unexplained | 0.1 | -0.08 | margin | rsi | -91.7 | -10.4 | 3.19 | 0.52 | 1 |
| FR | unexplained | 0.08 | -0.0 | margin | top1_sh | -41.9 | 6.5 | -3.33 | 1.0 | 1 |
| AT | unexplained | 0.07 | -0.0 | imp_sh | top1_sh | -38.1 | 76.3 | 35.62 | 0.32 | 0 |
| SE1 | unexplained | 0.04 | -0.07 | gas | rsi | 5.2 | 34.4 | -15.28 | 0.74 | 0 |
| CH | unexplained | -0.01 | -0.02 | res_sh | hhi | -16.9 | 35.5 | 20.77 | 0.27 | 0 |
| NO1 | unexplained | -0.14 | 0.0 | gas | top1_sh | 28.6 | 93.4 | 16.59 | 0.18 | 0 |
| NO4 | unexplained | -0.16 | -0.0 | month | top1_sh | -13.4 | 65.2 | -14.22 | 0.8 | 0 |

## Findings

1. **The evening-belt residual is a tightness-priced premium** (HU, PL, DE_LU,
   EE, SK, NL, BE): in exactly the hours physics flags as tight, the market
   clears above the competitive counterfactual (HU resid +54 €/MWh at the
   peak; book-implied peak markup +137, winter +105). These probes cannot by
   themselves split "systematic scarcity markup" from "missing scarcity
   mechanism" — but this is the conduct frontier, localized and quantified.
2. **Italy + Iberia are model-gap, not conduct**: residual physics-predictable
   AND settled at/below our book — the model over-prices the peak (matches
   recal-2026-08: the IT peak-tranche step; fix is the graded tranche, cv36).
3. **RS is the one firm-concentration signal** (tier-1 map, EPS ≈94% share,
   ΔR² +0.07 on top1_sh, book peak premium +45).
4. **18 zones unexplained** — mostly small/noisy residuals (Nordic hydro, AT,
   CH): not predictable from anything measured; likely hydrology/reservoir
   features we don't carry, or noise.

## Proposed next steps (owner's call)

- **Sharpen the HU/belt conduct claim**: per-unit marginality analysis in the
  tight hours (the books carry owners; tier-1 firm map for HU), plus the exact
  MPCC net-position dual to rule out residual import mispricing in those hours.
- **cv36 graded peak tranche** for the model-gap zones (already proposed in
  recal-2026-08).
- Nordic hydro features (reservoir levels) for the unexplained Nordics.

Budget spent as stated: one pass, no re-clearing. Scripts + CSVs in this
directory (`probe_build.py`, `probe_gbm.py`, `probe_synth.py`).


# 2-year re-run (2026-08-27, owner: "48 Wednesdays aren't enough")

## What ran

- **729-day cv35 backfill** 2024-07-01..2026-06-30, 39 zones, offline on the
  refreshed DuckDB extract (now carrying `jao.*` and
  `entsoe.unavailability_in_the_transmission_grid`), Gurobi ×4 —
  **729 days/hour**, 82% solver utilization, results in `data/results.duckdb`
  (`multi_zone_eu`/cv35), books captured at the **matching cv35 vintage**
  (`data/backfill_books_cv35`, 729 parquets) — the 48-day run's cv31-book
  caveat is gone. 1 day lost (2024-11-17, 23-period truncation).
- Same two probes on 681,691 zone-hours (settled join 100%, actual-net-position
  join 99.97%).

## Two data corrections found while scaling (both fixed, both matter)

1. **Sub-hourly flows were summed, not averaged**: PT15M border rows counted
   4× in the actual net position — the 48-day run's markup levels were
   inflated for 15-minute borders (HU book peak premium +137 → **+82**
   corrected). Direction of every finding unchanged; sizes now honest.
2. The results writer's positional `INSERT SELECT *` broke against a results
   DB predating a column migration → `INSERT BY NAME` (shipped in this PR).

## The 2-year conduct map

Footprint: mean physics R² **0.45** (0.18 on 48 Wednesdays — the residual is
far more learnable with 15× data), conduct ΔR² **+0.01** (still ~nothing).

| zone | klass | r2_phys | d_r2 | top_phys | top_cond | mk_pk_prem | mk_win_prem | resid_pk | piv_share | tier1 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| NO3 | concentration-linked | 0.65 | 0.06 | month | hhi | -6.3 | 42.9 | -25.14 | 0.59 | 0 |
| AT | concentration-linked | 0.44 | 0.04 | res_sh | top1_sh | -0.4 | 18.6 | 27.13 | 0.24 | 0 |
| NO4 | concentration-linked | 0.43 | 0.06 | gas | top1_sh | -3.0 | 16.7 | -21.42 | 0.25 | 0 |
| NO5 | model-gap | 0.69 | 0.03 | margin | hhi | -6.0 | 49.6 | -7.25 | 0.18 | 0 |
| IT-NORTH | model-gap | 0.68 | -0.0 | D | rsi | -36.8 | -25.5 | -15.53 | 0.05 | 0 |
| ES | model-gap | 0.63 | -0.0 | month | hhi | -16.7 | -15.6 | -15.71 | 0.01 | 0 |
| NO1 | model-gap | 0.59 | 0.02 | np_head_exp | top1_sh | 0.5 | 52.0 | -3.43 | 0.75 | 0 |
| PT | model-gap | 0.58 | 0.01 | month | hhi | -29.4 | -28.3 | -17.55 | 0.0 | 0 |
| IT-CNORTH | model-gap | 0.55 | 0.0 | D | top1_sh | -91.7 | -44.1 | -10.14 | 0.88 | 0 |
| SE3 | model-gap | 0.54 | 0.02 | np_head_exp | top1_sh | 10.1 | 10.4 | -5.88 | 0.59 | 0 |
| SE2 | model-gap | 0.51 | 0.02 | gas | top1_sh | -4.6 | 6.7 | -17.91 | 1.0 | 0 |
| SE1 | model-gap | 0.49 | 0.02 | gas | hhi | 6.0 | 27.6 | -15.52 | 0.24 | 0 |
| CH | model-gap | 0.48 | 0.02 | res_sh | hhi | -2.4 | 44.9 | 15.02 | 0.19 | 0 |
| IT-CSOUTH | model-gap | 0.48 | 0.01 | margin | rsi | -1.8 | -5.2 | -11.02 | 0.01 | 0 |
| FI | model-gap | 0.47 | 0.02 | margin | rsi | 3.8 | -8.1 | -2.39 | 0.37 | 0 |
| SK | model-gap | 0.44 | 0.02 | D | top1_sh | -55.1 | -68.7 | 45.57 | 0.74 | 0 |
| CZ | model-gap | 0.44 | 0.01 | res_sh | rsi | 18.2 | 3.2 | 26.82 | 0.0 | 0 |
| BE | model-gap | 0.44 | 0.01 | res_sh | hhi | 10.5 | -2.3 | 4.43 | 0.01 | 0 |
| FR | model-gap | 0.42 | -0.01 | gas | rsi | -5.7 | 7.0 | -5.1 | 1.0 | 1 |
| RO | model-gap | 0.39 | 0.01 | margin | top1_sh | -35.7 | -61.2 | 30.17 | 0.63 | 1 |
| LT | model-gap | 0.36 | 0.03 | margin | top1_sh | 12.8 | 19.4 | 44.05 | 0.22 | 0 |
| IT-SOUTH | model-gap | 0.36 | -0.0 | margin | rsi | -29.5 | -7.0 | -2.16 | 0.13 | 0 |
| NO2 | model-gap | 0.36 | 0.02 | np_head_exp | top1_sh | 5.0 | 21.4 | -4.67 | 0.57 | 0 |
| IT-Sardinia | model-gap | 0.36 | 0.01 | margin | hhi | -22.9 | 32.1 | -1.43 | 0.02 | 0 |
| SI | model-gap | 0.35 | 0.01 | res_sh | hhi | -17.6 | 18.9 | 46.39 | 0.22 | 0 |
| GR | model-gap | 0.31 | 0.01 | margin | top1_sh | -4.3 | -10.2 | 15.11 | 0.44 | 1 |
| BG | model-gap | 0.28 | 0.01 | co2 | hhi | -35.9 | -9.2 | 22.02 | 0.5 | 1 |
| DE_LU | tightness-marked | 0.65 | 0.0 | res_sh | rsi | 26.6 | 0.8 | 19.23 | 0.02 | 0 |
| PL | tightness-marked | 0.63 | -0.0 | res_sh | rsi | 48.4 | -0.3 | 43.85 | 0.0 | 0 |
| HU | tightness-marked | 0.53 | 0.01 | D | top1_sh | 81.8 | 12.1 | 70.96 | 0.3 | 1 |
| NL | tightness-marked | 0.45 | 0.02 | res_sh | hhi | 42.8 | 8.2 | 25.4 | 0.0 | 0 |
| RS | tightness-marked | 0.45 | 0.0 | imp_sh | top1_sh | 54.8 | 0.4 | 32.0 | 1.0 | 1 |
| DK1 | tightness-marked | 0.39 | 0.01 | res_sh | top1_sh | 33.3 | -15.0 | 13.78 | 0.78 | 0 |
| LV | tightness-marked | 0.33 | 0.02 | nx | top1_sh | 37.6 | -9.3 | 46.21 | 0.16 | 0 |
| DK2 | tightness-marked | 0.33 | -0.0 | res_sh | top1_sh | 30.2 | -4.2 | 30.79 | 0.16 | 0 |
| EE | tightness-marked | 0.28 | -0.01 | res_sh | rsi | 51.6 | 43.5 | 39.09 | 0.18 | 0 |
| IT-Sicily | unexplained | 0.24 | -0.01 | res_sh | rsi | 23.8 | 5.9 | 15.68 | 0.0 | 0 |
| IT-Calabria | unexplained | 0.23 | 0.02 | res_sh | rsi | -43.6 | -7.3 | 10.64 | 0.09 | 0 |
| SE4 | unexplained | 0.18 | 0.02 | np_head_exp | hhi | 25.4 | -8.7 | 3.59 | 0.55 | 0 |


## What survives 15× more data

1. **The tightness-priced belt is confirmed and sharpened**: HU (+82 book peak
   premium, **+71 €/MWh** peak residual), PL (+48/+44), NL (+43/+25), RS
   (+55/+32), DE_LU (+27/+19), DK1/DK2, EE (+52/+39), LV (+38/+46). Physics
   predicts *when*; the book says the market clears *above its competitive
   stack* in exactly those hours. This is the program's central exhibit.
2. **Conduct features stay inert OOS everywhere** (ΔR² +0.01) — whatever
   prices the tight hours, static concentration indices don't time it.
3. **SK/SI/RO/LT re-classified to model-gap** (2y): settled sits above the
   coupled counterfactual at the peak but *below* their standalone books —
   an import-pricing mechanism gap (the net-position dual), not local bidding.
4. **Italy + Iberia stay model-gap** (we over-price; graded tranche = cv36),
   and **AT/NO3/NO4 show small concentration signals** (ΔR² 0.04–0.06,
   owner-level tier — verify before claiming).

## Coverage line

729 days × 39 zones × 24h; 1 truncated day dropped; books cv35; firm tier-1 =
GR/HU/BG/RS/FR/RO; inversion levels still biased for anchored/exporting zones
(within-zone structure only). Scripts and CSVs updated in this directory
(`probe2y_*`).