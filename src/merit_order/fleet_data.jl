# fleet_data.jl — Fleet/hydro data queries: hydro availability, per-type output p95, installed capacity, reservoir dryness and drawdown.
# Included by ../MeritOrderBook.jl inside `module MeritOrderBook` (definition order preserved).


# --- Day-level batch caches (2026-07-24 performance review) ------------------
# The four query families below used to run per (zone, day): on a 39-zone
# sequential day that is ~4 aggregate-table scans x 39 zones x 2 passes. Like
# the outage/flows day caches, each family now fetches ONCE per day for ALL
# zones (grouped by area_map_code) and per-zone calls slice the cached result.
# Per-zone VALUES are identical to the old per-zone queries: percentile_cont
# sorts within its group (deterministic), DISTINCT ON orders within the same
# keys; only scan-order FP summation can differ at the last ULP (the same
# documented mechanism as the physical-flows day cache). Errors are never
# cached; locks follow the TTF_PRICE_CACHE pattern.
const _TYPE_P95_DAY_CACHE = Dict{Tuple{Date,Int},Dict{String,Dict{String,Float64}}}()
const _OVERNIGHT_P5_DAY_CACHE = Dict{Tuple{Date,Int},Dict{String,Dict{String,Float64}}}()
const _OVERNIGHT_RESIDUAL_DAY_CACHE = Dict{Tuple{Date,Int},Dict{String,Float64}}()
const _HYDRO_AVAIL_DAY_CACHE = Dict{Tuple{Date,Int},Dict{String,Float64}}()
const _INSTALLED_CAP_CACHE = Ref{Union{Nothing,Dict{String,Dict{String,Float64}}}}(nothing)
const _RESERVOIR_DAY_CACHE = Dict{Date,Dict{String,Any}}()
const _FLEET_DATA_LOCK = ReentrantLock()

function clear_fleet_data_caches!()
    lock(_FLEET_DATA_LOCK) do
        empty!(_TYPE_P95_DAY_CACHE)
        empty!(_OVERNIGHT_P5_DAY_CACHE)
        empty!(_OVERNIGHT_RESIDUAL_DAY_CACHE)
        empty!(_HYDRO_AVAIL_DAY_CACHE)
        _INSTALLED_CAP_CACHE[] = nothing
        empty!(_RESERVOIR_DAY_CACHE)
    end
    return nothing
end

function _type_p95_all_zones(day::Date, lookback_days::Int)
    key = (day, lookback_days)
    cached = lock(_FLEET_DATA_LOCK) do
        get(_TYPE_P95_DAY_CACHE, key, nothing)
    end
    cached !== nothing && return cached
    df = sql2df_with_retry(
        """
        SELECT area_map_code AS z, production_type,
               percentile_cont(0.95) WITHIN GROUP (ORDER BY mw) AS p95
        FROM (
            SELECT area_map_code, production_type, date_time_utc,
                   SUM(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY area_map_code, production_type, date_time_utc
        ) hourly
        GROUP BY area_map_code, production_type
        """,
        [day - Day(lookback_days), day])
    out = Dict{String,Dict{String,Float64}}()
    for row in eachrow(df)
        ismissing(row.p95) && continue
        get!(out, String(row.z), Dict{String,Float64}())[String(row.production_type)] =
            Float64(row.p95)
    end
    lock(_FLEET_DATA_LOCK) do
        _TYPE_P95_DAY_CACHE[key] = out
    end
    return out
end

function _hydro_avail_all_zones(day::Date, lookback_days::Int)
    key = (day, lookback_days)
    cached = lock(_FLEET_DATA_LOCK) do
        get(_HYDRO_AVAIL_DAY_CACHE, key, nothing)
    end
    cached !== nothing && return cached
    df = sql2df_with_retry(
        """
        SELECT z, percentile_cont(0.95) WITHIN GROUP (ORDER BY hydro_mw) AS p95
        FROM (
            SELECT area_map_code AS z, date_time_utc,
                   SUM(actual_generation_output_mw) AS hydro_mw
            FROM entsoe.aggregated_generation_per_type
            WHERE production_type = ANY(\$1)
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY area_map_code, date_time_utc
        ) hourly
        GROUP BY z
        """,
        [HYDRO_PRODUCTION_TYPES, day - Day(lookback_days), day])
    out = Dict{String,Float64}()
    for row in eachrow(df)
        ismissing(row.p95) && continue
        out[String(row.z)] = Float64(row.p95)
    end
    lock(_FLEET_DATA_LOCK) do
        _HYDRO_AVAIL_DAY_CACHE[key] = out
    end
    return out
