# iter9 A/B scorer — per-zone, per-window metrics (resolution-aware actuals,
# dedup by sequence) for sim prices from a TSV (ab_run.jl output) or from a
# saved Postgres clearing_mode/cv record. Prints tables and writes a TSV.
#
# Usage:
#   julia --project=. score_ab.jl <simA> <simB> [out.tsv]
# where simX is either a path to an ab_run TSV or "pg:<clearing_mode>:<cv>".
using Euphemia, Dates, Statistics, Printf, DataFrames

include(joinpath(@__DIR__, "..", "..", "..", "test", "scripts", "eu_eval_metrics.jl"))

const WINDOWS = [
    ("apr", Date(2026, 4, 1), Date(2026, 4, 5)),
    ("jul", Date(2026, 7, 6), Date(2026, 7, 21)),
    ("mar", Date(2026, 3, 1), Date(2026, 3, 8)),
]

"load sim prices as Dict{(zone, DateTime) => price}"
function load_sim(src::AbstractString)
    sim = Dict{Tuple{String,DateTime},Float64}()
    if startswith(src, "pg:")
        _, cm, cv = split(src, ":")
        for (_, sd, ed) in WINDOWS
            df = sim_prices(String(cm), parse(Int, cv), sd, ed)
            for r in eachrow(df)
                sim[(String(r.z), DateTime(r.t))] = Float64(r.sim)
            end
        end
    else
        for line in eachline(src)
            startswith(line, "zone\t") && continue
            z, ts, p = split(line, '\t')
            sim[(String(z), DateTime(ts, dateformat"yyyymmdd-HHMM"))] = parse(Float64, p)
        end
    end
    return sim
end

function window_metrics(sim, actmap, sd::Date, ed::Date)
    lo = DateTime(sd); hi = DateTime(ed + Day(1))
    byz = Dict{String,Tuple{Vector{Float64},Vector{Float64}}}()
    for ((z, t), p) in sim
        (lo <= t < hi) || continue
        a = get(actmap, (z, t), NaN); isnan(a) && continue
        sv, av = get!(byz, z, (Float64[], Float64[]))
        push!(sv, p); push!(av, a)
    end
    out = NamedTuple[]
    for z in sort(collect(keys(byz)))
        sv, av = byz[z]
        length(sv) < 3 && continue
        c = (std(sv) > 0 && std(av) > 0) ? cor(sv, av) : NaN
        push!(out, (z=z, n=length(sv), corr=c, mae=mean(abs.(sv .- av)),
                    bias=mean(sv .- av), simμ=mean(sv), actμ=mean(av)))
    end
    return out
end

srcA, srcB = ARGS[1], ARGS[2]
outp = get(ARGS, 3, joinpath(@__DIR__, "ab_scores.tsv"))
simA, simB = load_sim(srcA), load_sim(srcB)

# actuals across the full span (cheap: three bounded queries)
actmap = Dict{Tuple{String,DateTime},Float64}()
for (_, sd, ed) in WINDOWS
    for r in eachrow(resolution_aware_actuals(sd, ed))
        actmap[(String(r.z), DateTime(r.t))] = Float64(r.act)
    end
end

open(outp, "w") do io
    println(io, "window\tarm\tzone\tn\tcorr\tmae\tbias\tsim_mean\tact_mean")
    for (wname, sd, ed) in WINDOWS
        mA = window_metrics(simA, actmap, sd, ed)
        mB = window_metrics(simB, actmap, sd, ed)
        dA = Dict(r.z => r for r in mA)
        println("\n### window $wname ($sd..$ed)  A=$srcA  B=$srcB")
        @printf("%-12s | %6s %7s %8s | %6s %7s %8s | %7s %7s\n",
                "zone", "corrA", "maeA", "biasA", "corrB", "maeB", "biasB", "Δcorr", "ΔMAE")
        for r in mB
            a = get(dA, r.z, nothing)
            if a === nothing
                @printf("%-12s | %6s %7s %8s | %6.2f %7.1f %+8.1f | %7s %7s\n",
                        r.z, "-", "-", "-", r.corr, r.mae, r.bias, "-", "-")
            else
                @printf("%-12s | %6.2f %7.1f %+8.1f | %6.2f %7.1f %+8.1f | %+7.2f %+7.1f\n",
                        r.z, a.corr, a.mae, a.bias, r.corr, r.mae, r.bias,
                        r.corr - a.corr, r.mae - a.mae)
            end
        end
        for (arm, m) in (("A", mA), ("B", mB))
            for r in m
                @printf(io, "%s\t%s\t%s\t%d\t%.4f\t%.3f\t%.3f\t%.3f\t%.3f\n",
                        wname, arm, r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
            end
        end
    end
end
println("\nscores written: $outp")
