# Recalibrating the bidding form on the JAO-corrected network (2026-08-26)

Owner: "redo a calibration on how to bid", after cv35 (JAO flow-based capacity)
merged.

## Why now, and the framing

Most of the per-zone `scarcity_kappa` / `peak_kappa` / `thermal_srmc_multiplier`
values were fitted at cv14–cv17 to make prices right **against a network that
gave the flow-based zones phantom or missing capacity**. cv35 replaced that with
the market's own maxBEX + net positions, so a zone's coupled price is now set
correctly by imports — and the old bidding-form knobs, which had been
compensating, are stale. This is a recalibration of the FORM (how a zone bids
into scarcity and the peak), not of the network. It is targeted at the zones
where cv35's own residual is a bidding error, judged where it acts (the peak /
scarcity hours), not a blind 39-zone sweep.

## Evidence — cv35 residuals on Set A (odd ISO weeks of the 52 Wednesdays, 26 days)

Two opposite patterns the corrected coupling exposes:

- **Peak OVER-bidding** (too expensive at the evening peak now that imports
  couple the zone down): IT-NORTH/CNORTH bias +12, peak +30; ES/PT +7/+8, peak
  +27/+32; SE1/SE2 +15/+16, peak +16/+19; RS +10.
- **Peak UNDER-bidding** (too cheap): HU −17.5, peak −46; LV/LT/EE −8..−23;
  DK2 −14; NO5 −14.

## Sets and gate (kept as discipline, not ceremony)

- **Set A** (calibrate): odd ISO weeks → 26 Wednesdays 2025-07..2026-06.
- **Set B** (held out, scored ONCE, only if an A candidate passes): even ISO
  weeks → 26 Wednesdays. Not touched until Set A shows a candidate.
- Judged per zone at the hours the change acts (peak 17–20, morning 6–9) AND on
  the footprint, with the **untouched zones as the collateral guard**: an
  untouched zone must not move more than ±1.0 MAE (spillover ceiling) — the
  cv18 lesson that coupled form changes leak.
- Baseline = `calA_base` (this branch, no overrides) on the same 26 days and
  data, so it is a same-code baseline (not the cv34-labelled A/B arms).

## Arm 1 (`calA_v1`) — the combined per-zone form change

`EUPHEMIA_PROFILE_OVERRIDES` (runtime, worker-safe; inert when empty):

| zones | change | rationale |
|---|---|---|
| IT-NORTH, IT-CNORTH | `peak_kappa` 1.2→0.8, `thermal_srmc_multiplier` 1.2→1.1 | +30 peak over-bid |
| ES, PT | `peak_kappa` 1.2→0.8 | +30 peak over-bid |
| SE1, SE2 | `scarcity_kappa` 1.0→0.6 | +16 over-bid (net-position coupling) |
| RS | `scarcity_kappa` 3.0→2.0 | +10 over-bid |
| HU | `scarcity_kappa` 3.0→4.5, `peak_kappa` 1.2→1.8 | −46 peak under-bid |
| LV, LT, EE | `scarcity_kappa` 1.5→3.0 | −8..−23 import-scarcity under-bid |

Disjoint zones, so each is attributed on its own; spillover measured on the
rest. Gate: the touched zones improve (MAE and peak bias toward 0) on Set A,
no untouched zone worse than +1.0 MAE, no new cap hours. A pass → the same
overrides scored once on Set B; if it holds, they are promoted from the ENV
string into the zone profiles as the cv36 default.

## Budget

Bounded first pass: baseline + arm 1 on Set A only (2 × 26 Gurobi days,
~1.5 h). No Set B, no second arm, until Set A is read. Reported with the
per-zone table; the next arm (or the ship) is the owner's call on the numbers.

## Results

(appended after the Set-A run.)
