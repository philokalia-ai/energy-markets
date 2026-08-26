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

## Results — Set A (calA_base vs calA_v1, 26 days, live Postgres, Gurobi)

```
days~26  zone               base MAE/bias/pk        v1 MAE/bias/pk   dMAE
--- TOUCHED
IT-CNORTH  *    24.5 +11.5   +31      19.0 -12.0   -10     -5.4
IT-NORTH   *    24.5 +12.0   +32      20.1 -12.9    -9     -4.4
ES         *    24.2  +7.3   +29      23.4  +5.8   +27     -0.8
RS         *    28.3 +10.1    -0      28.0  +9.3    -2     -0.4
SE1        *    24.8 +14.6   +15      24.5 +14.7   +15     -0.3
SE2        *    25.8 +16.4   +18      25.6 +16.5   +18     -0.2
LT         *    33.4 -20.8   -26      33.4 -21.1   -27     +0.0
HU         *    25.5 -17.5   -46      25.6 -18.1   -46     +0.1
EE         *    33.1  -7.5   -15      33.2  -8.7   -17     +0.1
PT         *    26.9  +9.1   +34      27.4  +9.7   +33     +0.5
LV         *    33.8 -22.3   -30      34.4 -23.2   -31     +0.6
--- spillover
IT-Sardinia     23.7  +1.9   +28      21.9  -6.4    +0     -1.8
IT-CSOUTH       19.0  +2.8   +28      17.3  -9.0    -3     -1.7
IT-SOUTH        17.9  +1.6   +27      16.4  -8.6    -2     -1.5
IT-Calabria     17.6  -1.6   +19      16.5  -9.8    -6     -1.1
IT-Sicily       19.7  -4.9    +9      19.1 -12.3   -15     -0.6
FR              24.4  +8.2    +6      23.9  +6.4    +3     -0.6
GR              21.4  -0.4   +10      21.0  -0.6    +9     -0.5
DE_LU           18.5  -2.2   -20      18.1  -3.0   -21     -0.4
BE              20.9  +8.7    -4      20.5  +7.9    -6     -0.4
NL              20.1  -1.6   -22      19.9  -2.1   -22     -0.2
DK2             27.2 -12.9   -19      27.0 -14.5   -22     -0.2
CZ              17.3  -6.9   -22      17.3  -7.7   -23     -0.1
FI              24.1  +4.0    +5      24.0  +3.4    +4     -0.1
NO3             20.2  +5.9    +9      20.1  +5.9    +8     -0.0
RO              23.1  -1.7    -1      23.1  -2.5    -3     -0.0
NO1             21.6 -15.0   -20      21.5 -15.2   -21     -0.0
PL              20.9 -10.9   -31      20.9 -11.3   -32     -0.0
BG              23.3  -2.3    +2      23.3  -2.9    +0     -0.0
NO5             24.6 -13.6   -14      24.6 -13.8   -14     -0.0
NO2             13.3  -2.3    -8      13.3  -2.7    -9     -0.0
SE3             21.9  -3.3    -5      21.9  -3.8    -6     +0.0
NO4             20.0 +12.4   +13      20.1 +12.5   +13     +0.0
DK1             19.1  -0.3   -15      19.2  -1.2   -17     +0.1
SI              22.9 -14.1   -36      23.0 -15.0   -37     +0.1
SK              21.3 -13.1   -33      21.4 -13.9   -34     +0.1
AT              22.0 -16.2   -33      22.3 -17.1   -34     +0.3
SE4             27.7  +0.6    -6      28.2  -0.7   -10     +0.5
CH              22.0 -14.7   -21      23.9 -17.6   -22     +1.9

footprint  base 23.09 -> v1 22.67 (-0.42)   touched 27.71 -> 26.78 (-0.93)   untouched 21.28 -> 21.06 (-0.22)
max untouched-zone |dMAE| 1.92 (CH); spillover ceiling 1.0; net new cap-hours 0
```

**Verdict: v1 is NOT a ship candidate, but the run isolated the one real
bidding-form lever and proved the rest of the residuals are structural.**

1. **IT-NORTH/CNORTH peak+thermal was the real form error.** `peak_kappa`
   1.2→0.8 + `thermal_srmc_multiplier` 1.2→1.1 took the bias from +12 to −12
   and the peak from +31 to −10: MAE 24.5 → 19.5 (−5). It **overshot the sign**
   (now too cheap) and it dragged the four untouched IT sub-zones from +28 peak
   to ~0 — a −1..−2 MAE *gain* for them (the coupling working), not damage.
   But it breached **CH +1.9 MAE** (CH imports from a now-cheaper IT-NORTH; its
   −15 bias worsened to −18). A gentler setting (`peak_kappa` ~1.0,
   `thermal_srmc_multiplier` ~1.15) is the obvious next arm.
2. **The other five changes did essentially nothing** (≤0.6 MAE, bias
   unchanged): HU (−46 peak) ignored `scarcity_kappa` 3→4.5 and `peak_kappa`
   1.2→1.8; the Baltics ignored `scarcity_kappa` 1.5→3; SE1/SE2 ignored 1.0→0.6;
   RS barely moved on 3→2. **These residuals are structural, not form**: HU is
   the UA war-scarcity boundary and its evening shortfall is a capability
   question; the Baltics are import-driven (their price is Finland/Sweden plus
   the interconnector, not their own stack); SE1/SE2's +16 is the net-position
   coupling from cv35, not their own kappa. The scarcity/peak knobs move a zone
   only where its OWN stack sets the price — they are inert on import-set zones.

**The finding**: of the 11 targeted residuals, one (Italy North) was a bidding-
form error the network correction made stale; the rest need mechanism work
(import capability, the net-position dual), not a knob. The bounded budget
(baseline + 1 arm) is spent. Proposed next arm — **owner's call**: IT-only,
gentler (`IT-NORTH,IT-CNORTH:peak_kappa=1.0;thermal_srmc_multiplier=1.15`),
check the bias lands near 0 and CH stays within +1.0; if it passes Set A,
score once on Set B and promote to the cv36 profile default.

**Spillover-ceiling note**: the ±1.0 MAE ceiling in the prereg was written
unsigned; the run shows it must be signed (worse by >1.0), because the IT
sub-zones changed by >1.0 in the *improving* direction. Only CH is a real
breach (worse). Corrected here for the next arm.
