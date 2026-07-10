# Identity guard for the day-level-outage-cache refactor of get_generators
# (PR perf/book-build). The new get_generators computes the zone-independent
# active-outage and stale-override work ONCE per day (get_day_outages) and feeds
# each zone's slice to the per-zone query as array parameters. This test proves
# the rewrite returns EXACTLY the same generators as the original zone-filtered
# CTE query, for a spread of zones and a crisis-year date.
#
# `old_get_generators` below is a verbatim copy of the original function body
# (the pre-refactor SQL with the in-query active_outages / stale_outage_override
# CTEs), so the two paths can be compared in one process.

using Test
using Dates
using Euphemia

# --- Original implementation (pre-refactor), reproduced for comparison --------
function old_get_generators(map_code::String, day::Dates.Date;
                            exclude_unavailable::Bool=true,
                            exclude_variable_renewables::Bool=true)
    query = """
    WITH active_outages AS (
        SELECT
            asset_code,
            MIN(available_capacity_mw) AS available_capacity_mw,
            MIN(start_outage_utc::timestamp) AS earliest_start
        FROM entsoe.unavailability_of_production_and_generation_units
        WHERE status = 'Active'
          AND area_map_code = \$1
          AND \$2::timestamp >= start_outage_utc::timestamp
          AND \$2::timestamp < end_outage_utc::timestamp
        GROUP BY asset_code
    ),
    recent_generation AS (
        SELECT DISTINCT generation_unit_code
        FROM entsoe.actual_generation_output_per_generation_unit
        WHERE generation_unit_code IN (
                SELECT DISTINCT generation_unit_code
                FROM entsoe.production_and_generation_units
                WHERE area_map_code = \$1)
          AND date_time_utc >= \$2::timestamp - INTERVAL '60 days'
          AND date_time_utc < \$2::timestamp + INTERVAL '1 day'
          AND actual_generation_output_mw > 0
    ),
    stale_outage_override AS (
        SELECT o.asset_code AS generation_unit_code
        FROM active_outages o
        WHERE EXISTS (
            SELECT 1
            FROM entsoe.actual_generation_output_per_generation_unit a
            WHERE a.generation_unit_code = o.asset_code
              AND a.date_time_utc >= GREATEST(o.earliest_start, \$2::timestamp - INTERVAL '7 days')
              AND a.date_time_utc < \$2::timestamp
              AND a.actual_generation_output_mw > 1
        )
    )
    SELECT DISTINCT ON (g.generation_unit_code)
        g.valid_from, g.valid_to, g.production_unit_code, g.production_unit_name,
        g.production_unit_status, g.production_unit_type, g.production_unit_location,
        g.production_unit_installed_capacity_mw, g.production_unit_voltage_kv,
        g.area_code, g.area_display_name, g.area_type_code, g.area_map_code,
        g.generation_unit_code, g.generation_unit_name, g.generation_unit_status,
        g.generation_unit_type, g.generation_unit_location,
        COALESCE(
            CASE WHEN o.available_capacity_mw > 0 THEN o.available_capacity_mw ELSE NULL END,
            g.generation_unit_installed_capacity_mw
        ) AS generation_unit_installed_capacity_mw,
        g.update_time_utc, g.source,
        o.available_capacity_mw AS outage_available_capacity
    FROM entsoe.production_and_generation_units g
    LEFT JOIN active_outages o ON g.generation_unit_code = o.asset_code
    LEFT JOIN recent_generation rg ON g.generation_unit_code = rg.generation_unit_code
    LEFT JOIN stale_outage_override so ON g.generation_unit_code = so.generation_unit_code
    WHERE
        g.production_unit_status = 'COMMISSIONED'
        AND g.generation_unit_status = 'COMMISSIONED'
        AND g.area_type_code IN ('BZN', 'BZN/CTA')
        AND g.area_map_code = \$1
        AND (
            DATE(\$2) BETWEEN DATE(g.valid_from)
                     AND COALESCE(DATE(g.valid_to), DATE(\$2) + INTERVAL '1 year')
            OR rg.generation_unit_code IS NOT NULL
        )
        AND (o.asset_code IS NULL OR o.available_capacity_mw > 0
             OR so.generation_unit_code IS NOT NULL)
    ORDER BY g.generation_unit_code, g.valid_from DESC, g.generation_unit_installed_capacity_mw DESC
    """
    df = Euphemia.sql2df_with_retry(query, [map_code, day])
    generators = Euphemia.Generator[]
    for row in eachrow(df)
        declared_type = Symbol(Euphemia.normalize_fuel_type_name(row.generation_unit_type))
        inferred_type = Euphemia.infer_fuel_type_from_name(row.generation_unit_name, declared_type)
        gen = Euphemia.Generator(
            row.generation_unit_code, row.generation_unit_name, inferred_type,
            row.generation_unit_location,
            Float64(row.generation_unit_installed_capacity_mw),
            Euphemia.get_min_active_capacity(
                Float64(row.generation_unit_installed_capacity_mw), inferred_type),
            row.area_map_code,
            Euphemia.get_marginal_cost(day,
                Euphemia.normalize_fuel_type_name(row.generation_unit_type),
                row.area_display_name))
        push!(generators, gen)
    end
    if exclude_variable_renewables
        generators = filter(g -> g.fuel_type ∉ Euphemia.VARIABLE_RENEWABLE_TYPES, generators)
    end
    return generators
end

# Comparable, order-independent view of a generator
gkey(g) = (g.code, g.name, g.fuel_type, g.location, g.p_max, g.p_min,
           g.bidding_zone, g.marginal_cost)

function compare_zone(zone, day)
    Euphemia.clear_generator_caches!()   # cold: force the new path to query
    new_gens = Euphemia.get_generators(zone, day)
    old_gens = old_get_generators(zone, day)
    new_sorted = sort(map(gkey, new_gens); by = x -> x[1])
    old_sorted = sort(map(gkey, old_gens); by = x -> x[1])
    return new_sorted, old_sorted
end

@testset "get_generators day-outage-cache identity" begin
    cases = [
        ("GR", Date(2026, 4, 3)),
        ("DE_LU", Date(2026, 4, 3)),
        ("NO1", Date(2026, 4, 3)),
        ("FR", Date(2026, 4, 3)),
        ("GR", Date(2022, 8, 24)),   # crisis-year date
    ]
    for (zone, day) in cases
        @testset "$zone $day" begin
            new_sorted, old_sorted = compare_zone(zone, day)
            @test length(new_sorted) == length(old_sorted)
            @test new_sorted == old_sorted
            if new_sorted != old_sorted
                # Surface the first few differences for diagnosis
                only_new = setdiff(Set(new_sorted), Set(old_sorted))
                only_old = setdiff(Set(old_sorted), Set(new_sorted))
                @info "DIFF $zone $day" n_only_new=length(only_new) n_only_old=length(only_old) first_new=first(collect(only_new), min(3, length(only_new))) first_old=first(collect(only_old), min(3, length(only_old)))
            end
        end
    end

    @testset "memoization returns a mutable-safe copy" begin
        Euphemia.clear_generator_caches!()
        a = Euphemia.get_generators("GR", Date(2026, 4, 3))
        n0 = length(a)
        push!(a, first(a))                       # mutate the returned vector
        b = Euphemia.get_generators("GR", Date(2026, 4, 3))  # memo hit
        @test length(b) == n0                    # not corrupted by the push!
    end
end
