# Round 2 exp 4: MAR results redone with the single acceptance ratio, WITH IMPACT on the 96-step baselines, through
# CompanyScore.score (the plug-in interface). Thermal units at the given sizes, formats hourly_mc (benchmark), block,
# mar_full; carve-out as round 1 (same MW of baseline supply nearest SRMC × 1.1).
# usage: jl.sh mar96 research/strategy/blocks/run_mar96.jl DAYS.txt OUT.csv KMAP.json [SIZES]
using Euphemia, Dates, JSON, Printf
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
include(joinpath(pkgdir(Euphemia), "src", "strategy", "CompanyScore.jl")); using .CompanyScore
import Euphemia.MarketOrders: MarketOrder, LinkedHourlyOrder
# carve reference = SRMC × 1.1, used in rounds 1-2; was the (inert) DEFAULT_MARKUP_FACTOR, deleted on main by #481
const CARVE_REF_SRMC_MULT = 1.1
const SF = StrategyFormats
const ROOT = joinpath(homedir(), "armada/em-team/strategy/runs")
StrategyHarness.CACHE[] = joinpath(ROOT, "baseline96")
const ZONES = Dict("CCGT" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"], "COAL" => ["DE_LU", "GR"])
scale(a::SF.Thermal, s) = SF.Thermal(a.id, a.zone, a.pmax * s, a.pmin * s, a.min_up, a.min_down, a.srmc, a.startup * s, a.noload * s)

function main()
    days = [Date(strip(l)) for l in eachline(ARGS[1]) if !isempty(strip(l))]
    out = ARGS[2]; kj = JSON.parsefile(ARGS[3]; allownan=true)["kmap"]
    sizes = length(ARGS) >= 4 ? parse.(Float64, split(ARGS[4], ',')) : [5.0]
    newfile = !isfile(out); io = open(out, "a")
    newfile && println(io, "day,zone,arch,format,size,status,solve_s,pricings,k_su,dp_mean,dp_maxabs,profit_sim,",
        "n_fam,n_fam_acc,prb,mar_ratio,mar_moved,mar_partial,mar_cap_hit,carve_short,cap_mw,",
        "srch_cand_partial,srch_moved,srch_cap_hit")
    for day in days
        base = load_baseline(day)
        inp = JSON.parsefile(joinpath(ROOT, "st-blocks/inputs/$day.json"))
        for arch in ("CCGT", "COAL"), z in ZONES[arch], s in sizes
            a = scale(archetype(arch, z; ttf=inp["ttf"], eua=inp["eua"]), s)
            ref = a.srmc * CARVE_REF_SRMC_MULT
            carve = [Carve(z, a.pmax, 0.5 * a.srmc, 2.0 * ref; ref=ref)]
            for fmt in ("hourly_mc", "block", "mar_full")
                key = "$z|$arch|$fmt|1.0|1.0"
                (fmt != "hourly_mc" && !haskey(kj, key)) && error("no calibrated k_su for $key")
                k = fmt == "hourly_mc" ? 1.0 : Float64(kj[key])
                st = strategy_of(a, fmt; k_su=k)
                t0 = time()
                r = try
                    score(st, a, base; carve=carve, impact=true)
                catch e
                    println("FAIL $day $z $arch $fmt $s: ", sprint(showerror, e)); nothing
                end
                r === nothing && continue
                im = r.impact; info = im.reclear.complex_info
                srch = (info !== nothing && hasproperty(info, :search)) ? info.search : nothing
                fam = Dict{String,Float64}()
                for (i, o) in enumerate(r.orders)
                    o isa LinkedHourlyOrder && (fam[o.family] = max(get(fam, o.family, 0.0), im.ratio[i]))
                end
                _, _, Ssim = SF.accept(r.orders, im.P, day; res=r.res)
                prb = count(f -> fam[f] == 0 && Ssim[f] > 1e-3, keys(fam))
                mr = [fam[f] for f in keys(fam) if SF.family_kind(f) == :BLKM]
                g(x, d) = srch === nothing ? d : (hasproperty(srch, x) ? getproperty(srch, x) : d)
                @printf(io, "%s,%s,%s,%s,%.0f,%s,%.1f,%d,%.2f,%.3f,%.3f,%.1f,%d,%d,%d,%s,%d,%d,%s,%.1f,%.1f,%d,%d,%d\n",
                    day, z, arch, fmt, s, im.status, time() - t0, g(:pricings, 1), k, sum(im.dp) / length(im.dp),
                    maximum(abs.(im.dp)), im.result.profit, length(fam), count(>(0), values(fam)), prb,
                    isempty(mr) ? "-" : string(round(mr[1], digits=3)), g(:mar_moved, 0), g(:mar_partial, 0),
                    string(g(:mar_cap_hit, false)), im.carve_shortfall, a.pmax, g(:mar_search_cand_partial, 0),
                    g(:mar_search_moved, 0), g(:mar_search_cap_hit, 0))
                flush(io)
            end
        end
        println("$day done $(Dates.format(now(UTC), "HH:MM"))Z"); flush(stdout)
    end
    close(io)
end
main()
