# Infeasible Zones Analysis (Valid Data)

**Date**: 2025-12-10 (test date)
**Analysis**: Zones that fail UC despite having valid generator and load data

## Summary Table

| Zone | Generators | P_max (MW) | Max Demand (MW) | ON P_max (MW) | Gap (MW) | Root Cause |
|------|------------|------------|-----------------|---------------|----------|------------|
| **DE_LU** | 119 | 37,714 | 70,664 | - | -32,950 | Capacity shortage |
| **DK2** | 5 | 1,446 | 2,190 | - | -744 | Capacity shortage |
| **FI** | 43 | 9,462 | 11,229 | - | -1,767 | Capacity shortage |
| **NL** | 31 | 12,067 | 17,677 | - | -5,610 | Capacity shortage |
| **FR** | 191 | 69,052 | 63,400 | 54,082 | -9,318 | Startup constraints |
| **HU** | 78 | 5,712 | 6,531 | 2,814 | -3,717 | Capacity + startup |
| **IT-Sardinia** | 9 | 1,734 | 1,200 | 647 | -553 | Startup constraints |
| **PL** | 125 | 29,100 | 23,600 | 24,553 | +953 | Startup/ramp constraints |
| **SK** | 22 | 4,151 | 3,895 | 2,831 | -1,064 | Startup constraints |

## Root Cause Categories

### 1. Capacity Shortage (P_max < Max Demand)

These zones have insufficient total generation capacity. Even if all generators were ON, they couldn't meet peak demand.

| Zone | P_max | Max Demand | Shortage |
|------|-------|------------|----------|
| DE_LU | 37,714 MW | 70,664 MW | 32,950 MW (87%) |
| NL | 12,067 MW | 17,677 MW | 5,610 MW (46%) |
| FI | 9,462 MW | 11,229 MW | 1,767 MW (19%) |
| DK2 | 1,446 MW | 2,190 MW | 744 MW (51%) |

**Why shortage variable should help**: The shortage variable handles `total P_max < demand` cases. These zones should now be feasible with shortage active. If still infeasible, check for ramp/uptime constraint violations.

### 2. Startup Constraint Issues (Sufficient capacity, but can't start fast enough)

These zones have enough total capacity, but too many generators are OFF with long startup times.

#### FR (France)
- **Need from OFF generators**: 9,318 MW
- **Fast start (<4h)**: 4,050 MW ❌
- **Medium (4-12h)**: 3,250 MW
- **Slow (>12h)**: 7,670 MW
- **Issue**: Nuclear plants ARE running, but non-nuclear OFF generators (coal, gas, hydro pumped storage) have long startup times

#### SK (Slovakia)
- **Need from OFF generators**: 1,064 MW
- **Fast start (<4h)**: 0 MW ❌❌
- **Medium (4-12h)**: 330 MW
- **Slow (>12h)**: 990 MW
- **Issue**: NO fast-start capacity at all

#### IT-Sardinia
- **Need from OFF generators**: 553 MW
- **Fast start (<4h)**: 520 MW ≈
- **Slow (>12h)**: 567 MW
- **Issue**: Barely insufficient fast-start, plus data quality issue (output > P_max)

#### HU (Hungary)
- **Need from OFF generators**: 3,717 MW (also has capacity shortage)
- **Fast start (<4h)**: 115 MW ❌❌
- **Medium (4-12h)**: 1,936 MW
- **Slow (>12h)**: 846 MW
- **Issue**: Almost no fast-start + actual capacity shortage

#### PL (Poland)
- **ON capacity > Max demand**: Should be feasible
- **Issue**: Likely ramp constraints or min uptime/downtime conflicts

## Startup Time by Thermal State

| Thermal State | Typical Startup | Example Fuels |
|---------------|-----------------|---------------|
| Hot | 1-4 hours | Recently shut down, gas turbines |
| Warm | 4-12 hours | Coal, CCGT |
| Cold | 12-48 hours | Nuclear, lignite, long-idle coal |

## Why Current Slack Variables Don't Help

1. **Shortage variable**: Only handles `total P_max < demand`, not `available P_max < demand`
2. **Excess variable**: Handles overgeneration (P_min > demand), not undergeneration
3. **Curtailment variable**: Only for renewable spillage

## Potential Solutions

### Option 1: Startup Violation Variable
Add a slack variable that allows generators to "emergency start" with high penalty:
```
startup_violation[i,t] >= 0
g[i,t] <= P_max[i] * (u[i,t] + startup_violation[i,t])
Objective += high_penalty * sum(startup_violation)
```

### Option 2: Relax Min Uptime/Downtime
Allow violations of minimum uptime/downtime constraints with penalty.

### Option 3: Rolling Horizon Pre-start
Run a longer horizon optimization that allows generators to pre-start before the market day.

### Option 4: Reduce Startup Times
Use more realistic (shorter) startup times for some generator types, especially:
- Hydro Pumped Storage (should be fast-start)
- Gas turbines (OCGT should be 15-30 min)

## Technical Details

### Fuel Type Startup Parameters (Current)

| Fuel Type | Hot Start | Warm Start | Cold Start | Min Uptime |
|-----------|-----------|------------|------------|------------|
| Nuclear | 8h | 24h | 48h | 24h |
| Coal/Lignite | 4h | 8h | 12h | 8h |
| CCGT | 2h | 4h | 6h | 4h |
| OCGT | 1h | 2h | 4h | 2h |
| Hydro Pumped | 0.25h | 0.25h | 1h | 1h |

### Initial Condition Thermal State Rules
- Hot: hours_off <= 8
- Warm: 8 < hours_off <= 48
- Cold: hours_off > 48
