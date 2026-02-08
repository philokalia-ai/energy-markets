# Price Validation: Simulated vs ENTSO-E Day-Ahead Prices

**Date**: 2025-12-10
**Mode**: Single-zone market clearing (`uc_based`, `merit_order` strategy, Gurobi solver)
**Code version**: 6

## Overall Statistics (40 matched zones)

| Metric | Value |
|--------|-------|
| MAE | 34.2 EUR/MWh |
| RMSE | 43.1 EUR/MWh |
| Bias | -3.51 EUR/MWh (slight underestimate) |
| Correlation | 0.49 |
| Actual avg | 87.22 EUR/MWh |
| Simulated avg | 83.71 EUR/MWh |

## Per-Zone Comparison

| Zone | Sim Avg | Actual Avg | Diff | Sim Range | Actual Range |
|------|---------|------------|------|-----------|--------------|
| AT | 154.76 | 119.37 | +35.39 | 100.48 - 157.74 | 84.49 - 156.10 |
| BG | 100.19 | 120.39 | -20.20 | 100.19 - 100.19 | 80.73 - 171.05 |
| CH | 33.59 | 116.89 | -83.30 | 16.50 - 34.33 | 101.04 - 130.10 |
| CZ | 101.99 | 97.80 | +4.19 | 100.19 - 157.74 | 65.45 - 146.72 |
| DE_LU | 105.79 | 81.63 | +24.16 | 100.19 - 157.74 | 28.44 - 115.68 |
| DK1 | 112.94 | 54.64 | +58.30 | 112.94 - 112.94 | 25.74 - 87.41 |
| DK2 | 122.01 | 50.80 | +71.21 | 112.94 - 167.34 | 10.41 - 87.41 |
| EE | 181.91 | 77.55 | +104.36 | 181.91 - 181.91 | 10.39 - 256.21 |
| ES | 103.39 | 103.27 | +0.12 | 100.48 - 157.74 | 81.00 - 125.68 |
| FI | 112.94 | 40.05 | +72.89 | 112.94 - 112.94 | 10.39 - 104.14 |
| FR | 88.08 | 68.93 | +19.15 | 34.33 - 100.48 | -0.01 - 107.20 |
| GR | 86.46 | 107.35 | -20.89 | 16.50 - 100.48 | 10.00 - 162.11 |
| HU | 107.73 | 123.13 | -15.40 | 100.48 - 157.74 | 81.97 - 181.39 |
| IT-Calabria | 97.77 | 119.33 | -21.56 | 90.08 - 100.48 | 98.64 - 153.01 |
| IT-CNORTH | 105.25 | 118.78 | -13.53 | 100.48 - 157.74 | 98.64 - 144.88 |
| IT-CSOUTH | 102.27 | 119.54 | -17.27 | 100.48 - 157.74 | 98.64 - 153.01 |
| IT-NORTH | 100.48 | 118.78 | -18.30 | 100.48 - 100.48 | 98.64 - 144.88 |
| IT-Sardinia | 80.25 | 119.54 | -39.29 | 1.10 - 112.94 | 98.64 - 153.01 |
| IT-Sicily | 100.48 | 119.37 | -18.89 | 100.48 - 100.48 | 98.64 - 153.01 |
| IT-SOUTH | 100.48 | 119.40 | -18.92 | 100.48 - 100.48 | 98.64 - 153.01 |
| LT | 2.04 | 77.82 | -75.78 | 0.00 - 2.20 | 10.39 - 256.21 |
| LV | 11.49 | 77.82 | -66.33 | 0.00 - 157.74 | 10.39 - 256.21 |
| ME | 96.70 | 115.46 | -18.76 | 16.50 - 100.19 | 88.51 - 140.00 |
| MK | 147.35 | 114.77 | +32.58 | 100.19 - 167.34 | 85.09 - 151.07 |
| NL | 101.72 | 76.58 | +25.14 | 100.48 - 115.36 | 23.79 - 106.11 |
| NO1 | 15.13 | 56.52 | -41.39 | 0.00 - 16.50 | 26.70 - 67.90 |
| NO2 | 15.13 | 55.62 | -40.49 | 0.00 - 16.50 | 25.47 - 67.96 |
| NO3 | 15.13 | 44.14 | -29.01 | 0.00 - 16.50 | 25.35 - 63.62 |
| NO4 | 18.07 | 19.60 | -1.53 | 0.00 - 157.74 | 11.11 - 27.30 |
| NO5 | 16.60 | 58.49 | -41.89 | 0.00 - 157.74 | 26.94 - 71.19 |
| PL | 112.99 | 109.09 | +3.90 | 112.94 - 115.36 | 84.67 - 151.65 |
| PT | 19.24 | 103.27 | -84.03 | 0.00 - 100.48 | 81.00 - 125.68 |
| RO | 103.36 | 120.39 | -17.03 | 100.19 - 157.74 | 80.73 - 171.05 |
| RS | 152.94 | 116.66 | +36.28 | 100.19 - 157.74 | 94.00 - 140.00 |
| SE1 | 12.72 | 30.31 | -17.59 | 0.00 - 16.50 | 10.39 - 54.68 |
| SE2 | 5.16 | 30.56 | -25.40 | 0.00 - 16.50 | 10.35 - 48.85 |
| SE3 | 40.82 | 34.50 | +6.32 | 34.33 - 78.83 | 10.34 - 52.72 |
| SE4 | 115.90 | 35.94 | +79.96 | 115.36 - 167.34 | 10.43 - 53.89 |
| SI | 152.94 | 113.14 | +39.80 | 100.19 - 157.74 | 83.81 - 144.88 |
| SK | 94.25 | 101.54 | -7.29 | 34.33 - 100.48 | 73.42 - 139.79 |

