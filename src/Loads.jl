struct Load
    timeslot::String
    resolution_code::String
    bidding_zone::String
    value::Float64
end

function get_loads()
    return [Load("20250624-00", "60", "GR", 42.0)]
end

function get_loads(bidding_zone::String, day::Dates.Date)
    # Use day-ahead load forecast for UC planning (matches renewable forecast horizon)
    # UTC day window as explicit range bounds: sargable (uses
    # idx_load_fcst_zone_time instead of reading every row of the zone) and
    # independent of the session timezone, unlike date(date_time_utc) = day
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
    return [
        Load(
            Dates.format(row.date_time_utc, "yyyymmdd-HHMM"),  # Fixed: use date_time_utc
            row.resolution_code,
            bidding_zone,
            row.total_load_mw  # Fixed: use total_load_mw
        ) for row in eachrow(df)
    ]
end
