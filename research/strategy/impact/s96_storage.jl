# 15-minute vs hourly storage orders WITH price impact (st-impact, owner's open question), on 96-step baselines
# (runs/st-impact/b96, built from cv46 bundle 3d4de9a). Constructors: st-blocks' formats.jl (>= 144c2a3, cited).
# env DAYS (comma), OUT (csv). For each day x zone {ES, DE_LU} x asset {BESS 100 MW/200 MWh, PSP 300 MW/2.4 GWh} x size
# {1x, 5x} x format {hourly_oc (legs at opportunity cost), exclusive (loop groups)} x res {60, 15}:
#   F96 = our native 96-step forecast of the zone; res=60 bids use its hourly means (24), res=15 bids use F96.
#   company orders = bids(asset, fmt, F, day; res); re-clear the 96-step baseline with them (new capacity: no carve).
#   sim  = settle at the re-cleared quarter prices with the master's acceptance (settle(...; res=15));
#   pt   = price-taker at realised PT15M quarter prices (evaluate(...; res=15)) — st-blocks' realised score;
#   fc   = price-taker at our own forecast F96 (no impact) — the gap sim − fc is the asset's own price impact.
using Euphemia, Dates, JSON, Printf
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
import Euphemia.MarketOrders: MarketOrder, SimpleOrder, LinkedHourlyOrder
const SF = StrategyFormats
const ROOT = joinpath(homedir(), "armada/em-team/strategy")
StrategyHarness.CACHE[] = joinpath(ROOT, "runs", "st-impact", "b96")
scale(a::SF.Storage, s) = SF.Storage(a.id, a.zone, a.p * s, a.e * s, a.eta)

function clear_ratio(company, r)     # st-blocks run_impact.jl
    info = r.complex_info
    blocks = (info !== nothing && hasproperty(info, :blocks)) ? info.blocks : Dict{String,Any}()
    map(enumerate(company)) do (i, o)
        if o isa SimpleOrder
            o.quantity > 0 ? r.accepted[i] / o.quantity : 0.0
        elseif SF.family_kind(o.family) == :BLK
            haskey(blocks, o.family) ? 1.0 : 0.0
        else
            haskey(blocks, o.family) ? blocks[o.family].ratio : 0.0
        end
    end
end

function realised96(day)
    out = Dict{String,Dict{String,Float64}}()
    pre = string(day)
    for (i, l) in enumerate(eachline(joinpath(ROOT, "data", "sdac", "realised_quarter.csv")))
        i == 1 && continue
        z, t, p = split(l, ',')
        startswith(t, pre) || continue
        dt = DateTime(t, dateformat"yyyy-mm-dd HH:MM:SS")
        get!(out, String(z), Dict{String,Float64}())[Dates.format(dt, "yyyymmdd-HHMM")] = parse(Float64, p)
    end
    return out
end

"""60-minute products on the 96-step clear. A 60-min order mapped to a 96-period book would sit in its first quarter
only, so: a 60-min SimpleOrder becomes a divisible 60-min product = a BLKM family (MAR 0) of its 4 quarters at the same
price and volume (one acceptance ratio for the hour, in the money on the hour's average); a 60-min block member is
expanded to its 4 quarters within the same family. 15-min orders pass unchanged. Returns (orders96, family_of_original)."""
function to96(company)
    out = MarketOrder[]; fam = Vector{Union{Nothing,String}}(nothing, length(company))
    for (i, o) in enumerate(company)
        if o.resolution_code == 15
            push!(out, o); o isa LinkedHourlyOrder && (fam[i] = o.family)
        elseif o isa SimpleOrder
            f = "BLKM:$(o.zone):H$(i):mar=0.0"; fam[i] = f
            for k in 0:3
                push!(out, LinkedHourlyOrder(o.type, o.price, o.quantity, o.zone, o.date_time + Minute(15k), 15, f, NaN))
            end
        else
            fam[i] = o.family
            for k in 0:3
                push!(out, LinkedHourlyOrder(o.type, o.price, o.quantity, o.zone, o.date_time + Minute(15k), 15, o.family, NaN))
            end
        end
    end
    return out, fam
