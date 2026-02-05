# UC and Interconnection: Approaches for Joint Optimization

## Problem Statement

The current architecture has a fundamental mismatch:

```
Current Flow:
┌─────────────────────────────────────────────────────────────┐
│  Zone A: UC solves independently (no imports/exports)       │
│  Zone B: UC solves independently (no imports/exports)       │
│                           ↓                                  │
│  BiddingStrategy: Creates orders based on isolated UC       │
│                           ↓                                  │
│  MPCC: Clears market WITH interconnections (ATC)            │
└─────────────────────────────────────────────────────────────┘
```

**The problem**: UC doesn't know about interconnections, so:
- Zone A (expensive) commits expensive units when it could import from Zone B
- Zone B (cheap) doesn't commit extra capacity for exports
- MPCC sees bids that were optimized for isolated operation, not joint operation

This document analyzes four approaches to address this issue.

---

## Approach 1: Accept Suboptimality

**Concept**: Keep the current architecture. UC provides a baseline, MPCC handles marginal adjustments via price signals.

**Tradeoffs**:
| Pros | Cons |
|------|------|
| No code changes | Suboptimal commitment decisions |
| Fast execution | Expensive zones over-commit |
| Simple to understand | Cheap zones under-commit for export |

**When appropriate**: Quick prototyping, or when interconnection flows are small relative to zonal demand.

---

## Approach 2: Adjust UC Demand by Expected Flows

**Concept**: Before running UC, estimate each zone's net position (importer/exporter) and adjust demand accordingly.

### How it works

```
1. Estimate expected net flows for each zone pair
2. For each zone:
   - If net importer: UC_demand = actual_demand - expected_imports
   - If net exporter: UC_demand = actual_demand + expected_exports
3. Run UC per zone with adjusted demands
4. Run MPCC normally
```

### Example

- Zone GR expects to import 300 MW from BG
- GR's UC runs with demand reduced by 300 MW → commits fewer/cheaper units
- BG's UC runs with demand increased by 300 MW → commits more units for export

### The chicken-and-egg problem

How do you know flows before clearing the market?

| Method | Accuracy | Complexity |
|--------|----------|------------|
| Historical average flows | Low-Medium | Simple |
| Price-based heuristic (cheap→expensive) | Medium | Medium |
| Previous day's flows | Medium | Simple |
| Simplified economic dispatch | High | Medium |

### Tradeoffs

| Pros | Cons |
|------|------|
| Minimal code changes | Requires flow prediction |
| Zones solve independently (parallelizable) | Prediction errors → suboptimal commitment |
| Fast (same runtime as current) | Doesn't capture hourly flow variation |
| Easy to understand | One-shot - can't self-correct |

---

## Approach 3: Multi-Zone UC (Joint Optimization)

**Concept**: Solve one large UC problem for all zones simultaneously, with transmission as decision variables.

### Mathematical Formulation

```
Variables:
  g[generator, time]     - generation (all zones)
  u[generator, time]     - commitment (all zones)
  flow[from, to, time]   - transmission between zones

Objective:
  min Σ_z Σ_g Σ_t (marginal_cost_g × g[g,t] + startup_cost_g × v[g,t] + ...)

Constraints:
  # Power balance per zone (with flows)
  Σ g[gen ∈ zone, t] + Σ flow[other → zone, t] =
      demand[zone, t] + Σ flow[zone → other, t]    ∀ zone, t

  # ATC limits
  -ATC[z1, z2] ≤ flow[z1, z2, t] ≤ ATC[z1, z2]    ∀ z1, z2, t

  # All standard UC constraints (ramping, min up/down, etc.)
  # ... per generator constraints unchanged
```

### Scale Considerations

For the current system:

```
Single-zone UC (e.g., GR):
  ~35 generators × 24 periods = ~840 binary variables

Multi-zone UC (50 zones):
  ~6,000 generators × 24 periods = ~144,000 binary variables
  + ~500 flow variables (zone pairs × periods)
```

### Tradeoffs

| Pros | Cons |
|------|------|
| Globally optimal solution | Much larger problem (~170× more binaries) |
| No prediction needed | Slower solve time (minutes → hours?) |
| Flows are optimized jointly | Memory intensive |
| Academically "correct" | Can't parallelize UC |
| | Complex data management (all zones at once) |
| | Solver may struggle with problem size |

