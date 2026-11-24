#!/usr/bin/env julia
# measure_forecast_profile.jl — the same-input check of a daily-forecast run profile for measure-duckdb-path.yml
# (ceres option (a) cut-over): runs the profile's real code (bin/daily_forecast.jl main, and for morning/entsoe the
# persistence horizon bin/horizon_forecast.jl) on whatever store the environment selects (the run-local fill, or
# Postgres for the baseline), with FORCE_RERUN so the no-clobber check does not skip the slices production already
# froze — and WRITES NOTHING: the writers (write_forecast!, emit_input_corrections!, write_slice!) are replaced in
# this process by captures. The captured slices go to DIR/prices_<label>.csv in the `compare` format
# (day = market_date|L<lead>|<input_mode>, zone, period = slot start, price), so the existing compare step diffs them.
#
# usage: julia --project=. bin/measure_forecast_profile.jl --part clear|horizon --label pg|duckdb --out DIR
# env:   the profile's environment (bin/forecast_profile_env.sh PROFILE), plus the store's.
using Dates, Printf
opt(k) = (i = findfirst(==(k), ARGS); i === nothing ? error("$k is required") : ARGS[i+1])
const PART, LABEL, OUT = opt("--part"), opt("--label"), opt("--out")
PART in ("clear", "horizon") || error("--part must be clear or horizon")
mkpath(OUT)
ENV["FORCE_RERUN"] = "true"   # recompute every slice; nothing is written
const CAPTURE = Tuple{String,String,DateTime,Float64}[]
const CSV = joinpath(OUT, "prices_$LABEL.csv")

function dump!()
    fresh = !isfile(CSV)
    open(CSV, "a") do io
        fresh && println(io, "day,zone,period,price")
        for (k, z, t, p) in sort(CAPTURE)
            println(io, k, ",", z, ",", Dates.format(t, "yyyy-mm-ddTHH:MM"), ",", repr(p))
        end
    end
    println("measure_forecast_profile: $PART $LABEL captured $(length(CAPTURE)) slot prices → $CSV")
end

if PART == "clear"
    ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"
    include(joinpath(@__DIR__, "daily_forecast.jl"))
    # the writers become captures (same signatures, defined after the script's own)
    function write_forecast!(market_date::Date, lead_days::Int, prediction_made::DateTime,
                             zone_hourly::Dict{String,Dict{DateTime,Float64}}, input_mode::String=INPUT_MODE; kwargs...)
        for (z, h) in zone_hourly, (t, p) in h
            push!(CAPTURE, ("$(market_date)|L$(lead_days)|$(input_mode)", z, t, p))
        end
        return sum(length, values(zone_hourly); init=0)
    end
    emit_input_corrections!(day::Date; dry_run::Bool=false) =
        (println("measure: cv32 input corrections for $day not written (read-only check)"); 0)
    t0 = time(); main()
    @printf("daily forecast (%s, %s): %.1f s\n", get(ENV, "INPUT_MODE", "?"), LABEL, time() - t0)
else
    include(joinpath(@__DIR__, "horizon_forecast.jl"))
    function write_slice!(T::Date, lead::Int, made::DateTime, zone_hourly::Dict{String,Dict{DateTime,Float64}})
        for (z, h) in zone_hourly, (t, p) in h
            push!(CAPTURE, ("$(T)|L$(lead)|$(PERSIST_MODE)", z, t, p))
        end
        return sum(length, values(zone_hourly); init=0)
    end
    main()
end
dump!()
