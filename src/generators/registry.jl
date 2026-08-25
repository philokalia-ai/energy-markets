# registry.jl — The unit registry: day-level outage cache, per-zone memoized get_generators query with dedup and validity fallbacks.
# Included by ../Generators.jl inside `module Euphemia` (definition order preserved).

# =============================================================================
# Day-level outage cache
# =============================================================================
# The unavailability table (entsoe.unavailability_of_production_and_generation_units,
# ~13.6M rows / 9.4 GB) has no index that serves the outage-overlap predicate, so
# every get_generators() call used to seq-scan it (~3 s), casting the text
# start/end_outage_utc columns per row. That work is IDENTICAL for every zone on a
# given market day, so a 39-zone book build (+ pass-2 rebuilds) paid it ~50 times.
# Compute it ONCE per day here — across ALL zones — and let each zone's query
# consume the result via array parameters instead of recomputing the CTEs.
#
# Cached value: a DataFrame with one row per asset_code whose CURRENT-version
# 'Active' outage message covers at least 12 hours of `day`, carrying:
#   - available_capacity_mw: MIN over the asset's overlapping rows, NULL -> 0.0.
#     (The per-zone query treats NULL and 0 identically — both fail
#     `available_capacity_mw > 0` and both COALESCE to installed capacity — so the
#     final generator list is unchanged by the NULL->0 normalization.)
#   - stale_override: TRUE when the unit demonstrably generated (>1 MW) during its
#     claimed outage in the 7 days before `day` (hard-evidence override for stale
#     'Active' 0-MW records, e.g. Romanian hydro).
# The probe starts at the binding (0-MW) record's start, not at the earliest
# row of any partial derate, so generation during an old partial derate cannot
# "prove wrong" a full outage that began later.
#
# Semantics fixed 2026-08-24 (bug sweep):
#   * Latest version per message — ENTSO-E publishes every outage message as
#     versioned rows sharing `instance_code`; a cancellation, withdrawal or
#     end-date change is a NEW row and the superseded rows keep status='Active'.
#     Applying them removed cancelled outages' capacity for their whole original
#     window (2026-04-03: FR 16.0 GW, DE_LU 9.1 GW, ES 5.7 GW, PL 5.4 GW).
#   * cv34: "latest" means latest AS KNOWN AT THE GATE (D-1 10:00 UTC) for
#     delivery days from 2025-10-01, where the publication timestamp is a real
#     TSO time; a same-day forced outage published after the gate no longer
#     reaches the book (2026-04-03: DE_LU 1.9 GW, GR 837 MW were lookahead).
#   * Day overlap, not a midnight instant — the old predicate tested whether the
#     outage covered D 00:00 UTC, so an outage starting 06:00 on D was ignored
#     for all of D (~70 asset-days/day, ~18 GW) and one ending 00:30 on D
#     excluded the unit for 24 h. p_max is a day-level quantity, so an outage
#     counts when it covers the MAJORITY (>= 12 h) of the day.
#   * Grouped by asset_code alone: an outage filed under a different area code
#     than the registry's zone (Italian units filed as IT / another sub-zone)
#     now applies to the unit wherever the registry places it.
const _OUTAGE_DAY_CACHE = Dict{Dates.Date,DataFrames.DataFrame}()
const _OUTAGE_DAY_CACHE_LOCK = ReentrantLock()

# Per-(zone, day, flags) memo of the final Vector{Generator}, so pass-2 anchored
# rebuilds and repeated builds within one process do not re-query. Cleared per
# process. Callers mutate the returned vector (fleet completion push!/filter), so
# callers always receive a shallow copy — the cached vector is never handed out.
const _GENERATOR_MEMO = Dict{Tuple{String,Dates.Date,Bool,Bool},Vector{Generator}}()
const _GENERATOR_MEMO_LOCK = ReentrantLock()