end

"""
    get_hydro_availability(bidding_zone::String, day::Date; lookback_days=30) -> Union{Float64,Nothing}

Recent achievable hydro output as a fraction of what the fleet produced at
its best over the trailing window: the 95th-percentile hourly total hydro
output over the `lookback_days` before `day` (strictly before — no
lookahead). Hydro is energy-limited, so recent peak output is a physical
proxy for the water actually available — in dry periods (e.g. August 2024,
May 2025 in SEE) reservoirs cannot sustain nameplate output regardless of
price, which tightens the real capacity margin and drives scarcity pricing.

Returns MW (the p95 hourly output), or `nothing` when no data exists.
"""
function get_hydro_availability(bidding_zone::String, day::Date; lookback_days::Int=30)
    # Served from the all-zones day cache; `nothing` when the zone has no
    # hydro rows in the window — same contract as the single-zone query.
    return get(_hydro_avail_all_zones(day, lookback_days), bidding_zone, nothing)
end

function _get_hydro_availability_singlezone(bidding_zone::String, day::Date; lookback_days::Int=30)
    df = sql2df_with_retry(
        """
        SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY hydro_mw) AS p95
        FROM (
            SELECT date_time_utc, SUM(actual_generation_output_mw) AS hydro_mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1
              AND production_type = ANY(\$2)
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$4::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY date_time_utc
        ) hourly
        """,
        [bidding_zone, HYDRO_PRODUCTION_TYPES, day - Day(lookback_days), day]
    )
    (isempty(df) || ismissing(df.p95[1])) && return nothing
    return Float64(df.p95[1])
end

"""
    get_type_output_p95(bidding_zone::String, day::Date; lookback_days=30) -> Dict{String,Float64}

95th-percentile hourly actual output per production type over the trailing
window (strictly before `day` — no lookahead), from
`entsoe.aggregated_generation_per_type`. Used for fleet completion: ENTSO-E's
unit-level table only lists larger units, so for some zones (RO, BG, RS) the
per-type aggregate output demonstrably exceeds the unit-level fleet capacity.
"""
function get_type_output_p95(bidding_zone::String, day::Date; lookback_days::Int=30)
    # Served from the all-zones day cache (one grouped query per (day,
    # lookback) instead of one scan per zone) — values per zone identical.
    return get(_type_p95_all_zones(day, lookback_days), bidding_zone,
               Dict{String,Float64}())
end

function _get_type_output_p95_singlezone(bidding_zone::String, day::Date; lookback_days::Int=30)
    df = sql2df_with_retry(
        """
        SELECT production_type,
               percentile_cont(0.95) WITHIN GROUP (ORDER BY mw) AS p95
        FROM (
            SELECT production_type, date_time_utc, SUM(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY production_type, date_time_utc
        ) hourly
        GROUP BY production_type
        """,
        [bidding_zone, day - Day(lookback_days), day]
    )
    return Dict{String,Float64}(row.production_type => Float64(row.p95)
                                for row in eachrow(df) if !ismissing(row.p95))
end

function _overnight_p5_all_zones(day::Date, lookback_days::Int)
    key = (day, lookback_days)
    cached = lock(_FLEET_DATA_LOCK) do
        get(_OVERNIGHT_P5_DAY_CACHE, key, nothing)
    end
    cached !== nothing && return cached
    # 5th-percentile of OVERNIGHT (00-06 UTC) per-type hourly output over the
    # trailing window: the MW the type demonstrably never drops below in the
    # low-demand overnight hours — its always-on/must-run floor. Mirrors the
    # p95 query exactly except for the overnight-hour filter and the 0.05
    # quantile. Ex-ante (strictly before `day`), day-cached, errors uncached.
    df = sql2df_with_retry(
        """
        SELECT area_map_code AS z, production_type,
               percentile_cont(0.05) WITHIN GROUP (ORDER BY mw) AS p5
        FROM (
            SELECT area_map_code, production_type, date_time_utc,
                   SUM(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND EXTRACT(HOUR FROM date_time_utc) < 6
            GROUP BY area_map_code, production_type, date_time_utc
        ) hourly
        GROUP BY area_map_code, production_type
        """,
        [day - Day(lookback_days), day])
    out = Dict{String,Dict{String,Float64}}()
    for row in eachrow(df)
        ismissing(row.p5) && continue
        get!(out, String(row.z), Dict{String,Float64}())[String(row.production_type)] =
            Float64(row.p5)
    end
    lock(_FLEET_DATA_LOCK) do
        _OVERNIGHT_P5_DAY_CACHE[key] = out
    end
    return out
