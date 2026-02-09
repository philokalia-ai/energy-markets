# Coupled vs Iterative Coupled Clearing — Price Validation

**Date**: 2025-12-10
**Optimizer**: Gurobi (2 parallel workers)
**Code version**: 6
**Bidding strategy**: merit_order (markup_factor=1.1)

## Run Summary

| Metric | Coupled | Iterative |
|--------|---------|-----------|
| Clearing mode | `multi_zone` | `multi_zone_iterative` |
| Zones cleared | 36 | 36 |
| Total time | 11.1 min | 104.4 min (1.74 hours) |
| Solver time (MPCC) | 22.1s | ~22s per iteration |
| Iterations | 1 | 10 (max, did not converge) |
| Final price change | — | 181.91 EUR/MWh |
| Average price | 61.05 EUR/MWh | 61.49 EUR/MWh |
| Price range | 0.0 - 181.91 EUR/MWh | 0.0 - 181.91 EUR/MWh |

## Convergence

The iterative solver did **not converge** after 10 iterations. The final max price change was 181.91 EUR/MWh (tolerance: 1.0 EUR/MWh). This indicates persistent oscillation in the UC-MPCC feedback loop.

## Price Validation Comparison

Simulated prices compared against ENTSO-E day-ahead prices. MAE = Mean Absolute Error, Corr = Pearson correlation, Bias = simulated minus actual.

| Zone | Coupled MAE | Iter MAE | Coupled Corr | Iter Corr | Coupled Bias | Iter Bias | Result |
|------|---:|---:|---:|---:|---:|---:|--------|
| **PL** | 22.8 | **10.9** | 0.491 | 0.296 | -17.8 | **-1.3** | **Best improvement** |
| **FI** | 45.2 | **40.5** | 0.217 | -0.583 | 44.5 | **21.8** | MAE improved, bias halved |
| **FR** | 21.6 | **19.7** | 0.567 | **0.682** | 10.0 | 17.6 | Better MAE + correlation |
| **AT** | 34.9 | **31.6** | 0.144 | 0.001 | -33.8 | **-29.8** | MAE improved |
| **ES** | 18.7 | **17.1** | 0.72 | 0.564 | -15.6 | **-10.9** | MAE + bias improved |
| **NO1** | 46.3 | **44.4** | 0.137 | 0.236 | -46.3 | -44.4 | Slight improvement |
| GR | 26.0 | 26.0 | -0.004 | **0.294** | -6.9 | -6.9 | Correlation improved |
| NL | 25.3 | 25.1 | -0.01 | **0.225** | 24.4 | 24.2 | Correlation improved |
| CZ | 14.4 | 14.8 | 0.0 | 0.177 | 2.4 | 1.0 | ~same |
| RO | 27.1 | 27.0 | 0.143 | 0.152 | -20.1 | -20.1 | ~same |
| IT-NORTH | 18.4 | 18.4 | 0.0 | 0.0 | -18.3 | -18.3 | No change |
| BG | 97.1 | 97.1 | 0.009 | 0.01 | -95.3 | -95.3 | No change |
| DK1 | 27.7 | 31.3 | 0.152 | 0.041 | 27.7 | 31.3 | Worsened |
| HU | 65.7 | 75.2 | 0.03 | -0.18 | -63.9 | -73.7 | Worsened |
| SE3 | 57.2 | 59.9 | -0.268 | -0.077 | 57.2 | 59.9 | Worsened |
| PT | 91.4 | 93.1 | 0.128 | 0.15 | -91.3 | -93.0 | Worsened |

### Summary

- **6 zones improved**: PL, FI, FR, AT, ES, NO1
- **6 zones unchanged**: GR, NL, CZ, RO, IT-NORTH, BG
- **4 zones worsened**: DK1, HU, SE3, PT

### Notable Observations

1. **Poland (PL)** saw the largest improvement: MAE dropped from 22.8 to 10.9 EUR/MWh and bias from -17.8 to -1.3. This makes sense — PL is a net importer, and the iterative approach adjusts UC dispatch to account for expected imports.

2. **Flat-price zones** (GR, CZ, IT-NORTH, RO, BG) showed little change because their simulated prices have near-zero variance. The MPCC produces a single clearing price across all periods for these zones, regardless of the UC feedback. This is a separate issue from convergence.

3. **Nordic zones** (NO1, SE3, FI) are structurally difficult — hydro-dominated markets have price dynamics driven by water values and reservoir management, which our cost-based UC model cannot capture.

4. **Non-convergence** (Δλ=181.91 EUR/MWh after 10 iterations) means the iterative results are from an unstable fixed point. The improvements in some zones may be coincidental rather than systematic.

5. **Runtime**: 10x longer (104 min vs 11 min) for mixed results. The iterative approach is not cost-effective for this date.
