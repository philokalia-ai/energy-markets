# src/generators — registry and cost model notes

Loaded when working under `src/generators/`. Moved from the root `CLAUDE.md`
(August 2026). These are the data-quality gotchas and design rationale behind
`get_generators` and the SRMC cost model — the code alone would teach the wrong
pattern in several places.


**Generator unavailability filtering:**
```julia
# Get generators with outage filtering (default behavior)
generators = get_generators("GR", Date(2024, 6, 15))

# Disable filtering to get all commissioned generators
generators = get_generators("GR", Date(2024, 6, 15); exclude_unavailable=false)
```

The `exclude_unavailable` parameter (default: `true`) filters generators based on outage data:
- **Complete outages** (`available_capacity_mw = 0`): Generator excluded entirely
- **Partial outages** (`available_capacity_mw > 0`): Generator's `p_max` reduced to available capacity
- Only `status = 'Active'` outages are considered (ignores `Cancelled`/`Withdrawn`)
- Uses `MIN(available_capacity_mw)` when multiple outage records exist (conservative)

**Generator deduplication (overlapping validity periods):**
- ENTSO-E data can have multiple rows for the same generator with overlapping `valid_from`/`valid_to` periods
- This is a data quality issue where capacity changes create duplicate entries instead of properly versioned records
- The query uses `DISTINCT ON (generation_unit_code)` to deduplicate
- Priority: most recent `valid_from`, then highest capacity as tiebreaker
- Example: Poland's "Dolna Odra B7" had 5 overlapping entries with capacities 210-232 MW

**Date validity filter with recent generation fallback:**
- ENTSO-E data has stale `valid_from`/`valid_to` dates for some operating plants
- Example: Spain nuclear plants had `valid_from` in 2026 (future!) but were actively generating
- Example: German coal plants had `valid_to` in 2022-2024 but were still operating in 2025
- Solution: Include plants that EITHER pass the date validity filter OR have recent actual generation output
- Recent generation = output > 0 MW within the last 60 days (from `actual_generation_output_per_generation_unit`)
- This ensures operating plants are included regardless of stale validity dates
- Plants with neither valid dates NOR recent generation are correctly excluded (truly decommissioned)

**Day-level outage cache + per-zone memoization (`get_generators` performance):**
- The `active_outages` aggregation and the `stale_outage_override` set are
  **zone-independent day-level work**: a ~3 s seq-scan of the 9.4 GB
  `unavailability_of_production_and_generation_units` table (text timestamps cast
  per row). `get_day_outages(day)` computes this ONCE per market day across ALL
  zones and caches it in a module-level `Dict{Date,DataFrame}` (thread-safe, like
  `TTF_PRICE_CACHE`; never cached on DB error). Each zone's `get_generators` query
  consumes its slice as array parameters (`unnest($3,$4,$5)`) — same rows as the
  old per-zone CTEs (identity-tested for GR/DE_LU/NO1/FR + a 2022 crisis date in
  `test/test_get_generators_identity.jl`). A 39-zone EU build hit the table once
  instead of ~50 times (235 s → 145 s for the generator stage).
- `get_generators` also memoizes its result per `(zone, day, exclude_unavailable,
  exclude_variable_renewables, infer_ramp_rates_flag)` in a module-level `Dict`, so
  pass-2 anchored rebuilds and repeated builds in one process are free (they
  return a shallow copy — callers may mutate the returned vector, e.g. fleet
  completion). `Euphemia.clear_generator_caches!()` clears both caches.

The `exclude_variable_renewables` parameter (default: `true`) filters out wind and solar generators:
- **Variable renewables** (Wind Onshore, Wind Offshore, Solar) are excluded from UC
- These generators' output is non-dispatchable and handled via renewable forecasts
- Renewable generation is subtracted from load to calculate net demand for UC
- This prevents double-counting (generator in UC + forecast subtracted from load)

**Gas marginal costs from real TTF prices:**

Gas-fired generators ("Fossil Gas") use real TTF front-month futures prices from
`yfinance.ttf_f` (populated by the ceres yfinance ETL, updated Tue–Sat):

```julia
# Most recent TTF close at or before a date (€/MWh), nothing if no data within 10 days
ttf = Euphemia.get_ttf_price(Date(2024, 6, 15))

# Gas marginal cost = TTF/efficiency + carbon + O&M (no bid markup)
mc = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas")  # ≈ €97/MWh
```

Cost model constants (in `src/Generators.jl`): `GAS_PLANT_EFFICIENCY = 0.55`,
`GAS_EMISSION_FACTOR = 0.202` tCO₂/MWh gas, `GAS_VOM_COST = 2.0` €/MWh.

EUA carbon prices come from `yfinance.eua_co2` (daily EUR closes of the
SparkChange Physical Carbon ETC "CO2.L", populated by the ceres yfinance ETL
alongside TTF; the ETC physically holds EU Allowances so its close tracks
EUA spot ~1:1). `eua_price(day)` uses the close of the last trading day
strictly before the market date (no lookahead), cached in
`EUA_PRICE_CACHE`; before the feed's history starts (Nov 2021) or on DB
failure it falls back to the `EUA_PRICE_BY_YEAR` yearly lookup.

TTF lookups use the close of the last trading day strictly before the market
date (no lookahead) and are cached per date in `TTF_PRICE_CACHE` (transient DB
errors are never cached). If no TTF price exists within 10 days before the
requested date (e.g., before the table's history starts in Feb 2023), the
`FUEL_SRMC_BASE` fallback is used. All other fuel types use the `FUEL_SRMC_BASE`
table in `src/Generators.jl` — true short-run marginal costs: non-carbon base
plus `FUEL_EMISSION_FACTOR_EL × eua_price(day)` (e.g., lignite ≈ €112/MWh at
EUA 70), with no bid markup: bidding strategy belongs to the order-book
layer, not the cost model.

**Fuel type inference from generator names:**

Generators classified as "Other" in the ENTSO-E database may actually be known technology types. The `infer_fuel_type_from_name()` function attempts to reclassify them based on naming patterns:

```julia
# Automatic inference happens when loading generators
generators = get_generators("FR", Date(2024, 6, 15))
# Logs: "Inferred fuel type for BESS_AFD7_BARBAN: Other → Energy storage"
```

Currently recognized patterns:
- **BESS/Battery** → `Symbol("Energy storage")`: Matches "BESS", "BATTERY", "BATTERIE", "BATTERI"

Generators that cannot be inferred remain as "Other" with flexible parameters (see FuelTypeParameters below). Unknown "Other" generators are documented in `docs/unknown-other-generators.md` for future research.

**Flexible fuel types:**

The constant `FLEXIBLE_FUEL_TYPES` defines technologies that can operate at any output level (no minimum load factor):
```julia
FLEXIBLE_FUEL_TYPES = [
    Symbol("Hydro Water Reservoir"),
    Symbol("Hydro Run-of-river and pondage"),
    Symbol("Hydro Pumped Storage"),
    Symbol("Energy storage"),
    Symbol("Other")
]
```

These fuel types:
- Have `min_load_factor = 0` (can operate at any level down to 0 MW)
- Are excluded from thermal minimum generation constraints in UC
- Include "Other" since the actual technology is unknown