end

"""
    get_overnight_output_p5(bidding_zone::String, day::Date; lookback_days=30) -> Dict{String,Float64}

5th-percentile hourly actual output per production type restricted to the
OVERNIGHT hours (00–06 UTC) over the trailing `lookback_days` (strictly before
`day` — no lookahead), from `entsoe.aggregated_generation_per_type`. This is the
demonstrated always-on floor of each fuel type: the MW it never drops below even
in the lowest-demand hours of the night. Used by the cv24 Italian must-run floor
to size (from fundamentals, not bids/prices) the price-taker slice of the
physically-inflexible classes (geothermal, run-of-river, biomass, waste). Empty
Dict for a zone with no data (the caller then adds no floor block).
"""
function get_overnight_output_p5(bidding_zone::String, day::Date; lookback_days::Int=30)
    return get(_overnight_p5_all_zones(day, lookback_days), bidding_zone,
               Dict{String,Float64}())
end

function _overnight_residual_all_zones(day::Date, lookback_days::Int, floor_types::Vector{String})
    key = (day, lookback_days)   # floor_types is a constant across the process
    cached = lock(_FLEET_DATA_LOCK) do
        get(_OVERNIGHT_RESIDUAL_DAY_CACHE, key, nothing)
    end
    cached !== nothing && return cached
    # 5th-percentile of the OVERNIGHT (00-06 UTC) SUMMED output of the must-run
    # fleet types — the RES-aware "residual demand met by the must-run fleet".
    # Summing the floor types per timestamp BEFORE the percentile (vs cv24's
    # per-type p5) makes the signal shrink together on high-RES nights, when the
    # whole thermal+RoR fleet backs off because RES/imports cover the trough —
    # which is what fixed cv24's summer over-thinning at the sizing layer. Ex-ante
    # (strictly before `day`), day-cached, errors uncached.
    df = sql2df_with_retry(
        """
        SELECT z, percentile_cont(0.05) WITHIN GROUP (ORDER BY mw) AS p5
        FROM (
            SELECT area_map_code AS z, date_time_utc,
                   SUM(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_type_code LIKE 'BZN%'
              AND production_type = ANY(\$1)
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
              AND EXTRACT(HOUR FROM date_time_utc) < 6
            GROUP BY area_map_code, date_time_utc
        ) hourly
        GROUP BY z
        """,
        [floor_types, day - Day(lookback_days), day])
    out = Dict{String,Float64}()
    for row in eachrow(df)
        ismissing(row.p5) && continue
        out[String(row.z)] = Float64(row.p5)
    end
    lock(_FLEET_DATA_LOCK) do
        _OVERNIGHT_RESIDUAL_DAY_CACHE[key] = out
    end
    return out
end

"""
    get_overnight_floor_residual_p5(bidding_zone, day, floor_types; lookback_days=30) -> Float64

The RES-aware must-run sizing signal for the cv24.1 Italian floor: the trailing
p5 (00–06 UTC, strictly before `day`) of the OVERNIGHT SUMMED output of the
must-run fleet types (`floor_types`, ENTSO-E production-type names). By the
energy balance this is the overnight residual demand met by that fleet
(load − RES − imports, restricted to the floored fleet) — it shrinks precisely
when RES fills the trough, so the floor no longer over-thins in the high-RES
season (the cv24 summer-regression cause). Returns MW (0.0 when no data).
"""
function get_overnight_floor_residual_p5(bidding_zone::String, day::Date,
    floor_types::Vector{String}; lookback_days::Int=30)
    return get(_overnight_residual_all_zones(day, lookback_days, floor_types),
               bidding_zone, 0.0)
end

