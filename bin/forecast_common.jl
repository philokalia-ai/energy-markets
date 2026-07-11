# Shared pure logic for the daily-forecast product
# (bin/daily_forecast.jl, bin/score_forecasts.jl, bin/export_forecast_json.jl).
#
# Everything here is deliberately DB-free so test/test_forecast_tracking.jl can
# unit-test the eligibility gate, the lead-day arithmetic, the realized-day
# write guard and the scoring math on synthetic data without a live solve.

using Dates, Statistics

# The 39-zone EU footprint (same list as bin/eu_calibration_run.jl / CLAUDE.md).
const FORECAST_FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

"""
    forecast_lead_days(market_date::Date, today_utc::Date) -> Int

Lead time in whole days: 0 = same-day nowcast, 1 = day-ahead, etc.
"""
forecast_lead_days(market_date::Date, today_utc::Date) =
    Dates.value(market_date - today_utc)

"""
    assert_unrealized(market_date::Date, latest_actual_date::Date)

HARD GUARD for honest forecasting: refuse to write a "prediction" for a market
day that has already realized (market_date ≤ latest actual_total_load date) —
a prediction written now for a realized day would be fake. Throws on violation.
"""
function assert_unrealized(market_date::Date, latest_actual_date::Date)
    if market_date <= latest_actual_date
        error("REFUSING to write forecast for $market_date: the day has already " *
              "realized (latest actual_total_load date = $latest_actual_date). " *
              "A prediction written now would be fake.")
    end
    return true
end

"""
    eligibility_verdict(zones, load_hours_by_zone, res_zones_required,
                        res_zones_present, atc_rows;
                        min_load_hours=20) -> (eligible::Bool, reason::String)

Pure eligibility gate for one candidate market day. A day is eligible iff
1. EVERY footprint zone has ≥ `min_load_hours` hourly-equivalent rows of
   day-ahead load forecast (`load_hours_by_zone`: zone → distinct hours);
2. every zone that had a wind/solar forecast on the most recent fully-realized
   day (`res_zones_required`) also has one for this day (`res_zones_present`);
3. offered implicit ATC rows exist for the day (`atc_rows` > 0).

Never degrades: any missing zone makes the whole day ineligible.
"""
function eligibility_verdict(zones::Vector{String},
                             load_hours_by_zone::AbstractDict{String,<:Integer},
                             res_zones_required::AbstractSet{String},
                             res_zones_present::AbstractSet{String},
                             atc_rows::Integer;
                             min_load_hours::Integer=20)
    missing_load = [z for z in zones if get(load_hours_by_zone, z, 0) < min_load_hours]
    if !isempty(missing_load)
        return (false, "load forecast missing/short (<$(min_load_hours)h) for " *
                       "$(length(missing_load)) zone(s): $(join(missing_load, ","))")
    end
    missing_res = sort(collect(setdiff(res_zones_required, res_zones_present)))
    if !isempty(missing_res)
        return (false, "wind/solar forecast missing for zone(s) that had one on " *
                       "the last realized day: $(join(missing_res, ","))")
    end
    if atc_rows <= 0
        return (false, "no offered ATC (implicit) rows for the day")
    end
    return (true, "all $(length(zones)) zones have load forecast, " *
                  "RES coverage matches the last realized day " *
                  "($(length(res_zones_required)) zones), ATC present ($atc_rows rows)")
end

"""
    hourly_prices(prices::Dict{String,Float64}) -> Dict{DateTime,Float64}

Collapse a market-clearing price dict keyed by "yyyymmdd-HHMM" timeslots to
hourly prices (mean of sub-hourly slots within each hour; identity for hourly
books, which is what the merit-order clear produces).
"""
function hourly_prices(prices::Dict{String,Float64})
    acc = Dict{DateTime,Vector{Float64}}()
    for (ts, p) in prices
        dt = DateTime(ts, dateformat"yyyymmdd-HHMM")
        h = trunc(dt, Hour)
        push!(get!(acc, h, Float64[]), p)
    end
    return Dict(h => mean(v) for (h, v) in acc)
end

"""
    score_series(sim::Vector{Float64}, act::Vector{Float64})
        -> (n, mae, bias, corr)

Scoring math for one zone-day: MAE, bias (sim − actual, so + = model too
expensive) and Pearson correlation over paired hours. `corr` is `nothing` when
either series is degenerate (zero variance) or fewer than 3 pairs — never NaN.
Requires equal lengths; returns `nothing` for all metrics when n == 0.
"""
function score_series(sim::Vector{Float64}, act::Vector{Float64})
    length(sim) == length(act) ||
        throw(ArgumentError("sim and act must be paired (got $(length(sim)) vs $(length(act)))"))
    n = length(sim)
    n == 0 && return (n=0, mae=nothing, bias=nothing, corr=nothing)
    mae = mean(abs.(sim .- act))
    bias = mean(sim .- act)
    c = (n >= 3 && std(sim) > 0 && std(act) > 0) ? cor(sim, act) : nothing
    c isa Float64 && !isfinite(c) && (c = nothing)
    return (n=n, mae=mae, bias=bias, corr=c)
end

# ---------------------------------------------------------------------------
# Minimal JSON serializer (avoids adding a package dependency). Handles the
# restricted value universe of the export contract: Dict / NamedTuple /
# Vector / String / Real / Bool / Nothing / Missing / Date / DateTime.
# Non-finite floats (NaN/Inf) are emitted as null — JSON has no NaN.
# ---------------------------------------------------------------------------
function json_write(io::IO, v)
    if v === nothing || v === missing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa AbstractFloat
        isfinite(v) ? print(io, v) : print(io, "null")
    elseif v isa Real
        print(io, v)
    elseif v isa AbstractString || v isa Symbol
        json_write_string(io, string(v))
    elseif v isa Date
        json_write_string(io, Dates.format(v, "yyyy-mm-dd"))
    elseif v isa DateTime
        json_write_string(io, Dates.format(v, "yyyy-mm-ddTHH:MM:SS") * "Z")
    elseif v isa AbstractDict
        print(io, "{")
        first = true
        for (k, val) in v
            first || print(io, ",")
            first = false
            json_write_string(io, string(k)); print(io, ":")
            json_write(io, val)
        end
        print(io, "}")
    elseif v isa NamedTuple
        print(io, "{")
        first = true
        for (k, val) in pairs(v)
            first || print(io, ",")
            first = false
            json_write_string(io, string(k)); print(io, ":")
            json_write(io, val)
        end
        print(io, "}")
    elseif v isa AbstractVector || v isa Tuple
        print(io, "[")
        for (i, val) in enumerate(v)
            i > 1 && print(io, ",")
            json_write(io, val)
        end
        print(io, "]")
    else
        throw(ArgumentError("json_write: unsupported type $(typeof(v))"))
    end
end

function json_write_string(io::IO, s::String)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", string(UInt16(c), base=16, pad=4))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

json_string(v) = sprint(json_write, v)