end

days = Date.(split(ENV["DAYS"], ","))
out = ENV["OUT"]
newfile = !isfile(out)
io = open(out, "a")
newfile && println(io, "day,zone,asset,size,format,res,status,solve_s,profit_sim,profit_pt,profit_fc,dp_mean_abs,dp_max_abs,",
    "n_fam,n_fam_acc,sold_mwh_sim,sold_mwh_pt,dev_mwh_pt,carve_short")
for day in days
    base = load_baseline(day)
    per = base.book.periods
    length(per) == 96 || error("$day: baseline has $(length(per)) periods, expected 96")
    inp = JSON.parsefile(joinpath(ROOT, "runs/st-blocks/inputs/$day.json"))
    R96 = realised96(day)
    for z in ("ES", "DE_LU")
        F96 = [base.prices[z][p] for p in per]
        F24 = [sum(F96[4h+1:4h+4]) / 4 for h in 0:23]
        Pr = [get(get(R96, z, Dict{String,Float64}()), p, NaN) for p in per]
        any(isnan, Pr) && (println("SKIP $day $z: realised quarters missing"); continue)
        for arch in ("BESS", "PSP"), s in (1.0, 5.0)
            a = scale(archetype(arch, z; ttf=inp["ttf"], eua=inp["eua"], wv=sum(F24) / 24), s)
            for fmt in ("hourly_oc", "exclusive"), res in (60, 15)
                company = res == 60 ? bids(a, fmt, F24, day; res=60) : bids(a, fmt, F96, day; res=15)
                t0 = time()
                c96, famof = to96(company)
                r = try
                    reclear(base, c96)
                catch e
                    println("FAIL $day $z $arch $s $fmt $res: ", sprint(showerror, e)); flush(stdout); nothing
                end
                r === nothing && continue
                Ps = [r.prices[z][p] for p in per]
                ratio96 = clear_ratio(c96, r)
                blocks = (r.complex_info !== nothing && hasproperty(r.complex_info, :blocks)) ? r.complex_info.blocks : Dict{String,Any}()
                # ratio of each ORIGINAL order: its family's ratio (60-min products / blocks), else the simple order's own
                j = 0
                ratio = map(enumerate(company)) do (i, o)
                    famof[i] === nothing ? ratio96[findfirst(x -> x === o, c96)] :
                        (haskey(blocks, famof[i]) ? (hasproperty(blocks[famof[i]], :ratio) ? blocks[famof[i]].ratio : 1.0) : 0.0)
                end
                st = SF.settle(a, company, ratio, Ps, day; res=15)
                pt = SF.evaluate(a, company, Pr, day; res=15)
                fc = SF.evaluate(a, company, F96, day; res=15)
                fam = Dict{String,Float64}()
                for (i, o) in enumerate(company)
                    famof[i] === nothing || (fam[famof[i]] = max(get(fam, famof[i], 0.0), ratio[i]))
                end
                dp = Ps .- F96
                @printf(io, "%s,%s,%s,%.0f,%s,%d,%s,%.1f,%.1f,%.1f,%.1f,%.3f,%.2f,%d,%d,%.1f,%.1f,%.1f,%.1f\n",
                    day, z, arch, s, fmt, res, r.status, time() - t0, st.profit, pt.profit, fc.profit,
                    sum(abs.(dp)) / 96, maximum(abs.(dp)), length(fam), count(>(0), values(fam)), st.sold_mwh,
                    pt.sold_mwh, pt.dev_mwh, sum(values(r.carve_shortfall); init=0.0))
                flush(io)
            end
        end
    end
    println("S96 $day done $(Dates.format(now(UTC), "HH:MM"))Z"); flush(stdout)
end
close(io)
