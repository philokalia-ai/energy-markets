# Resolution of a set of delivery slots, from the SPACING of the timestamps, never the row count
# (cv46 downstream, D1). A count rule mislabels a 15-min day with 92/100 quarters (DST) or a
# truncated quarter set as hourly; the spacing is the same on every day.

"""
    slot_resolution_minutes(stamps) -> Union{Int,Nothing}

Smallest positive spacing in minutes between the distinct `stamps` (DateTime), or `nothing` when
fewer than two distinct stamps leave it undetermined."""
function slot_resolution_minutes(stamps)
    ts = sort!(unique(DateTime.(collect(stamps))))
    length(ts) < 2 && return nothing
    m = minimum(Dates.value(Minute(b - a)) for (a, b) in zip(ts[1:end-1], ts[2:end]))
    return m > 0 ? m : nothing
end

"""
    energy_prices_resolution_code(stamps) -> String

`simulations.energy_prices.resolution_code` ("15M" / "30M" / "1H") for one zone-day of slots. When
the spacing is undetermined (a single slot) it falls back to the slot count (96 → 15M, 48 → 30M,
else 1H), the previous rule."""
function energy_prices_resolution_code(stamps)
    m = slot_resolution_minutes(stamps)
    if m === nothing
        n = length(collect(stamps))
        return n == 96 ? "15M" : n == 48 ? "30M" : "1H"
    end
    m == 15 && return "15M"
    m == 30 && return "30M"
    m == 60 && return "1H"
    @warn "Unexpected slot spacing of $m minutes; labelling the slots 1H"
    return "1H"
end

"""
    forecast_resolution_code(stamps) -> String

`simulations.forecast_prices.resolution_code` (ISO 8601, as `forecast_scores.q15_forecast_res` and
the ENTSO-E actuals: "PT15M" / "PT30M" / "PT60M") for one zone's slots of a forecast slice.
Undetermined spacing (a single slot) → "PT60M", the column default for every row written before
the column existed."""
function forecast_resolution_code(stamps)
    m = slot_resolution_minutes(stamps)
    m === nothing && return "PT60M"
    m in (15, 30, 60) && return "PT$(m)M"
    @warn "Unexpected forecast slot spacing of $m minutes; labelling the slice PT60M"
    return "PT60M"
end
