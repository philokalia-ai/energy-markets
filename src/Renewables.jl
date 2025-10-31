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
        date_time,
        resolution_code,
        map_code,
        production_type,
        aggregated_generation_forecast
    FROM 
        entsoe.day_ahead_generation_forecast_for_wind_and_solar
    WHERE 
        area_type_code = 'BZN' -- BZN, CTY, CTA
        AND map_code = '$bidding_zone'
        AND date(date_time) = '$day'
    ORDER BY date_time, map_code
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