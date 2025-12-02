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
    query = """
    SELECT
        date_time_utc,
        resolution_code,
        total_load_mw
    FROM 
        entsoe.actual_total_load
    WHERE 
        area_map_code = '$bidding_zone'
        AND area_type_code = 'BZN' -- BZN, CTY, CTA, TODO: MIGHT NEED OTHERS, BZN/CTA, or BZN/CTA/CTY for all three 
        AND date(date_time_utc) = '$day'
    ORDER BY date_time_utc;
    """

    df = Euphemia.sql2df_with_retry(query)
    return [
        Load(
            Dates.format(row.date_time, "yyyymmdd-HHMM"),  # e.g. "20250624-0030" for 30-min resolution
            row.resolution_code,
            bidding_zone,
            row.total_load_value
        ) for row in eachrow(df)
    ]
end