"""
    get_installed_capacity_by_type(bidding_zone::String) -> Dict{String,Float64}

INSTALLED capacity (MW) per fuel type from the ENTSO-E unit registry
(`entsoe.production_and_generation_units`): COMMISSIONED units deduplicated per
`generation_unit_code` (most recent `valid_from`, highest capacity tiebreaker —
the standard dedup for this table's overlapping-validity data-quality issue),
summed per `generation_unit_type`. Deliberately does NOT apply the
date-validity / recent-generation filter of `get_generators` — that filter is
what removes idle-but-existing capacity; the caller (installed-aware fleet
truth) gates each type on recent market activity instead, which is what
excludes genuinely-decommissioned capacity with stale COMMISSIONED status
(e.g. Germany's post-phase-out nuclear). Keys are normalized fuel names.
The registry is slowly-changing reference data (same ex-ante treatment as
`get_generators`' use of it).
"""
function get_installed_capacity_by_type(bidding_zone::String)
    # Registry snapshot cached per process (the query is day-independent, so
    # this returns exactly what per-call queries would — modulo an ETL write
    # landing mid-process, same exposure as any long backfill already had).
    cached = lock(_FLEET_DATA_LOCK) do
        _INSTALLED_CAP_CACHE[]
    end
    if cached === nothing
        df_all = sql2df_with_retry(
            """
            SELECT area_map_code AS z, generation_unit_type AS t, SUM(cap) AS mw FROM (
              SELECT DISTINCT ON (area_map_code, generation_unit_code)
                     area_map_code, generation_unit_type,
                     generation_unit_installed_capacity_mw AS cap
              FROM entsoe.production_and_generation_units
              WHERE production_unit_status = 'COMMISSIONED'
                AND generation_unit_status = 'COMMISSIONED'
                AND generation_unit_installed_capacity_mw > 0
              -- DISTINCT ON per (zone, unit): a unit re-zoned across validity
              -- rows must dedup WITHIN each zone exactly like the old
              -- per-zone query did, not once globally.
              ORDER BY area_map_code, generation_unit_code, valid_from DESC,
                       generation_unit_installed_capacity_mw DESC
            ) s
            GROUP BY area_map_code, generation_unit_type
            """, [])
        allz = Dict{String,Dict{String,Float64}}()
        for row in eachrow(df_all)
            (ismissing(row.t) || ismissing(row.mw) || ismissing(row.z)) && continue
            k = normalize_fuel_type_name(String(row.t))
            d = get!(allz, String(row.z), Dict{String,Float64}())
            d[k] = get(d, k, 0.0) + Float64(row.mw)
        end
        lock(_FLEET_DATA_LOCK) do
            _INSTALLED_CAP_CACHE[] = allz
        end
        cached = allz
    end
    return get(cached, bidding_zone, Dict{String,Float64}())
end

function _get_installed_capacity_by_type_singlezone(bidding_zone::String)
    df = sql2df_with_retry(
        """
        SELECT generation_unit_type AS t, SUM(cap) AS mw FROM (
          SELECT DISTINCT ON (generation_unit_code)
                 generation_unit_type, generation_unit_installed_capacity_mw AS cap
          FROM entsoe.production_and_generation_units
          WHERE area_map_code = \$1
            AND production_unit_status = 'COMMISSIONED'
            AND generation_unit_status = 'COMMISSIONED'
            AND generation_unit_installed_capacity_mw > 0
          ORDER BY generation_unit_code, valid_from DESC,
                   generation_unit_installed_capacity_mw DESC
        ) s
        GROUP BY generation_unit_type
        """,
        [bidding_zone]
    )
    out = Dict{String,Float64}()
    for row in eachrow(df)
        (ismissing(row.t) || ismissing(row.mw)) && continue
        k = normalize_fuel_type_name(String(row.t))
        out[k] = get(out, k, 0.0) + Float64(row.mw)
    end
    return out
end

