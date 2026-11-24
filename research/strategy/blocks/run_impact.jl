# st-blocks with impact: re-clear our baseline book of D with the company's orders (formats × sizes).
# usage: jl.sh imp research/strategy/blocks/run_impact.jl DAYS.txt OUT.csv KMAP.json [ARCHS] [SIZES]
#   KMAP.json: the scorer's calibrated k_su (score_pt.py --json, from CAL days only).
# Thermal / hydro assets REPLACE the same MW of baseline supply (Carve, ref = SRMC × DEFAULT_MARKUP_FACTOR, the
# book's own bid for such a unit / the water value); storage is added on top (no carve). Others' bids are the
# baseline book (short-run residual demand; pass-2 anchors not re-run).
using Euphemia, Dates, JSON, Printf, Serialization
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
import Euphemia.MarketOrders: MarketOrder, SimpleOrder, LinkedHourlyOrder
const SF = StrategyFormats
const ROOT = joinpath(homedir(), "armada/em-team/strategy/runs")
StrategyHarness.RD_CACHE[] = joinpath(ROOT, "st-blocks/rd")
const ZONES = Dict("CCGT" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"], "COAL" => ["DE_LU", "GR"],
    "HYDRO" => ["NO2", "FR", "ES", "IT-SOUTH"], "PSP" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"],
    "BESS" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"])
const FMTS = Dict(:thermal => ["hourly_mc", "hourly_ac", "block", "linked", "exclusive", "mar", "mar_full", "block_hac"],
                  :storage => ["hourly_oc", "hourly_sched", "block", "exclusive"],
                  :hydro => ["hourly_oc", "block", "mar"])

scale(a::SF.Thermal, s) = SF.Thermal(a.id, a.zone, a.pmax * s, a.pmin * s, a.min_up, a.min_down, a.srmc, a.startup * s, a.noload * s)
scale(a::SF.Storage, s) = SF.Storage(a.id, a.zone, a.p * s, a.e * s, a.eta)
scale(a::SF.Hydro, s) = SF.Hydro(a.id, a.zone, a.p * s, a.e * s, a.wv)
cls(a) = a isa SF.Thermal ? :thermal : a isa SF.Storage ? :storage : :hydro
vec24(d::Dict{String,Float64}, per) = [get(d, p, NaN) for p in per]

"""Accepted ratio per company order from a re-clear: simple orders from the harness (ties resolved by the
solver's acceptance), BLK from the accepted set, BLKM/BLKL/BLKX from the master's ratio."""
function clear_ratio(company, r)
    info = r.complex_info
    blocks = (info !== nothing && hasproperty(info, :blocks)) ? info.blocks : Dict{String,Any}()
    function one(i, o)
        if o isa SimpleOrder
            o.quantity > 0 ? r.accepted[i] / o.quantity : 0.0
        elseif SF.family_kind(o.family) == :BLK
            haskey(blocks, o.family) ? 1.0 : 0.0
        else
            haskey(blocks, o.family) ? blocks[o.family].ratio : 0.0
        end
    end
    return Float64[one(i, o) for (i, o) in enumerate(company)]   # Float64 even when the company has no orders
end

function main()
    days = [Date(strip(l)) for l in eachline(ARGS[1]) if !isempty(strip(l))]
    out = ARGS[2]
    kj = JSON.parsefile(ARGS[3]; allownan=true)["kmap"]
    archs = length(ARGS) >= 4 ? split(ARGS[4], ',') : sort(collect(keys(ZONES)))
    sizes = length(ARGS) >= 5 ? parse.(Float64, split(ARGS[5], ',')) : [5.0, 1.0]
    only = length(ARGS) >= 6 ? Set(split(ARGS[6], ',')) : nothing      # optional format subset
    newfile = !isfile(out)
    io = open(out, "a")
    newfile && println(io, "day,zone,arch,format,size,status,solve_s,pricings,k_su,dp_mean,dp_maxabs,dp_on,neigh,",
        "profit_sim,profit_base,n_fam,n_fam_acc,prb,pab,mar_ratio,unfilled_h,sold_mwh,dev_mwh,carve_short,cap_mw")
    for day in days
        base = load_baseline(day)
        per = base.book.periods
        inp = JSON.parsefile(joinpath(ROOT, "st-blocks/inputs/$day.json"))
        for arch in archs, z in ZONES[arch], s in sizes
            F = vec24(base.prices[z], per)
            a0 = archetype(String(arch), z; ttf=inp["ttf"], eua=inp["eua"], wv=sum(F) / 24)
            a = scale(a0, s)
            carve = if a isa SF.Thermal
                ref = a.srmc * Euphemia.MPCC.DEFAULT_MARKUP_FACTOR
                [Carve(z, a.pmax, 0.5 * a.srmc, 2.0 * ref; ref=ref)]
            elseif a isa SF.Hydro
                [Carve(z, a.p, 0.5 * a.wv, 2.0 * a.wv; ref=a.wv)]
            else
                Carve[]
            end
            for fmt in FMTS[cls(a)]
                only === nothing || fmt in only || continue
                # calibrated k_su: key "zone|arch|format|su[|nl]" (score_pt.py JSON, 5 parts since 508d157, 4 before)
                kk = ["$z|$arch|$fmt|1.0|1.0", "$z|$arch|$fmt|1.0"]
                ik = findfirst(x -> haskey(kj, x), kk)
                (a isa SF.Thermal && fmt != "hourly_mc" && ik === nothing) && error("no calibrated k_su for $z $arch $fmt in KMAP")
                k = ik === nothing ? 1.0 : Float64(kj[kk[ik]])
                company = bids(a, fmt, F, day; k_su=k)
                t0 = time()
                r = try
                    reclear(base, company; carve=carve)
                catch e
                    println("FAIL $day $z $arch $fmt $s: ", sprint(showerror, e)); nothing
                end
                r === nothing && continue
                Ps = vec24(r.prices[z], per)
                ratio = clear_ratio(company, r)
                st = SF.settle(a, company, ratio, Ps, day; res=60)
                pb = SF.evaluate(a, company, F, day; res=60)          # price-taker at OUR forecast (no impact)
                fam_ix = Dict{String,Float64}()
                for (i, o) in enumerate(company)
                    o isa LinkedHourlyOrder && (fam_ix[o.family] = max(get(fam_ix, o.family, 0.0), ratio[i]))
                end
                _, _, Ssim = SF.accept(company, Ps, day; res=60)      # family surplus at the simulated prices
                # paradoxically rejected: rejected, in the money at the simulated prices, and eligible (a linked
                # child only if its parent is accepted; an exclusive member only if no member of its group is)
                acc_names = Set(SF.parse_family(f).zone * ":" * SF.parse_family(f).name for f in keys(fam_ix) if fam_ix[f] > 0)
                gacc = Set(get(SF.parse_family(f).attrs, "group", "") for f in keys(fam_ix) if fam_ix[f] > 0)
                function eligible(f)
                    pf = SF.parse_family(f)
                    par = get(pf.attrs, "parent", ""); grp = get(pf.attrs, "group", "")
                    (isempty(par) || (pf.zone * ":" * par) in acc_names) && (isempty(grp) || !(grp in gacc))
                end
                prb = count(f -> fam_ix[f] == 0 && Ssim[f] > 1e-3 && eligible(f), keys(fam_ix))
                pab = count(f -> fam_ix[f] > 0 && Ssim[f] < -1e-3 && SF.family_kind(f) != :BLKL, keys(fam_ix))
                mr = [fam_ix[f] for f in keys(fam_ix) if SF.family_kind(f) == :BLKM]
                dp = Ps .- F
                on = st.x .!= 0
                nb = String[]
                for zz in sort(collect(keys(r.prices)))
                    zz == z && continue
                    d = sum(abs(r.prices[zz][p] - base.prices[zz][p]) for p in per) / 24
                    d > 1.0 && push!(nb, "$zz:$(round(d, digits=1))")
                end
                unf = a isa SF.Thermal ? count(t -> Ps[t] > a.srmc && st.phys[t] <= 0, 1:24) : 0
                info = r.complex_info
                npr = (info !== nothing && hasproperty(info, :search)) ? info.search.pricings : 1
                @printf(io, "%s,%s,%s,%s,%.0f,%s,%.1f,%d,%.2f,%.3f,%.3f,%.3f,%s,%.1f,%.1f,%d,%d,%d,%d,%s,%d,%.1f,%.1f,%.1f,%.1f\n",
                    day, z, arch, fmt, s, r.status, time() - t0, npr, k, sum(dp) / 24, maximum(abs.(dp)),
                    any(on) ? sum(dp[on]) / count(on) : 0.0, isempty(nb) ? "-" : join(nb, ";"),
                    st.profit, pb.profit, length(fam_ix), count(>(0), values(fam_ix)), prb, pab,
                    isempty(mr) ? "-" : string(round(mr[1], digits=3)), unf, st.sold_mwh, st.dev_mwh,
                    sum(values(r.carve_shortfall); init=0.0),
                    a isa SF.Thermal ? a.pmax : a isa SF.Storage ? a.p : a.p)
                flush(io)
            end
        end
        println("$day done $(Dates.format(now(UTC), "HH:MM"))Z")
    end
    close(io)
end
main()
