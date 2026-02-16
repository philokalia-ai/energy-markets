# Gas Plant Classification

## Problem

The ENTSO-E Transparency Platform categorizes all gas-fired power plants under a single fuel type: **"Fossil Gas"**. In reality, gas plants fall into three distinct technology classes with very different cost structures and operational characteristics:

| Technology | Efficiency | Typical Marginal Cost (2024) | Role |
|-----------|-----------|------------------------------|------|
| **CCGT** (Combined Cycle Gas Turbine) | ~55% | ~84 EUR/MWh | Mid-merit baseload |
| **CHP** (Combined Heat and Power) | ~48% | ~97 EUR/MWh | Heat-driven, must-run |
| **OCGT** (Open Cycle Gas Turbine) | ~35% | ~140 EUR/MWh | Peaker |

Treating all gas plants identically at, say, 45% efficiency would systematically misprice CCGTs (too expensive) and OCGTs (too cheap), distorting the merit order and producing unrealistic market clearing prices.

## Two-Stage Classification

We implement a two-stage pipeline: **name-based classification** at generator load time, followed by **behavioural validation** during parameter inference.

### Stage 1: Name-Based Classification

When generators are loaded from the ENTSO-E database, each "Fossil Gas" plant is classified based on keywords in its name. The rules are applied in priority order:

**1. CCGT keywords** (highest priority):
- Matches: `GuD`, `CCGT`, `"combined cycle"`, `Combicycle`
- Result: `Fossil Gas` (the symbol represents CCGT)
- CCGT overrides CHP — a combined-cycle CHP plant still has CCGT-level thermal efficiency

**2. CHP keywords:**
- Matches: `HKW`, `BHKW`, `KWK`, `CHP`, `Coge` (cogneration), `Heizkraft`, `Elektrociep` (Polish), `Warmekraft`, `EC` (with word boundary matching)
- Result: `Fossil Gas CHP`

**3. Capacity fallback** (when no keywords match):
- \> 200 MW → CCGT (large gas plants are almost always combined cycle)
- ≤ 200 MW → `Fossil Gas OCGT`

The keyword lists cover naming conventions across multiple European languages (German, French, Polish, etc.), since ENTSO-E data uses local plant names.

### Stage 2: Behavioural Validation

During parameter inference, `validate_gas_classification()` checks whether a plant's historical operating pattern matches its assigned class. This catches misclassifications from Stage 1 — particularly the capacity fallback, which is a heuristic.

Three metrics are computed from historical generation data:
- **Capacity factor** — average output / p_max
- **Starts per week** — number of ON→OFF→ON cycles per week
- **Mean run duration** — average length of continuous operation

**Reclassification rules:**

| From | To | Condition | Rationale |
|------|----|-----------|-----------|
| OCGT | CHP | CF > 50% AND starts < 2/week | High utilization, rarely cycling → heat-led must-run |
| OCGT | CCGT | CF > 35% AND mean run > 12h | Mid-merit pattern with long runs |
| CCGT | OCGT | CF < 15% AND starts > 5/week AND run < 4h | Peaker pattern despite being labelled CCGT |

**CHP is never reclassified.** The CHP keywords (HKW, KWK, etc.) are highly specific to combined heat and power plants, so name-based CHP classification is high-confidence.

## Parameter Impact

The classification directly determines generator parameters used throughout the simulation pipeline:

| Parameter | CCGT | CHP | OCGT |
|-----------|------|-----|------|
| **Fuel type symbol** | `Fossil Gas` | `Fossil Gas CHP` | `Fossil Gas OCGT` |
| **Efficiency** | 55% | 48% | 35% |
| **Marginal cost (2024)** | ~84 EUR/MWh | ~97 EUR/MWh | ~140 EUR/MWh |
| **Ramp rate** | 25%/h | 20%/h | 50%/h |
| **Min load factor** | 35% | 40% | 20% |
| **Min uptime** | 4h | 6h | 1h |
| **Min downtime** | 2h | 3h | 1h |
| **Cold startup time** | 6h | 6h | 2h |

These flow through the entire pipeline:

1. **Unit commitment** uses min load, ramp rates, uptime/downtime to determine optimal dispatch.
2. **Bidding strategy** uses marginal cost (computed from efficiency) to set bid prices.
3. **Market clearing** (MPCC) accepts bids in merit order, so the cost differences directly affect which plants are dispatched and at what price.

## Cost Model Integration

Marginal costs are calculated using a heat-rate-based model:

```
marginal_cost = fuel_price / efficiency + CO2_price × emission_factor / efficiency + VOM
```

With 2024 gas prices (~30 EUR/MWh thermal) and EU ETS carbon prices (~65 EUR/tonne):

- **CCGT** (55% eff): 30/0.55 + 65×0.37/0.55 + 3.5 = **~84 EUR/MWh**
- **CHP** (48% eff): 30/0.48 + 65×0.37/0.48 + 3.5 = **~97 EUR/MWh**
- **OCGT** (35% eff): 30/0.35 + 65×0.37/0.35 + 3.5 = **~140 EUR/MWh**

The 67% cost difference between CCGT and OCGT has a large impact on the merit order. An OCGT bidding at 140 EUR/MWh sets the clearing price far higher than a CCGT at 84 EUR/MWh — correctly classifying these plants is essential for realistic price simulation.

## Validation

A validation script (`test/scripts/validate_gas_classification.jl`) reports the classification distribution across all European zones, including how many plants were reclassified in Stage 2 and the resulting parameter distributions.