# Registry sanity bound. ENTSO-E's unit registry carries rare corrupt
# `installed_capacity_mw` values (e.g. IT-CSOUTH unit `26WUUUUUUBUSSI19` at
# 13,068,005 MW — a small plant with a mangled capacity), which propagate into
# the merit-order book as a multi-million-MW supply block that erases scarcity
# and pins the zone at gas SRMC (IT-CSOUTH's clearing price is flat → its
# price-vs-actual correlation is undefined/NaN). No real single generation unit
# approaches this: the largest European generation units are ≈1.7 GW (nuclear)
# and the biggest aggregate registry rows are a few GW, so a 25 GW ceiling
# rejects only garbage while leaving every genuine unit untouched (verified: no
# unit in the 39-zone footprint reaches it, so every zone but IT-CSOUTH is
# byte-identical). Surfaced by the GME MGP book comparison
# (docs/experiments/gme-book-comparison).
# cv25 fix 4 (gated by EUPHEMIA_DISABLE_FLEETPROBE_FIX): the 60-day
# recent-generation probe decides fleet membership for stale-registry units, and
# its upper bound `< $2 + INTERVAL '1 day'` INCLUDED the delivery day — a unit
# could enter day D's fleet BECAUSE it generated on day D (measured: ~37% of
# sampled days carry at least one such unit). The sibling probe in
# get_day_outages always used the strict `< $1`. The fix makes this one match.
# NOTE: `get_generators` memoizes per (zone, day, ...) WITHOUT this switch in
# the key — ablation arms must run in separate processes with the env set at
# launch, never flip it mid-process.
_fleet_probe_upper() =
    isempty(get(ENV, "EUPHEMIA_DISABLE_FLEETPROBE_FIX", "")) ?
        "\$2::timestamp" : "\$2::timestamp + INTERVAL '1 day'"

const MAX_PLAUSIBLE_UNIT_MW = 25_000.0

"""
    get_day_outages(day::Date) -> DataFrame

Once-per-day (all-zone) active-outage table backing `get_generators`. See the
`_OUTAGE_DAY_CACHE` comment for the schema and the row-identity argument. Cached
per day; never cached on DB error (the exception propagates out of `get!`).
"""
function get_day_outages(day::Dates.Date)
    return lock(_OUTAGE_DAY_CACHE_LOCK) do
        get!(_OUTAGE_DAY_CACHE, day) do
            Euphemia.sql2df_with_retry(
                """
                WITH cand AS (
                    -- every message with ANY version overlapping the day
                    SELECT DISTINCT instance_code
                    FROM entsoe.unavailability_of_production_and_generation_units
                    WHERE start_outage_utc::timestamp < \$1::timestamp + INTERVAL '1 day'
                      AND end_outage_utc::timestamp > \$1::timestamp
                ),
                vers AS (
                    -- the version of each message as KNOWN AT THE GATE (D-1
                    -- 10:00 UTC — the 12:00 CET/CEST auction, conservative):
                    -- versions published after the gate did not exist to the
                    -- auction. version_publication_timestamp_utc is a real TSO
                    -- time only from 2025-09-28 (before that it holds the ETL
                    -- ingestion time), so the vintage filter applies to delivery
                    -- days from 2025-10-01 — the documented seam (cv34).
                    -- Before the seam / for NULLs the latest version counts.
                    SELECT u.*,
                           ROW_NUMBER() OVER (PARTITION BY u.instance_code ORDER BY u.version DESC) AS rn
                    FROM entsoe.unavailability_of_production_and_generation_units u
                    JOIN cand USING (instance_code)
                    WHERE $(isempty(get(ENV, "EUPHEMIA_DISABLE_CV34_GATE", "")) ? "" : "TRUE OR ")
                       \$1::date < DATE '2025-10-01'
                       OR version_publication_timestamp_utc IS NULL
                       OR version_publication_timestamp_utc::timestamp < \$1::timestamp - INTERVAL '14 hours'
                ),
                active_outages AS (
                    SELECT asset_code,
                           MIN(available_capacity_mw) AS available_capacity_mw,
                           COALESCE(
                               MIN(start_outage_utc::timestamp)
                                   FILTER (WHERE COALESCE(available_capacity_mw, 0.0) <= 0.0),
                               MIN(start_outage_utc::timestamp)) AS earliest_start
                    FROM vers
                    WHERE rn = 1
                      AND status = 'Active'
                      AND start_outage_utc::timestamp < \$1::timestamp + INTERVAL '1 day'
                      AND end_outage_utc::timestamp > \$1::timestamp
                      AND LEAST(end_outage_utc::timestamp, \$1::timestamp + INTERVAL '1 day')
                          - GREATEST(start_outage_utc::timestamp, \$1::timestamp) >= INTERVAL '12 hours'
                    GROUP BY asset_code
                )
                SELECT o.asset_code,
                       COALESCE(o.available_capacity_mw, 0.0) AS available_capacity_mw,
                       EXISTS (
                           SELECT 1
                           FROM entsoe.actual_generation_output_per_generation_unit a
                           WHERE a.generation_unit_code = o.asset_code
                             AND a.date_time_utc >= GREATEST(o.earliest_start, \$1::timestamp - INTERVAL '7 days')
                             AND a.date_time_utc < \$1::timestamp
                             AND a.actual_generation_output_mw > 1
                       ) AS stale_override
                FROM active_outages o
                """,
                [day])
        end
    end
