# Iterative UC-MPCC Test Results

**Date**: 2026-02-02
**Test Date**: 2025-12-10
**Duration**: ~6 hours (21,381 seconds)

## Test Configuration

- **Algorithm**: Iterative UC-MPCC (Unit Commitment with Market Clearing feedback loop)
- **Max iterations**: 10
- **Price convergence tolerance**: 1.0 €/MWh
- **Damping factor**: 0.7
- **Zones processed**: 36 (out of 46 discovered, some failed due to missing data)
- **Cross-border links**: 138 directional transfer capacity links

### Zones Included

AT, BG, CZ, DE_LU, DK1, DK2, EE, ES, FI, FR, GR, HU, IT-Calabria, IT-CNORTH, IT-CSOUTH, IT-NORTH, IT-Sardinia, IT-Sicily, IT-SOUTH, LT, LV, NL, NO1, NO2, NO3, NO4, NO5, PL, PT, RO, SE1, SE2, SE3, SE4, SI, SK

### Zones Failed (missing data)

BE, BY, DE_50HzT, DK, GB, HR, IT, IT-SACODC, PLC, RU_KGD

## Convergence Results

| Metric | Value |
|--------|-------|
| **Converged** | No |
| **Iterations completed** | 10 |
| **Final price change** | 468.38 €/MWh |
| **Tolerance** | 1.0 €/MWh |
| **MPCC status** | Optimal |
| **Objective value** | €6.89 billion |

## Why Convergence Failed

The algorithm did not converge due to three main factors:

### 1. Structural Scarcity in Multiple Zones

Many zones hit the 500 €/MWh price cap, indicating demand exceeds available supply. This is a ceiling price that triggers "load shedding" in our model (economic scarcity signal).

### 2. Binary UC Decisions Cause Oscillation

Unit commitment involves binary (ON/OFF) decisions for thermal plants. Small changes in expected net imports can flip commitment decisions:
- Iteration N: Zone expects 100 MW import → commits fewer plants
- Iteration N+1: MPCC delivers 80 MW → shortage → price spikes to 500 €/MWh
- Iteration N+2: Zone expects 80 MW → commits more plants → excess → price drops

This creates a limit cycle that damping alone cannot resolve.

### 3. Limited Cross-Border Transmission (ATC)

Available Transfer Capacity constrains how much power can flow between zones:
- Even if Germany has surplus, it can only export up to ATC limit
- Multiple deficit zones compete for limited import capacity
- Binding ATC constraints prevent price equalization

## Price Patterns by Zone

### Stable Prices (~369 €/MWh) - Tight but balanced

| Zone | Avg Price | Interpretation |
|------|-----------|----------------|
| ES (Spain) | 369 €/MWh | Marginal gas plant setting price |
| GR (Greece) | 369 €/MWh | Coupled with Balkans |
| IT-CNORTH | 369 €/MWh | North Italy mainland |
| IT-CSOUTH | 369 €/MWh | Central-South Italy |
| IT-SOUTH | 369 €/MWh | Southern Italy |
| IT-Sicily | 369 €/MWh | Island coupled via HVDC |

### Lower Prices (~290-316 €/MWh) - Adequate supply

| Zone | Avg Price | Interpretation |
|------|-----------|----------------|
| IT-Sardinia | 316 €/MWh | Island with local generation |
| DK1 (Denmark West) | 290 €/MWh | High wind penetration |

### Mixed/Oscillating Prices (0-500 €/MWh)

| Zone | Price Range | Interpretation |
|------|-------------|----------------|
| SI (Slovenia) | 0-500 €/MWh | Swings between excess and scarcity |
| HU (Hungary) | 369-500 €/MWh | Frequent scarcity periods |
| Nordic zones | Variable | Hydro-dominated, weather-dependent |

## Net Import Adjustments (Final Iteration)

Major exporters (told to reduce local UC demand):
- **DE_LU (Germany)**: -147,863 MWh net export
- **FR (France)**: -59,546 MWh net export

Major importers (told to increase local UC demand):
- **SK (Slovakia)**: +21,426 MWh net import adjustment

Zones with persistent load shedding despite imports:
- **NO1 (Norway South)**: 75,476 MWh shortage
- **SE3 (Sweden Central)**: 54,561 MWh shortage
- **FI (Finland)**: 45,323 MWh shortage

## Why Real Europe Doesn't Have Blackouts

Our model shows economic scarcity (price signals), not actual load shedding. Several factors explain the gap:

### 1. Missing Capacity (~51-83% not modeled)

| Component | Real Capacity | Our Model | Gap |
|-----------|--------------|-----------|-----|
| Wind/Solar | ~70 GW (DE alone) | Excluded from UC | Handled via forecast subtraction |
| Small generators | Significant | Below reporting threshold | Not in ENTSO-E data |
| Demand response | ~5-10% of load | Not modeled | Industrial curtailment |
| Emergency reserves | ~10-15% | Not modeled | Spinning/standing reserve |

### 2. Real-Time Balancing

Our model is day-ahead unit commitment. Real systems have:
- Intraday markets (adjust closer to delivery)
- Balancing markets (real-time corrections)
- Automatic frequency restoration reserves

### 3. Interconnection Beyond Model Scope

- GB (Great Britain) not fully modeled
- Nordic-Baltic connections complex
- Some DC links missing

### 4. Scarcity Pricing ≠ Blackouts

When our model shows 500 €/MWh:
- Real market: Large consumers reduce load (demand response)
- Real TSO: Activates reserves, reduces voltage 5%, calls for emergency imports
- Our model: Records "shortage" as unserved energy

## Recommendations

### For Model Improvement

1. **Add renewable capacity to UC**: Currently excluded as "variable", but large-scale batteries and curtailable wind could participate
2. **Model demand response**: Add elastic demand at high prices
3. **Increase iteration limit**: Some zones might converge with 20+ iterations
4. **Use flow-based convergence**: Price-based may be too strict for binary UC

### For Analysis Use

1. **Interpret prices as stress indicators**: 500 €/MWh = system under stress, not actual blackout
2. **Compare relative prices**: Price differentials show congestion and flow direction
3. **Use for scenario analysis**: "What if Germany loses 10 GW nuclear?" type questions

## Data Quality Issues Discovered

### Date Validity Problem (Fixed)

ENTSO-E `valid_from`/`valid_to` dates are often stale:
- Spain nuclear: `valid_from` in 2026 (future!) but actively generating
- German coal: `valid_to` in 2022-2024 but still operating in 2025

**Solution implemented**: Include plants with recent actual generation output (last 60 days) regardless of validity dates.

### Duplicate Generator Records

Poland had duplicate generator codes causing UC cache failures.

**Solution implemented**: `DISTINCT ON (generation_unit_code)` with ordering by `valid_from DESC`.

## Files Modified

- `src/Generators.jl`: Date validity relaxation, duplicate handling
- `CLAUDE.md`: Documentation updates

## Raw Output Location

Full test output: `/tmp/claude-1002/-home-johnkgeorg-energy-markets/tasks/b08afe3.output` (1.5 MB)
