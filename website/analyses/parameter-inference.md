# Generator Parameter Inference

## Motivation

Accurate unit commitment requires plant-specific operational parameters — ramp rates, minimum stable generation, and minimum uptime/downtime constraints. ENTSO-E's Transparency Platform publishes basic generator metadata (installed capacity, fuel type, location), but not these operational parameters.

Using generic fuel-type defaults (e.g., "all coal plants ramp at 20%/h") introduces systematic error because individual plants vary significantly. A modern 800 MW supercritical coal unit ramps far faster than a 200 MW 1970s lignite plant, even though both share a fuel-type category.

Our approach: infer plant-specific parameters from **12 months of historical actual generation** data, available at 15/30/60-minute resolution from ENTSO-E.

## Data Source

We query `entsoe.actual_generation_output_per_generation_unit`, which provides timestamped MW output for each generation unit. The 12-month lookback window captures full seasonal variation — a gas peaker that runs only in summer would have too few data points in a 3-month window.

Each data point contains:
- `generation_unit_code` — unique identifier
- `date_time_utc` — timestamp
- `resolution_code` — temporal resolution (PT15M, PT30M, PT60M)
- `actual_generation_output_mw` — output in MW

We require a minimum of **100 data points** for any inference. Generators with insufficient history fall back to fuel-type defaults from `FuelTypeParameters`.

## Ramp Rate Inference

**Goal:** Determine how quickly a generator can change output, expressed as a fraction of p_max per hour.

**Method:**

1. Sort historical generation by timestamp.
2. Compute period-to-period deltas: `Δg[i] = g[i] - g[i-1]`.
3. Separate into ramp-ups (Δg > 0) and ramp-downs (|Δg| for Δg < 0).
4. Normalize to hourly rates based on the data resolution:
   - For PT15M data, multiply by 4 (= 60/15) to get the hourly rate.
   - For PT60M data, the delta is already hourly.
5. Take the **95th percentile** of observed ramp rates.
6. Convert to fraction of p_max: `ramp_rate = quantile(ramps, 0.95) × (60/resolution_min) / p_max`.

**Why the 95th percentile?** The maximum observed ramp often reflects measurement noise or data artifacts (e.g., a plant tripping). The 95th percentile captures the operational capability while filtering outliers.

The result is a pair `(ramp_up, ramp_down)` in units of fraction-of-p_max per hour. For example, `ramp_up = 0.25` means the plant can increase output by 25% of its rated capacity per hour.

## Minimum Generation (p_min)

**Goal:** Determine the lowest output at which a thermal generator can operate stably.

**Challenge:** Raw historical data contains zeros (plant off), startups/shutdowns (transient ramps), and stable operation — all mixed together. Simply taking a low percentile of all non-zero values would be biased by transient periods.

**Method:**

1. Sort by timestamp, compute deltas.
2. **Filter zeros** — periods where the plant is off (output = 0).
3. **Filter transients** — periods where `|Δg| > 5% of p_max`, indicating the plant is ramping through startup or shutdown. Adjacent points to large ramps are also excluded.
4. Take the **5th percentile** of remaining stable-operation values.
5. **Clamp** to fuel-type-specific bounds to prevent unreasonable values:

| Fuel Type | Min Bound | Max Bound |
|-----------|-----------|-----------|
| Coal / Lignite | 45% of p_max | 65% of p_max |
| Gas CCGT | 35% of p_max | 55% of p_max |
| Gas OCGT | 20% of p_max | 45% of p_max |
| Default (other thermal) | 30% of p_max | 60% of p_max |

These bounds are aligned with the `min_load_factor` values in `FuelTypeParameters`, ensuring consistency between inferred and default parameters.

**Flexible resources** (hydro, batteries, storage) skip p_min inference entirely and use p_min = 0, since they can operate at any output level.

**Outage validation:** When a generator has an active outage that reduces its available capacity below the inferred p_min, the value is clamped to the current p_max. Without this, the unit commitment model would face infeasible constraints (p_min > p_max is impossible).

## Min Uptime and Downtime

**Goal:** Determine the minimum number of hours a generator must stay on (or off) after being committed (or decommitted).

**Method:**

1. Classify each timestep as ON (output > 1 MW) or OFF.
2. Identify consecutive ON periods and OFF periods, recording their duration in hours (adjusted for data resolution).
3. **Filter glitches** — discard periods shorter than 2 time steps, which likely represent measurement errors rather than real cycling events.
4. Require at least **5 on/off cycles** for meaningful inference. Baseload plants (coal, nuclear) that rarely cycle often don't have enough cycles, so they fall back to fuel-type defaults.
5. Take the **5th percentile** of cycle durations.
6. **Clamp** to fuel-type-specific bounds:

| Fuel Type | Uptime Range | Downtime Range |
|-----------|-------------|----------------|
| Coal | 8 – 48 hours | 4 – 24 hours |
| Gas CCGT | 2 – 12 hours | 1 – 8 hours |
| Gas OCGT | 1 – 4 hours | 1 – 4 hours |
| Default | 2 – 24 hours | 1 – 12 hours |

## Caching

Inference is computationally expensive — querying 12 months of generation data and computing statistics for each generator takes several seconds, and a zone with 40+ generators can take over 15 minutes.

Results are cached in PostgreSQL (`simulations.generator_inferred_parameters`) with a 365-day default expiry. Physical plant parameters don't change frequently, so annual refresh is sufficient.

For batch operations, `refresh_inference_cache()` supports **generator-level parallelism** via `Distributed.jl`. Each generator's inference is completely independent (just database queries + statistics), allowing full utilization of available CPU cores.

## Pipeline Integration

When the unit commitment solver runs with `use_inferred_params=true` (the default), it:

1. Checks the cache for existing parameters.
2. If cached and fresh (< 365 days), applies them to the generator objects.
3. If missing or stale, runs inference and caches the results.
4. Validates that inferred p_min does not exceed current p_max (accounting for outages).
5. Uses the enriched generators in the optimization model.

Generators without sufficient historical data (< 100 data points) retain their fuel-type default parameters from `FuelTypeParameters`.