## Best Matches (|diff| < 10 EUR/MWh)

| Zone | Sim Avg | Actual Avg | Diff |
|------|---------|------------|------|
| ES | 103.39 | 103.27 | +0.12 |
| NO4 | 18.07 | 19.60 | -1.53 |
| PL | 112.99 | 109.09 | +3.90 |
| CZ | 101.99 | 97.80 | +4.19 |
| SE3 | 40.82 | 34.50 | +6.32 |
| SK | 94.25 | 101.54 | -7.29 |

These zones have diverse generation mixes (thermal + hydro/nuclear) and are large enough that cross-border flows are a smaller share of total supply.

## Worst Mismatches (|diff| > 50 EUR/MWh)

| Zone | Sim Avg | Actual Avg | Diff | Likely Cause |
|------|---------|------------|------|--------------|
| EE | 181.91 | 77.55 | +104.36 | Flat price across all hours; small zone with few generators, heavily dependent on imports |
| PT | 19.24 | 103.27 | -84.03 | Hydro-dominated zone; single-zone model underprices because it ignores exports to ES |
| CH | 33.59 | 116.89 | -83.30 | Heavily hydro; cheap local generation but actual prices set by imports from DE/FR |
| SE4 | 115.90 | 35.94 | +79.96 | Small southern Sweden zone; actual prices set by cheap Nordic hydro imports |
| LT | 2.04 | 77.82 | -75.78 | Almost no thermal generation; prices entirely driven by cross-border trade |
| FI | 112.94 | 40.05 | +72.89 | Flat simulated price; actual prices vary with Nordic hydro imports |
| DK2 | 122.01 | 50.80 | +71.21 | Wind-heavy zone; actual prices lower from wind + imports |

## Analysis

**What works well**: The overall price level is close (bias of only -3.51 EUR/MWh, sim avg 83.71 vs actual 87.22). Zones with diverse thermal generation mixes and limited import dependence (ES, PL, CZ, SK) match well.

**Systematic error patterns**:

1. **Hydro-dominated zones underpriced** (CH, PT, NO1-NO5, SE1-SE2): Single-zone clearing sees only cheap hydro and sets the price at hydro marginal cost (~16.50 EUR/MWh). In reality, these zones export heavily and their prices are pulled up toward the importing zones' marginal cost. Multi-zone clearing should fix this.

2. **Import-dependent zones overpriced** (EE, FI, DK1, DK2, SE4): These zones have limited local generation, so the single-zone model prices at the local marginal cost (often expensive gas). In reality, cheap imports from hydro-rich neighbors pull prices down. Multi-zone clearing should fix this.

3. **Flat simulated price profiles** (EE, DK1, FI, BG, IT-NORTH, IT-SOUTH): Some zones show the same price for every hour. This happens when the same generator is marginal all day — the merit order doesn't shift because the supply curve has few steps. More granular generator data (block orders, ramping costs in bids) would help.

## Expected Improvements

- **Multi-zone clearing**: Should significantly improve hydro export zones (CH, NO, SE, PT) and import-dependent zones (EE, FI, DK, SE4) by modeling cross-border price convergence.
- **Iterative UC-MPCC**: Should improve further by feeding cross-border flow information back into unit commitment decisions.
- **Block orders**: Adding minimum income conditions and startup costs to bids would create more realistic price variation within a day.
