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

function get_generation_forecast_for_wind_and_solar(bidding_zone::String, day::Dates.Date;
    coalesce_missing::Bool=false)
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
    # `coalesce_missing` (opt-in) turns NULL day-ahead forecasts into 0 MW so a
    # zone with partial RES coverage (e.g. CH, RS: no wind/solar forecast for
    # some types) still yields a usable book instead of throwing on the
    # Missing→Float64 conversion. Default `false` keeps the strict behaviour, so
    # the single-zone and 5-zone SEE paths are unchanged (they error out on
    # missing data exactly as before).
    return [
        RenewablesGenerationForecast(
            # Format datetime to match load data - include minutes for sub-hourly data
            Dates.format(row.date_time_utc, "yyyymmdd-HHMM"),  # Fixed: use date_time_utc
            row.resolution_code,
            row.area_map_code,  # Fixed: use area_map_code
            row.production_type,
            coalesce_missing && ismissing(row.day_ahead_generation_forecast_mw) ?
                0.0 : row.day_ahead_generation_forecast_mw  # Fixed: use day_ahead_generation_forecast_mw
        ) for row in eachrow(df)
    ]
end