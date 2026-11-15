# The true pre-gate lead-1 context (06:30 UTC on D-1), built directly the way
# bin/daily_forecast.jl builds its contexts. NB `Euphemia.issuance_context(d, 1; ...)`
# delegates lead 1 to the 10:00 UTC gate context and ignores `issue_time`.
pregate_0630(d::Dates.Date) = Euphemia.ForecastContext(d,
    Dates.DateTime(d - Dates.Day(1)) + Dates.Hour(6) + Dates.Minute(30), 1, :fixed_10utc, "blocks-0630")
