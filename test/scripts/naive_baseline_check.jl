# Offline check of the scoreboard naive baselines (#431; NOT part of CI).
#
# Recomputes, on the saved live JSON (`em-team/live/*.json`, the chosen lead-1 slices
# with the physics `sim`, `gbm` and `stats` lines) plus the read-only DuckDB extract
# (actuals via `resolution_aware_actuals`, the scorer's function), the naive D-1, D-7
# and weekday-rule (epf) baselines with the SAME pure functions the exporter uses
# (bin/naive_baselines.jl), per zone and pooled. Optionally adds a Timestral line from
# a backtest parquet (columns zone, t, median), e.g. em-team/results/tsfm/fc_t209_sim_L1.parquet
# — a reconstruction, not a live-issued forecast.
#
# AGGREGATION: unweighted pooled cell means. Per line, the cells are the line's hours
# with a finite actual and every lead-1 naive (D-1 and D-7) present; each line's rMAE
# is sum|line err| / sum|naive err| on ITS cells. Physics cells are the board's mask.
#
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=<extract.duckdb> \
#   EUPHEMIA_RESULTS_DB=<scratch>/results.duckdb \
#     julia --project=. test/scripts/naive_baseline_check.jl <live_dir> [d0] [d1] [tsfm.parquet] [out.csv]
# Defaults: d0 = 2026-09-14, d1 = 2026-11-13 (the live window of issue #431).

using Euphemia, Dates, Statistics, Printf, DataFrames, JSON, DuckDB

include(joinpath(@__DIR__, "..", "..", "bin", "forecast_common.jl"))
include(joinpath(@__DIR__, "eu_eval_metrics.jl"))
include(joinpath(@__DIR__, "..", "..", "bin", "naive_baselines.jl"))

const LIVE = ARGS[1]
const D0 = length(ARGS) >= 2 ? Date(ARGS[2]) : Date(2026, 9, 14)
const D1 = length(ARGS) >= 3 ? Date(ARGS[3]) : Date(2026, 11, 13)
const TSFM = length(ARGS) >= 4 && !isempty(ARGS[4]) ? ARGS[4] : nothing
const OUT = length(ARGS) >= 5 ? ARGS[5] : nothing
const LINES = ("physics", "gbm", "stats", "tsfm")

mutable struct Acc
    n::Int; model::Float64; d1::Float64; d7::Float64; epf::Float64
end
Acc() = Acc(0, 0.0, 0.0, 0.0, 0.0)
function add!(a::Acc, p)
    a.n += p.n; a.model += p.model
    a.d1 += something(p.d1, 0.0); a.d7 += something(p.d7, 0.0); a.epf += something(p.epf, 0.0)
    return a
end
add!(a::Acc, b::Acc) = add!(a, (n=b.n, model=b.model, d1=b.d1, d7=b.d7, epf=b.epf))