"""
    get_reservoir_dryness(bidding_zone::String, day::Date) -> Union{Float64,Nothing}

Hydrological dryness from ENTSO-E weekly reservoir filling levels
(`entsoe.aggregated_hydro_storage_filling_rate`): the latest stored energy
strictly before `day`'s ISO week, compared to the median stored energy for
the same weeks (±2) of previous years. Returns `clamp(1 - current/norm, 0, 1)`
— 0 in normal/wet conditions, approaching 1 in severe drought — or `nothing`
when either value is unavailable.

Unlike output-based dryness, this measures the water itself, so it is not
confounded by dispatch incentives (hydro running hard *because* prices are
high looks "wet" in output terms while reservoirs are actually draining).
"""
function get_reservoir_dryness(bidding_zone::String, day::Date)
    iso_week = Int(Dates.week(day))
    iso_year = year(day)

    current = sql2df_with_retry(
        """
        SELECT stored_energy_mwh
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
          AND (year < \$2 OR (year = \$2 AND week < \$3))
        ORDER BY year DESC, week DESC
        LIMIT 1
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(current) || ismissing(current.stored_energy_mwh[1])) && return nothing

    # cv22 bug-fix (gated by EUPHEMIA_DISABLE_CV22): `week BETWEEN $3-2 AND $3+2`
    # does not wrap the ISO-week cycle, so weeks 1-2 / 52-53 lose their neighbors
    # across the year boundary (e.g. iso_week=1 → BETWEEN -1 AND 3, missing weeks
    # 51-52). Pass the ±2 neighbourhood as an explicit wrapped set (mod-52). Only
    # differs from BETWEEN at ISO weeks 1/2/52/53 (Dec/Jan) — invisible to the
    # mid-year confirm/guard windows; see docs/experiments/cv22.md.
    if isempty(get(ENV, "EUPHEMIA_DISABLE_CV22", ""))
        weeks = sort(unique(Int[mod1(iso_week + d, 52) for d in -2:2]))
        norm = sql2df_with_retry(
            """
            SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY stored_energy_mwh) AS med
            FROM entsoe.aggregated_hydro_storage_filling_rate
            WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
              AND stored_energy_mwh IS NOT NULL
              AND year < \$2
              AND week = ANY(\$3)
            """,
            [bidding_zone, iso_year, weeks]
        )
    else
        norm = sql2df_with_retry(
            """
            SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY stored_energy_mwh) AS med
            FROM entsoe.aggregated_hydro_storage_filling_rate
            WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
              AND stored_energy_mwh IS NOT NULL
              AND year < \$2
              AND week BETWEEN \$3 - 2 AND \$3 + 2
            """,
            [bidding_zone, iso_year, iso_week]
        )
    end
    (isempty(norm) || ismissing(norm.med[1]) || Float64(norm.med[1]) <= 0.0) && return nothing

    return clamp(1.0 - Float64(current.stored_energy_mwh[1]) / Float64(norm.med[1]), 0.0, 1.0)
end

"""
    get_reservoir_drawdown(bidding_zone::String, day::Date) -> Union{Float64,Nothing}

Absolute reservoir DRAWDOWN: `clamp(1 - stored / trailing-52-week max, 0, 1)`,
using the latest stored energy strictly before `day`'s ISO week and the maximum
stored energy over the preceding 52 weeks (both ex-ante — only weeks before the
market day enter). 0 at the seasonal reservoir peak (autumn), rising toward 1 as
the reservoir empties through winter into spring.

This is the SEASONAL complement to `get_reservoir_dryness`. Dryness normalizes
against the *same week of prior years*, so a normal winter drawdown reads
dryness ≈ 0 even though the water is absolutely scarce and its shadow value is
high (measured: SE1/SE2 reservoirs draw down to 55–60% of the annual max by
February at dryness 0, yet the model priced their water at the full-reservoir
floor → SE1/SE2 clearing ≈ €18 vs actual ≈ €59). Drawdown restores that seasonal
water-value signal from fundamentals (reservoir physics), with no month dummies.
"""
function get_reservoir_drawdown(bidding_zone::String, day::Date)
    iso_week = Int(Dates.week(day))
    iso_year = year(day)
    # cv22 bug-fix (gated by EUPHEMIA_DISABLE_CV22): the lower-bound disjunct
    # `year > $2 - 2` admitted ALL of year Y-1 plus year Y up to the current
    # week — a 52–104-week window, not the documented "preceding 52 weeks"
    # ([(Y-1, iso_week) .. (Y, iso_week-1)]). It also made the second disjunct
    # `(year = Y-1 AND week >= iso_week)` dead. `$2 - 1` restores the intended
    # 52-week trailing window. Nordic reservoir-opportunity zones only; year-round
    # effect (see docs/experiments/cv22.md).
    lb = isempty(get(ENV, "EUPHEMIA_DISABLE_CV22", "")) ? 1 : 2
    df = sql2df_with_retry(
        """
        WITH hist AS (
          SELECT year, week, stored_energy_mwh
          FROM entsoe.aggregated_hydro_storage_filling_rate
          WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
            AND stored_energy_mwh IS NOT NULL
            AND (year < \$2 OR (year = \$2 AND week < \$3))
            AND (year > \$2 - $lb OR (year = \$2 - 1 AND week >= \$3))
        )
        SELECT (SELECT stored_energy_mwh FROM hist ORDER BY year DESC, week DESC LIMIT 1) AS cur,
               (SELECT MAX(stored_energy_mwh) FROM hist) AS mx
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(df) || ismissing(df.cur[1]) || ismissing(df.mx[1]) ||
        Float64(df.mx[1]) <= 0.0) && return nothing
    return clamp(1.0 - Float64(df.cur[1]) / Float64(df.mx[1]), 0.0, 1.0)
end

