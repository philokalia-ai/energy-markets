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
        date_time,
        resolution_code,
        total_load_value
    FROM 
        entsoe.ACTUAL_TOTAL_LOAD
    WHERE 
        map_code = '$bidding_zone'
        AND area_type_code = 'BZN'
        AND date(date_time) = '$day'
    ORDER BY date_time;
    """
    
    df = Euphemia.sql2df(query)
    return [
        Load(
            Dates.format(row.date_time, "yyyymmdd-HH"),  # e.g. "20250624-00"
            row.resolution_code,
            bidding_zone,
            row.total_load_value
        ) for row in eachrow(df)
    ]
end