function main()
    println("naive baseline check: lead 1, input_mode=weather, $D0..$D1, live=$LIVE")
    act = resolution_aware_actuals(D0 - Day(8), D1)
    actz = Dict{String,Dict{DateTime,Float64}}()
    for r in eachrow(act)
        (r.act === missing) && continue
        get!(Dict{DateTime,Float64}, actz, String(r.z))[DateTime(r.t)] = Float64(r.act)
    end
    locz = Dict(z => local_price_index(collect(keys(d)), collect(values(d))) for (z, d) in actz)
    println("actuals: $(nrow(act)) zone-hours over $(length(actz)) zones")

    tsfm = Dict{Tuple{String,DateTime},Float64}()
    if TSFM !== nothing
        db = DBInterface.connect(DuckDB.DB, ":memory:")
        tf = DataFrame(DBInterface.execute(db,
            "SELECT zone, t, median FROM read_parquet('$(replace(TSFM, '\'' => "''"))')"))
        for r in eachrow(tf)
            (r.median === missing) || (tsfm[(String(r.zone), DateTime(r.t))] = Float64(r.median))
        end
        println("tsfm: $(length(tsfm)) zone-hours from $TSFM")
    end

    acc = Dict{Tuple{String,String},Acc}()
    ndays = Dict{String,Int}()
    nscored = 0   # physics hours with a finite actual, before the naive-lag mask
    for f in sort(filter(endswith(".json"), readdir(LIVE; join=true)))
        zone = splitext(basename(f))[1]
        A = get(actz, zone, Dict{DateTime,Float64}())
        L = get(locz, zone, Dict{DateTime,Float64}())
        for day in JSON.parsefile(f)["days"]
            d = Date(day["date"])
            (D0 <= d <= D1 && day["lead_days"] == 1 && day["input_mode"] == "weather") || continue
            ts = [DateTime(replace(h, "Z" => "")) for h in day["hours"]]
            num(v) = v === nothing ? missing : Float64(v)
            series = Dict("physics" => num.(day["sim"]),
                          "gbm" => num.(get(day, "gbm", fill(nothing, length(ts)))),
                          "stats" => num.(get(day, "stats", fill(nothing, length(ts)))),
                          "tsfm" => [get(tsfm, (zone, t), missing) for t in ts])
            ndays[zone] = get(ndays, zone, 0) + 1
            nscored += count(i -> series["physics"][i] !== missing &&
                                  isfinite(get(A, trunc(ts[i], Hour), NaN)), eachindex(ts))
            for line in LINES
                p = naive_zone_day(ts, series[line], A, L, d, 1)
                add!(get!(Acc, acc, (zone, line)), p)
            end
        end
    end

    zones = sort(unique(first.(collect(keys(acc)))))
    nmask = sum((acc[(z, "physics")].n for z in zones); init=0)
    println("physics hours with an actual: $nscored; with every lead-1 naive lag: $nmask " *
            "($(nscored - nmask) dropped for a missing lag)")
    rows = DataFrame(zone=String[], line=String[], n=Int[], days=Int[], mae=Float64[],
                     naive_d1=Float64[], naive_epf=Float64[], naive_d7=Float64[],
                     rmae_d1=Float64[], rmae_epf=Float64[], rmae_d7=Float64[])
    r3(x) = x === nothing ? NaN : x
    push_row!(zone, line, a, nd) = a.n == 0 ? nothing :
        push!(rows, (zone, line, a.n, nd, a.model / a.n, a.d1 / a.n, a.epf / a.n, a.d7 / a.n,
                     r3(rmae(a.model, a.d1)), r3(rmae(a.model, a.epf)), r3(rmae(a.model, a.d7))))
    for z in zones, line in LINES
        push_row!(z, line, acc[(z, line)], get(ndays, z, 0))
    end
    for (label, keep) in (("ALL (pooled)", z -> true), ("ex-IT (pooled)", z -> !startswith(z, "IT")))
        for line in LINES
            a = Acc()
            for z in zones
                keep(z) && add!(a, acc[(z, line)])
            end
            push_row!(label, line, a, 0)
        end
    end

    @printf("\n%-14s %-7s %6s %7s %7s %7s %7s %6s %6s %6s\n", "zone", "line", "n", "MAE",
            "D-1", "epf", "D-7", "r_D1", "r_epf", "r_D7")
    for r in eachrow(rows)
        @printf("%-14s %-7s %6d %7.1f %7.1f %7.1f %7.1f %6.2f %6.2f %6.2f\n", r.zone, r.line, r.n,
                r.mae, r.naive_d1, r.naive_epf, r.naive_d7, r.rmae_d1, r.rmae_epf, r.rmae_d7)
    end
    if OUT !== nothing
        open(OUT, "w") do io
            println(io, join(names(rows), ","))
            for r in eachrow(rows)
                println(io, join((x isa AbstractFloat ? @sprintf("%.4f", x) : string(x) for x in r), ","))
            end
        end
        println("\nwrote $OUT")
    end
end

main()
