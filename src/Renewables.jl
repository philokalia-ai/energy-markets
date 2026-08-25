struct RES
    code::String
    name::String
    type::Symbol
    location::String
    capacity::Float64
    bidding_zone::String
end

struct RenewablesGenerationForecast
    date_time::String  # e.g. "20250624-00"
    resolution_code::String
    bidding_zone::String # e.g. "GR"
    production_type::String
    aggregated_generation_forecast::Float64
end

"""
    get_generation_forecast_for_wind_and_solar(zone, day) -> Vector{RenewablesGenerationForecast}

The TSO day-ahead wind/solar forecast (ENTSO-E 14.1.D) for `day`, cleaned of two
source defects that used to reach the book (bug sweep 2026-08-24):

1. **Mixed resolutions.** Some zone-days carry BOTH PT15M and PT60M rows for the
   same production type (FR 2026-01-06..08, GR 2025-10-08, LT, SE1-4, SI, SK …).
   Downstream took the resolution of the FIRST row and either summed the hourly
   row on top of its quarters (2-5x RES) or kept only the :00 quarter (1/4 RES);
   FR 2026-01-08 cleared at a 63.5 mean vs 109.9 settled. Per production type
   exactly ONE resolution is kept — the one with the most published values
   (ties -> the coarser) — and if types still differ, the finer ones are
   averaged to the coarsest so every row shares one resolution.
2. **NULL values.** Published rows with a NULL `day_ahead_generation_forecast_mw`
   (17k rows in the 2023-26 extract: PL Jun-2026, ES, SE1-4, DK1/2, IT-*) used
   to throw on the SEE path (the whole zone was dropped from the coupled clear)
   or be coalesced to 0 MW on the EU path (ES 2026-06-11: 16/192 values
   present, cleared 167.5 vs 32.8 settled). Both were wrong. A NULL now takes
   the zone/type's most recent published value for the same time-of-day within
   the previous `fallback_days` (persistence — strictly ex-ante), and only if
   none exists does it become 0 MW, with a warning either way.

`coalesce_missing` is kept for call-site compatibility and no longer changes
the result: every path falls back the same way. Days without either defect
are returned exactly as before (no extra query, same rows, same order).
"""
function get_generation_forecast_for_wind_and_solar(bidding_zone::String, day::Dates.Date;
    coalesce_missing::Bool=false, fallback_days::Int=7)
    # UTC day window as explicit range bounds: sargable (uses
    # idx_res_fcst_zone_time instead of reading every row of the zone) and
    # independent of the session timezone, unlike date(date_time_utc) = day
    query = """
    SELECT
        date_time_utc,
        resolution_code,
        area_map_code,
        production_type,
        day_ahead_generation_forecast_mw -- Note: Table also has intraday_generation_forecast_mw, current_generation_forecast_mw (discovered 2025-11-26)
    FROM
        entsoe.generation_forecasts_for_wind_and_solar
    WHERE
        date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
        AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
        AND area_map_code = \$2
        AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY') -- All codes corresponding to bzns
    ORDER BY date_time_utc, area_map_code
    """

    df = Euphemia.sql2df_with_retry(query, [day, bidding_zone])
    isempty(df) && return RenewablesGenerationForecast[]

    # --- 1. one resolution per production type -------------------------------
    # Compared on HOURS with at least one published value (a PT15M series with
    # a value at :00 and NULL quarters covers the same hours as the PT60M
    # series and must not win on row count); ties go to the coarser series.
    hours = Dict{Tuple{String,String},Set{Dates.DateTime}}()
    counts = Dict{Tuple{String,String},Int}()
    for row in eachrow(df)
        k = (String(row.production_type), String(row.resolution_code))
        counts[k] = get(counts, k, 0) + 1
        ismissing(row.day_ahead_generation_forecast_mw) && continue
        push!(get!(hours, k, Set{Dates.DateTime}()), trunc(DateTime(row.date_time_utc), Dates.Hour))
    end
    cover(k) = length(get(hours, k, Set{Dates.DateTime}()))
    chosen = Dict{String,String}()              # type -> resolution_code
    for (ptype, res) in keys(counts)
        cur = get(chosen, ptype, nothing)
        if cur === nothing || cover((ptype, res)) > cover((ptype, cur)) ||
           (cover((ptype, res)) == cover((ptype, cur)) &&
            parse_resolution_to_minutes(res) > parse_resolution_to_minutes(cur))
            chosen[ptype] = res
        end
    end
    if any(chosen[t] != r for (t, r) in keys(counts))
        dropped = sum(n for ((t, r), n) in counts if chosen[t] != r; init=0)
        @warn "RES forecast $bidding_zone $day: mixed resolutions per production type — " *
              "keeping one per type $(chosen), discarding $dropped duplicate value(s)"
        keep = [chosen[String(row.production_type)] == String(row.resolution_code)
                for row in eachrow(df)]
        df = df[keep, :]
    end

    # --- 2. NULL values -> persistence of the latest published value --------
    known = [!ismissing(v) for v in df.day_ahead_generation_forecast_mw]
    n_missing = count(!, known)
    if n_missing > 0
        hist = Euphemia.sql2df_with_retry("""
            SELECT date_time_utc, resolution_code, production_type, day_ahead_generation_forecast_mw
            FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE date_time_utc >= ((\$1::date - \$3::int)::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND area_map_code = \$2
              AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
              AND day_ahead_generation_forecast_mw IS NOT NULL
            ORDER BY date_time_utc
            """, [day, bidding_zone, fallback_days])
        # (type, resolution, time-of-day) -> latest published value (rows are
        # time-ordered, so the last write wins = the most recent day)
        latest = Dict{Tuple{String,String,Dates.Time},Float64}()
        for row in eachrow(hist)
            latest[(String(row.production_type), String(row.resolution_code),
                    Dates.Time(DateTime(row.date_time_utc)))] =
                Float64(row.day_ahead_generation_forecast_mw)
        end
        filled = 0; zeroed = 0
        vals = Vector{Float64}(undef, nrow(df))
        for (i, row) in enumerate(eachrow(df))
            v = row.day_ahead_generation_forecast_mw
            if ismissing(v)
                k = (String(row.production_type), String(row.resolution_code),
                     Dates.Time(DateTime(row.date_time_utc)))
                if haskey(latest, k)
                    vals[i] = latest[k]; filled += 1; known[i] = true
                else
                    vals[i] = 0.0; zeroed += 1
                end
            else
                vals[i] = Float64(v)
            end
        end
        # Still unknown (no history at that time-of-day — typically NULL
        # quarters of a series the TSO otherwise publishes hourly): take the
        # nearest KNOWN value of the same type/resolution within the day
        # (earlier preferred), i.e. the published :00 value carries across the
        # hour. Only a type with no value at all in the day stays at 0 MW.
        nearest = 0
        if zeroed > 0
            for i in 1:nrow(df)
                known[i] && continue
                ti = DateTime(df.date_time_utc[i]); kt = (String(df.production_type[i]), String(df.resolution_code[i]))
                best = 0; bestd = typemax(Int)
                for j in 1:nrow(df)
                    (known[j] && !ismissing(df.day_ahead_generation_forecast_mw[j])) || continue
                    (String(df.production_type[j]), String(df.resolution_code[j])) == kt || continue
                    d = abs(Dates.value(DateTime(df.date_time_utc[j]) - ti))
                    tj = DateTime(df.date_time_utc[j])
                    # earlier neighbours win ties
                    if d < bestd || (d == bestd && tj < DateTime(df.date_time_utc[best]))
                        best = j; bestd = d
                    end
                end
                best == 0 && continue
                vals[i] = vals[best]; nearest += 1; zeroed -= 1
            end
            # mark them known only after the sweep so fills don't chain
            for i in 1:nrow(df)
                (!known[i] && vals[i] != 0.0) && (known[i] = true)
            end
        end
        df.day_ahead_generation_forecast_mw = vals
        @warn "RES forecast $bidding_zone $day: $n_missing NULL value(s) — $filled filled from the " *
              "latest published value within $fallback_days days, $nearest from the nearest " *
              "published value in the day, $zeroed set to 0 MW (no value at all)"
    end

    # --- 3. a single resolution across production types ---------------------
    resolutions = unique(String.(df.resolution_code))
    if length(resolutions) > 1
        mins = parse_resolution_to_minutes.(resolutions)
        coarsest_min = maximum(mins)
        coarsest = resolutions[findfirst(==(coarsest_min), mins)]
        @warn "RES forecast $bidding_zone $day: production types published at different " *
              "resolutions $(resolutions) — averaging the finer ones to $coarsest"
        # Average the KNOWN values only (published or history-filled); an
        # unfilled NULL must not drag the average to a quarter of the truth.
        acc = Dict{Tuple{String,Dates.DateTime},Tuple{Float64,Int}}()
        for (i, row) in enumerate(eachrow(df))
            dt = DateTime(row.date_time_utc)
            minute_of_day = 60 * Dates.hour(dt) + Dates.minute(dt)
            bucket = DateTime(Date(dt)) + Dates.Minute(coarsest_min * div(minute_of_day, coarsest_min))
            k = (String(row.production_type), bucket)
            sv, n = get(acc, k, (0.0, 0))
            acc[k] = known[i] ? (sv + Float64(row.day_ahead_generation_forecast_mw), n + 1) : (sv, n)
        end
        return [RenewablesGenerationForecast(
                    Dates.format(bucket, "yyyymmdd-HHMM"), coarsest, bidding_zone, ptype,
                    n == 0 ? 0.0 : sv / n)
                for ((ptype, bucket), (sv, n)) in sort(collect(acc); by=kv -> (kv[1][2], kv[1][1]))]
    end

    return [
        RenewablesGenerationForecast(
            # Format datetime to match load data - include minutes for sub-hourly data
            Dates.format(row.date_time_utc, "yyyymmdd-HHMM"),
            row.resolution_code,
            row.area_map_code,
            row.production_type,
            Float64(row.day_ahead_generation_forecast_mw)
        ) for row in eachrow(df)
    ]
end