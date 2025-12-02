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

function get_generation_forecast_for_wind_and_solar(bidding_zone::String, day::Dates.Date)
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
        date(date_time_utc) = '$day'
        AND area_map_code = '$bidding_zone'
        AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY') 
    ORDER BY date_time_utc, area_map_code
    """

    df = Euphemia.sql2df_with_retry(query)
    return [
        RenewablesGenerationForecast(
            # Format datetime to match load data - include minutes for sub-hourly data
            Dates.format(row.date_time, "yyyymmdd-HHMM"),  # e.g. "20250624-0030" for 30-min resolution
            row.resolution_code,
            row.map_code,
            row.production_type,  # convert to Symbol
            row.aggregated_generation_forecast
        ) for row in eachrow(df)
    ]
end