### When it makes sense

- Small number of zones (2-5)
- Access to powerful hardware/Gurobi with many cores
- Academic/research settings where optimality is paramount

---

## Approach 4: Iterative UC-MPCC

**Concept**: Run UC and MPCC in a feedback loop until flows converge.

### Algorithm

```
Initialize: expected_flows[z1, z2, t] = 0

Repeat:
  1. For each zone (parallel):
     - Adjust demand by expected_flows
     - Run UC
     - Generate bids

  2. Run MPCC (all zones + interconnections)

  3. Extract actual_flows from MPCC result

  4. Check convergence:
     if |actual_flows - expected_flows| < tolerance:
       STOP
     else:
       expected_flows = α × actual_flows + (1-α) × expected_flows
       (damping factor α ≈ 0.7 helps stability)

Typically converges in 2-4 iterations
```

### Convergence Behavior

```
Iteration 1: UC ignores flows → MPCC finds flows → big adjustment
Iteration 2: UC accounts for flows → MPCC refines → smaller adjustment
Iteration 3: Usually converged (flows stable within tolerance)
```

### Damping Factor

The damping factor `α` controls how aggressively we update flow expectations:
- `α = 1.0`: Full update (may oscillate)
- `α = 0.7`: Recommended (balances speed and stability)
- `α = 0.5`: Conservative (slower convergence, more stable)

### Tradeoffs

| Pros | Cons |
|------|------|
| Uses existing UC + MPCC code | 2-4× runtime (multiple iterations) |
| Self-correcting (learns optimal flows) | Convergence not guaranteed (rare edge cases) |
| Parallelizable within each iteration | More complex orchestration |
| Handles hourly flow variation | UC cache becomes tricky (flow-dependent) |
| Practical for large systems | May oscillate without damping |

---

## Summary Comparison

| Aspect | Approach 1 (Accept) | Approach 2 (Adjusted Demand) | Approach 3 (Multi-Zone UC) | Approach 4 (Iterative) |
|--------|---------------------|------------------------------|---------------------------|------------------------|
| **Optimality** | Poor | Approximate | Globally optimal | Near-optimal |
| **Runtime** | 1× | 1× | 10-100× slower | 2-4× slower |
| **Complexity** | None | Low | High | Medium |
| **Parallelizable** | Yes | Yes | No | Yes (per iteration) |
| **Code changes** | None | Small | Large | Medium |
| **Scales to 50 zones** | Yes | Yes | Difficult | Yes |
| **Handles hourly variation** | No | Poorly | Perfectly | Well |

---

## Recommendation

For a system with 50 zones and 6,000+ generators:

**Recommended: Approach 4 (Iterative UC-MPCC)**

Reasons:
1. Reuses existing UC and MPCC code
2. Scales to the problem size
3. Self-correcting (no prediction model needed)
4. Can still parallelize UC within each iteration
5. 2-4× runtime is acceptable for day-ahead planning

**Alternative: Approach 2 (Adjusted Demand)**

If runtime is critical and a simpler solution is preferred:
- Use historical average flows as initial estimate
- Accept some suboptimality in exchange for simplicity

---

## Implementation Notes

### For Approach 4 (Iterative)

Key implementation considerations:

1. **Flow adjustment in UC**: Modify `solve_unit_commitment()` to accept optional `net_import` parameter that adjusts demand

2. **Convergence criteria**:
   ```julia
   max_flow_change = maximum(abs.(new_flows - old_flows))
   converged = max_flow_change < tolerance  # e.g., 10 MW
   ```

3. **Cache handling**: UC results become flow-dependent, so caching needs to account for expected flows or be disabled during iteration

4. **Iteration limit**: Set max iterations (e.g., 10) to prevent infinite loops in edge cases

### For Approach 2 (Adjusted Demand)

Key implementation considerations:

1. **Flow estimation**: Start with simple historical averages per zone pair per hour

2. **Demand adjustment**:
   ```julia
   adjusted_demand[z, t] = demand[z, t] - net_import[z, t]
   # where net_import > 0 means importing, < 0 means exporting
   ```

3. **Validation**: Compare MPCC actual flows vs predicted to measure estimation quality