end

"""
    clear_generator_caches!()

Clear the day-level outage cache and the per-zone generator memo. Useful in tests
and before cold-start profiling.
"""
function clear_generator_caches!()
    lock(_OUTAGE_DAY_CACHE_LOCK) do
        empty!(_OUTAGE_DAY_CACHE)
    end
    lock(_GENERATOR_MEMO_LOCK) do
        empty!(_GENERATOR_MEMO)
    end
    return nothing
end

# pull from postgres, for now only active units of given date (I think)
# exclude_unavailable: if true, excludes generators with active outages and reduces capacity for partial outages
# infer_ramp_rates: if true, infer ramp rates from historical generation data (3 months)
function get_generators(map_code::String, day::Dates.Date;
                       exclude_unavailable::Bool=true,
                       exclude_variable_renewables::Bool=true)
    memo_key = (map_code, day, exclude_unavailable, exclude_variable_renewables)
    cached = lock(_GENERATOR_MEMO_LOCK) do
        get(_GENERATOR_MEMO, memo_key, nothing)
    end
    cached !== nothing && return copy(cached)
    _FUEL_LOOKUP_FAILED[] = false

    # Per-zone outage arrays, sliced from the once-per-day all-zone cache and
    # fed to the query below via unnest (replacing the old zone-independent
    # active_outages / stale_outage_override CTEs).
    outage_codes = String[]
    outage_avail = Float64[]
    stale_codes = String[]
    if exclude_unavailable
        # The whole day table (all zones): the query joins on asset_code, so an
        # outage filed under another area code still reaches the zone's unit.
        sub = get_day_outages(day)
        outage_codes = String.(sub.asset_code)
        outage_avail = Float64[ismissing(v) ? 0.0 : Float64(v) for v in sub.available_capacity_mw]
        stale_mask = Bool[coalesce(s, false) for s in sub.stale_override]
        stale_codes = String.(sub.asset_code[stale_mask])
    end

    if exclude_unavailable
        # Query with unavailability filtering:
        # - Excludes generators with complete outages (available_capacity_mw = 0)
        # - Reduces p_max for partial outages (available_capacity_mw > 0)
        # - Only considers 'Active' status outages (ignores Cancelled/Withdrawn)
        # - Uses MIN available capacity when multiple outage records exist (conservative)
        # Note: DISTINCT ON deduplicates by generation_unit_code since ENTSO-E data
        # can have overlapping validity periods for the same generator (data quality issue).
        # We take the most recent version (by valid_from) with highest capacity as tiebreaker.
        #
        # Date validity filter relaxation:
        # ENTSO-E data has stale valid_from/valid_to dates for many operating plants.
        # Example: Spain nuclear has valid_from in 2026 (future!), Germany coal has valid_to in 2022.
        # Solution: Include plants that EITHER pass date validity OR have recent actual generation.
        # This uses hard evidence (actual_generation_output) to include operating plants.
        #
        # active_outages and stale_outage_override are no longer recomputed here:
        # both are zone-independent day-level work (a 3 s seq-scan of the 9.4 GB
        # unavailability table) that get_day_outages() computes ONCE per day for
        # all zones. This query consumes the zone's slice as array parameters
        # ($3 asset codes, $4 available_capacity_mw, $5 stale-override codes) and
        # rebuilds the same relations via unnest — same rows, same result.
        query = """
        WITH active_outages AS (
            SELECT asset_code, available_capacity_mw
            FROM unnest(\$3::text[], \$4::float8[]) AS t(asset_code, available_capacity_mw)
        ),
        -- Find generators with recent actual generation (last 60 days)
        -- This catches plants with stale validity dates that are still operating.
        -- Restricting to the zone's unit codes lets the
        -- (generation_unit_code, date_time_utc) index drive the lookup —
        -- a date-only filter would scan the 54 GB table (~150 s per call).
        recent_generation AS (
            SELECT DISTINCT generation_unit_code
            FROM entsoe.actual_generation_output_per_generation_unit
            WHERE generation_unit_code IN (
                    SELECT DISTINCT generation_unit_code
                    FROM entsoe.production_and_generation_units
                    WHERE area_map_code = \$1)
              AND date_time_utc >= \$2::timestamp - INTERVAL '60 days'
              AND date_time_utc < $(_fleet_probe_upper())
              AND actual_generation_output_mw > 0
        ),
        -- Hard-evidence override for stale outage records (computed per day in
        -- get_day_outages): a unit that produced power DURING its claimed
        -- complete outage proves the record wrong. ENTSO-E has multi-year
        -- 'Active' 0-MW outage records for units that are actually running
        -- (e.g. Romanian hydro), which would otherwise be excluded.
        stale_outage_override AS (
            SELECT unnest(\$5::text[]) AS generation_unit_code
        )
        SELECT DISTINCT ON (g.generation_unit_code)
            g.valid_from,
            g.valid_to,
            g.production_unit_code,
            g.production_unit_name,
            g.production_unit_status,
            g.production_unit_type,
            g.production_unit_location,
            g.production_unit_installed_capacity_mw,
            g.production_unit_voltage_kv,
            g.area_code,
            g.area_display_name,
            g.area_type_code,
            g.area_map_code,
            g.generation_unit_code,
            g.generation_unit_name,
            g.generation_unit_status,
            g.generation_unit_type,
            g.generation_unit_location,
            -- Use available capacity if partial outage, otherwise installed capacity
            COALESCE(
                CASE
                    WHEN o.available_capacity_mw > 0
                        THEN LEAST(o.available_capacity_mw, g.generation_unit_installed_capacity_mw)
                    ELSE NULL
                END,
                g.generation_unit_installed_capacity_mw
            ) AS generation_unit_installed_capacity_mw,
            g.update_time_utc,
            g.source,
            -- Include outage info for debugging/logging
            o.available_capacity_mw AS outage_available_capacity
        FROM
            entsoe.production_and_generation_units g
        LEFT JOIN active_outages o ON g.generation_unit_code = o.asset_code
        LEFT JOIN recent_generation rg ON g.generation_unit_code = rg.generation_unit_code
        LEFT JOIN stale_outage_override so ON g.generation_unit_code = so.generation_unit_code
        WHERE
            g.production_unit_status = 'COMMISSIONED'
            AND g.generation_unit_status = 'COMMISSIONED'
            AND g.area_type_code IN ('BZN', 'BZN/CTA')
            AND g.area_map_code = \$1
            -- Include if: passes date validity OR has recent actual generation
            AND (
                DATE(\$2)
                    BETWEEN DATE(g.valid_from)
                    AND COALESCE(
                            DATE(g.valid_to),
                            DATE(\$2) + INTERVAL '1 year'
                        )
                OR rg.generation_unit_code IS NOT NULL
            )
            -- Exclude complete outages (available_capacity = 0), unless the
            -- unit demonstrably generated during the claimed outage
            AND (o.asset_code IS NULL OR o.available_capacity_mw > 0
                 OR so.generation_unit_code IS NOT NULL)
        -- The validity row that actually covers the day wins; only then the most
        -- recent valid_from (stale-date fallback) and capacity as tiebreakers.
        -- (Without the first key a FUTURE-dated row wins for every past day —
        -- IT-CSOUTH 26WUUUUUUBUSSI19's corrupt 13 GW 2025-12-31 row displaced its
        -- correct 122 MW row on all dates and got the unit dropped entirely.)
        ORDER BY g.generation_unit_code,
                 (DATE(\$2) >= DATE(g.valid_from)
                  AND (g.valid_to IS NULL OR DATE(\$2) < DATE(g.valid_to))) DESC,
                 g.valid_from DESC,
                 g.generation_unit_installed_capacity_mw DESC
        """
    else
        # Original query without unavailability filtering
        # Note: DISTINCT ON deduplicates by generation_unit_code since ENTSO-E data
        # can have overlapping validity periods for the same generator (data quality issue).
        #
        # Date validity filter relaxation (same as above):
        # Include plants that EITHER pass date validity OR have recent actual generation.
        query = """
        WITH recent_generation AS (
            SELECT DISTINCT generation_unit_code
            FROM entsoe.actual_generation_output_per_generation_unit
            WHERE generation_unit_code IN (
                    SELECT DISTINCT generation_unit_code
                    FROM entsoe.production_and_generation_units
                    WHERE area_map_code = \$1)
              AND date_time_utc >= \$2::timestamp - INTERVAL '60 days'
              AND date_time_utc < $(_fleet_probe_upper())
              AND actual_generation_output_mw > 0
        )
        SELECT DISTINCT ON (g.generation_unit_code)
            g.valid_from,
            g.valid_to,
            g.production_unit_code,
            g.production_unit_name,
            g.production_unit_status,
            g.production_unit_type,
            g.production_unit_location,
            g.production_unit_installed_capacity_mw,
            g.production_unit_voltage_kv,
            g.area_code,
            g.area_display_name,
            g.area_type_code,
            g.area_map_code,
            g.generation_unit_code,
            g.generation_unit_name,
            g.generation_unit_status,
            g.generation_unit_type,
            g.generation_unit_location,
            g.generation_unit_installed_capacity_mw,
            g.update_time_utc,
            g.source
        FROM
            entsoe.production_and_generation_units g
        LEFT JOIN recent_generation rg ON g.generation_unit_code = rg.generation_unit_code
        WHERE
            g.production_unit_status = 'COMMISSIONED'
            AND g.generation_unit_status = 'COMMISSIONED'
            AND g.area_type_code IN ('BZN', 'BZN/CTA')
            AND g.area_map_code = \$1
            -- Include if: passes date validity OR has recent actual generation
            AND (
                DATE(\$2)
                    BETWEEN DATE(g.valid_from)
                    AND COALESCE(
                            DATE(g.valid_to),
                            DATE(\$2) + INTERVAL '1 year'
                        )
                OR rg.generation_unit_code IS NOT NULL
            )
        -- The validity row that actually covers the day wins; only then the most
        -- recent valid_from (stale-date fallback) and capacity as tiebreakers.
        -- (Without the first key a FUTURE-dated row wins for every past day —
        -- IT-CSOUTH 26WUUUUUUBUSSI19's corrupt 13 GW 2025-12-31 row displaced its
        -- correct 122 MW row on all dates and got the unit dropped entirely.)
        ORDER BY g.generation_unit_code,
                 (DATE(\$2) >= DATE(g.valid_from)
                  AND (g.valid_to IS NULL OR DATE(\$2) < DATE(g.valid_to))) DESC,
                 g.valid_from DESC,
                 g.generation_unit_installed_capacity_mw DESC
        """
    end

    # The exclude_unavailable query binds the day-level outage arrays as $3-$5;
    # the else branch uses only $1/$2 (extra params are harmless but omitted).
    query_args = exclude_unavailable ? Any[map_code, day, outage_codes, outage_avail, stale_codes] :
                 Any[map_code, day]
    df = Euphemia.sql2df_with_retry(query, query_args)

    # Build generators (without ramp rates initially)
    generators = Generator[]
    for row in eachrow(df)
        # Registry sanity bound: drop rows whose installed capacity exceeds any
        # physically-plausible generation unit (corrupt ENTSO-E capacities — see
        # MAX_PLAUSIBLE_UNIT_MW). Only IT-CSOUTH carries such a row in the
        # footprint, so every other zone is byte-identical.
        if Float64(row.generation_unit_installed_capacity_mw) > MAX_PLAUSIBLE_UNIT_MW
            @warn "Dropping corrupt registry capacity" unit=row.generation_unit_code zone=map_code capacity_mw=Float64(row.generation_unit_installed_capacity_mw)
            continue
        end
        # Infer actual fuel type from name if declared as "Other".
        # normalize_fuel_type_name folds ENTSO-E spelling variants (e.g.
        # Romania publishes "Hydro Run-of-river and pondage") onto the
        # canonical names every downstream table keys on.
        declared_type = Symbol(normalize_fuel_type_name(row.generation_unit_type))
        inferred_type = infer_fuel_type_from_name(row.generation_unit_name, declared_type)

        if inferred_type != declared_type
            @info "Reclassified generator $(row.generation_unit_name) from $declared_type to $inferred_type"
        end

        gen = Generator(
            row.generation_unit_code,                    # code
            row.generation_unit_name,                    # name
            inferred_type,                               # fuel_type (possibly inferred)
            row.generation_unit_location,                # location
            Float64(row.generation_unit_installed_capacity_mw), # p_max
            get_min_active_capacity(
                Float64(row.generation_unit_installed_capacity_mw),
                inferred_type
            ), # p_min (fuel-type-specific)
            row.area_map_code,                           # bidding_zone
            get_marginal_cost(
                day,
                normalize_fuel_type_name(row.generation_unit_type),  # Original (not name-inferred) type for cost — BESS still has storage costs
                row.area_display_name
            )                                           # marginal_cost
        )
        push!(generators, gen)
    end

    # Filter out variable renewables (wind, solar) if requested
    # These are handled separately via renewable forecasts subtracted from load
    if exclude_variable_renewables
        pre_filter_count = length(generators)
        generators = filter(g -> g.fuel_type ∉ VARIABLE_RENEWABLE_TYPES, generators)
        filtered_count = pre_filter_count - length(generators)
        if filtered_count > 0
            @info "Filtered out $filtered_count variable renewable generators (Wind/Solar) from UC"
        end
    end

    # Memoize the canonical result and hand callers a copy (they mutate it) —
    # unless a fuel-price lookup failed during this build (fallback costs must
    # not be pinned for the process lifetime; the next call retries the DB).
    if _FUEL_LOOKUP_FAILED[]
        @warn "get_generators($map_code, $day): fuel-price lookup failed during the build — result NOT memoized"
    else
        lock(_GENERATOR_MEMO_LOCK) do
            _GENERATOR_MEMO[memo_key] = generators
        end
    end
    return copy(generators)
end

