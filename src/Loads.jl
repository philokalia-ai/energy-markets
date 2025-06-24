struct Load
    bidding_zone::String
    timeslot::String
end

function get_loads()
    return Load("GR", "20250624-00")
end
