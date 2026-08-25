struct Load
    timeslot::String
    resolution_code::String
    bidding_zone::String
    value::Float64
end

function get_loads()
    return [Load("20250624-00", "60", "GR", 42.0)]
end

"""
    get_loads(zone, day) -> Vector{Load}

The TSO day-ahead load forecast for `day`, cleaned like the RES forecast
(2026-08-25, the load twin of the #342 RES fix):

1. **Mixed resolutions** — some zone-days carry PT15M and PT60M rows together
   (SE1-4 2025-12-01, SI 2026-05-19, SK 2024-06-30); downstream picked a
   parent by Dict iteration order. Exactly one resolution is kept: the one
   with the most hours covered, ties to the coarser.
2. **NULL values** take the nearest published value in the day, else the
   zone's latest published value at the same time-of-day within 7 days, else
   the row is dropped (a load hour cannot be 0) — always logged.
3. **Absent slots** — a TSO sometimes publishes the CET day (GR 2025-11-12:
   23:00–23:00 UTC, so the UTC-day window holds 23 hours) or skips slots
   (SI 15 days, BG/BE 6 each in 2025-07..2026-06); the coupled timeslot
   intersection then collapsed for all 39 zones (2025-11-12: 1 period,
   2026-06-03: 2 periods — day refused). See step 3 in the body.
"""
function get_loads(bidding_zone::String, day::Dates.Date; fallback_days::Int=7)
    query = """
    SELECT
        date_time_utc,
        resolution_code,
        total_load_mw
    FROM
        entsoe.day_ahead_total_load_forecast
    WHERE
        date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
        AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
        AND area_map_code = \$2
        AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
    ORDER BY date_time_utc;
    """

    df = Euphemia.sql2df_with_retry(query, [day, bidding_zone])
    isempty(df) && return Load[]

    # 1. one resolution: most hours with a published value, tie -> coarser
    resolutions = unique(String.(df.resolution_code))
    if length(resolutions) > 1
        hours = Dict{String,Set{Dates.DateTime}}()
        for row in eachrow(df)
            ismissing(row.total_load_mw) && continue
            push!(get!(hours, String(row.resolution_code), Set{Dates.DateTime}()),
                  trunc(DateTime(row.date_time_utc), Dates.Hour))
        end
        cover(r) = length(get(hours, r, Set{Dates.DateTime}()))
        best = resolutions[1]
        for r in resolutions[2:end]
            if cover(r) > cover(best) ||
               (cover(r) == cover(best) &&
                parse_resolution_to_minutes(r) > parse_resolution_to_minutes(best))
                best = r
            end
        end
        # Rows of the other resolution(s) that cover hours the chosen one
        # LACKS are converted, not discarded (GR 2025-11-12: hours 00-22 at
        # PT60M and 23:00 as four PT15M rows — dropping them lost the hour).
        best_min = parse_resolution_to_minutes(best)
        chosen = df[String.(df.resolution_code) .== best, :]
        covered = Set(trunc(DateTime(t), Dates.Hour) for t in chosen.date_time_utc)
        extra = df[(String.(df.resolution_code) .!= best) .&
                   [!(trunc(DateTime(t), Dates.Hour) in covered) for t in df.date_time_utc] .&
                   .!ismissing.(df.total_load_mw), :]
        converted = DataFrame(date_time_utc=DateTime[], resolution_code=String[], total_load_mw=Float64[])
        for row in eachrow(extra)
            m = parse_resolution_to_minutes(String(row.resolution_code))
            t = DateTime(row.date_time_utc)
            if m < best_min
                # finer -> average into the coarse slot
                slot = DateTime(Date(t)) + Dates.Minute(best_min * div(60 * Dates.hour(t) + Dates.minute(t), best_min))
                i = findfirst(==(slot), converted.date_time_utc)
                if i === nothing
                    push!(converted, (slot, best, Float64(row.total_load_mw)))
                else
                    converted.total_load_mw[i] = (converted.total_load_mw[i] + Float64(row.total_load_mw)) / 2
                end
            else
                # coarser -> replicate the MW value to the finer slots it spans
                for k in 0:(div(m, best_min) - 1)
                    push!(converted, (t + Dates.Minute(k * best_min), best, Float64(row.total_load_mw)))
                end
            end
        end
        dropped = nrow(df) - nrow(chosen) - nrow(extra)
        @warn "Load forecast $bidding_zone $day: mixed resolutions $(resolutions) — keeping $best, " *
              "$(nrow(converted)) slot(s) converted from the other resolution, $dropped duplicate row(s) discarded"
        df = vcat(chosen, converted)
        sort!(df, :date_time_utc)
    end

    # 2. NULL values
    n_missing = count(ismissing, df.total_load_mw)
    if n_missing > 0
        vals = Vector{Union{Missing,Float64}}(df.total_load_mw)
        known = [!ismissing(v) for v in vals]
        nearest = 0
        for i in eachindex(vals)
            known[i] && continue
            ti = DateTime(df.date_time_utc[i]); best = 0; bestd = typemax(Int)
            for j in eachindex(vals)
                known[j] || continue
                d = abs(Dates.value(DateTime(df.date_time_utc[j]) - ti))
                d < bestd && (best = j; bestd = d)
            end
            best == 0 && continue
            vals[i] = vals[best]; nearest += 1
        end
        filled = 0
        if any(ismissing, vals)
            hist = Euphemia.sql2df_with_retry("""
                SELECT date_time_utc, resolution_code, total_load_mw
                FROM entsoe.day_ahead_total_load_forecast
                WHERE date_time_utc >= ((\$1::date - \$3::int)::timestamp AT TIME ZONE 'UTC')
                  AND date_time_utc < (\$1::date::timestamp AT TIME ZONE 'UTC')
                  AND area_map_code = \$2
                  AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
                  AND total_load_mw IS NOT NULL
                ORDER BY date_time_utc
                """, [day, bidding_zone, fallback_days])
            latest = Dict{Tuple{String,Dates.Time},Float64}()
            for row in eachrow(hist)
                latest[(String(row.resolution_code), Dates.Time(DateTime(row.date_time_utc)))] =
                    Float64(row.total_load_mw)
            end
            for i in eachindex(vals)
                ismissing(vals[i]) || continue
                k = (String(df.resolution_code[i]), Dates.Time(DateTime(df.date_time_utc[i])))
                haskey(latest, k) && (vals[i] = latest[k]; filled += 1)
            end
        end
        dropped = count(ismissing, vals)
        @warn "Load forecast $bidding_zone $day: $n_missing NULL value(s) — $nearest from the nearest " *
              "published value in the day, $filled from the latest value within $fallback_days days, " *
              "$dropped row(s) dropped"
        keep = [!ismissing(v) for v in vals]
        df = df[keep, :]
        df.total_load_mw = Float64[v for v in vals[keep]]
    end

    # 3. ABSENT slots (2026-08-25): a TSO sometimes publishes the CET day
    #    (23:00-23:00 UTC), so the UTC-day window holds 23 of 24 hours (GR
    #    2025-11-12), or a few slots are simply missing (SI 15 days, BG/BE 6
    #    each in 2025-07..2026-06). One short zone collapses the coupled
    #    timeslot intersection for all 39 zones and the day is refused. When
    #    at least half of the day is present, the missing slots take the
    #    zone's latest published value at the same time-of-day within
    #    `fallback_days` (persistence, ex-ante); a mostly-missing day is left
    #    as published (the truncation gate then refuses it, correctly).
    res_code = String(df.resolution_code[1])
    step = Dates.Minute(parse_resolution_to_minutes(res_code))
    expected = collect(DateTime(day):step:(DateTime(day + Dates.Day(1)) - step))
    present = Set(DateTime.(df.date_time_utc))
    absent = [t for t in expected if !(t in present)]
    out = [Load(Dates.format(row.date_time_utc, "yyyymmdd-HHMM"), row.resolution_code,
                bidding_zone, Float64(row.total_load_mw)) for row in eachrow(df)]
    if !isempty(absent) && length(present) >= length(expected) ÷ 2
        hist = Euphemia.sql2df_with_retry("""
            SELECT date_time_utc, total_load_mw
            FROM entsoe.day_ahead_total_load_forecast
            WHERE date_time_utc >= ((\$1::date - \$4::int)::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND area_map_code = \$2 AND resolution_code = \$3
              AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
              AND total_load_mw IS NOT NULL
            ORDER BY date_time_utc
            """, [day, bidding_zone, res_code, fallback_days])
        latest = Dict{Dates.Time,Float64}()
        for row in eachrow(hist)
            latest[Dates.Time(DateTime(row.date_time_utc))] = Float64(row.total_load_mw)
        end
        filled = 0
        for t in absent
            haskey(latest, Dates.Time(t)) || continue
            push!(out, Load(Dates.format(t, "yyyymmdd-HHMM"), res_code, bidding_zone, latest[Dates.Time(t)]))
            filled += 1
        end
        sort!(out; by=l -> l.timeslot)
        @warn "Load forecast $bidding_zone $day: $(length(absent)) slot(s) absent in the UTC day " *
              "($(length(present))/$(length(expected)) published) — $filled filled from the latest " *
              "published value within $fallback_days days"
    elseif !isempty(absent)
        @warn "Load forecast $bidding_zone $day: only $(length(present))/$(length(expected)) slots " *
              "published — left as is (the truncation gate decides)"
    end
    return out
end
