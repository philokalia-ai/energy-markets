# st-blocks ROUND 2 price-taker grid on the 96-step baselines (main 5fa39e1+: cv46 bundle, 15-min clear, P1),
# through the CompanyStrategy plug-ins (strategy_of + offers). Same grid as run_pt.jl otherwise.
# usage: jl.sh pt96 research/strategy/blocks/run_pt96.jl DAYS.txt OUT.csv
#   forecast F96 = our 96-step baseline prices (runs/baseline96/<day>.prices.csv); F60 = its hourly means.
#   cases: 60-min products built from F60 on hourly realised; 60-min products on realised quarters; 15-min products
#   built from the NATIVE F96 on realised quarters (round 1 had to repeat the hourly forecast).
# Inputs: runs/st-blocks/inputs/<day>.json (ex-ante); runs/st-blocks/realised/<day>.json (SCORING ONLY).
using Euphemia, Dates, JSON, Printf
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
import Euphemia.MarketOrders: MarketOrder
const SF = StrategyFormats
const ROOT = joinpath(homedir(), "armada/em-team/strategy/runs")
const ZONES = Dict("CCGT" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"], "COAL" => ["DE_LU", "GR"],
    "HYDRO" => ["NO2", "FR", "ES", "IT-SOUTH"], "BESS" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"],
    "PSP" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"], "PVBAT" => ["ES", "GR", "IT-SOUTH", "DE_LU"],
    "FLEX" => ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"])
const K_SU = [0.5, 0.75, 1.0]                # start-up share in a block price (calibrated on cal days); ≤ 1 = never above cost
const SU_SCALE = [1.0, 0.5, 1.5]              # true start-up cost sensitivity (1.0 = repo formula; 1.5 = stress)
const NL_SCALE = [1.0, 0.0]                   # true no-load cost sensitivity (1.0 = FuelTypeParameters)
const PEN = [0.0, 10.0]                       # €/MWh on re-traded deviations (0 = intraday at the DA price)

function forecast96(day)
    F = Dict{String,Vector{Float64}}()
    for (i, l) in enumerate(eachline(joinpath(ROOT, "baseline96/$day.prices.csv")))
        i == 1 && continue
        z, p, _, v = split(l, ',')
        q = parse(Int, p[10:11]) * 4 + parse(Int, p[12:13]) ÷ 15 + 1
        get!(F, String(z), fill(NaN, 96))[q] = parse(Float64, v)
    end
    return F
end
hourly(F96) = [sum(@view F96[4h-3:4h]) / 4 for h in 1:24]

cls(a) = a isa SF.Thermal ? :thermal : a isa SF.Storage ? :storage : a isa SF.Hydro ? :hydro :
         a isa SF.PVBat ? :pvbat : :flex

function main()
    days = [Date(strip(l)) for l in eachline(ARGS[1]) if !isempty(strip(l))]
    out = ARGS[2]; sub = "st-blocks"
    io = open(out, "w")
    println(io, "day,zone,arch,format,k_su,su_scale,nl_scale,pen,res_bid,res_eval,profit,rev,cost,dev_mwh,sold_mwh,starts,n_fam,n_fam_acc,unfilled_h,cap_mw,srmc,startup,wv")
    for day in days
        inp = JSON.parsefile(joinpath(ROOT, sub, "inputs/$day.json"))
        rl = JSON.parsefile(joinpath(ROOT, sub, "realised/$day.json"))
        Fz96 = forecast96(day)
        t0 = time(); nrow = 0
        for (arch, zones) in sort(collect(ZONES)), z in zones
            haskey(Fz96, z) && haskey(rl["hourly"], z) || (println("skip $day $z: no forecast/realised"); continue)
            F96 = Fz96[z]; any(isnan, F96) && continue
            F = hourly(F96)
            P = Float64.(rl["hourly"][z]); Q = haskey(rl["q15"], z) ? Float64.(rl["q15"][z]) : nothing
            wv = sum(F) / length(F)    # ex-ante water value: the zone's forecast daily mean (no reservoir families in the book)
            for sus in (arch in ("CCGT", "COAL") ? SU_SCALE : [1.0]), nls in (arch in ("CCGT", "COAL") ? NL_SCALE : [1.0])
                a = archetype(arch, z; ttf=inp["ttf"], eua=inp["eua"], solar_fc=get(inp["solar_fc"], z, nothing),
                              load_fc=get(inp["load_fc"], z, nothing), wv=wv,
                              solar_peak=get(get(inp, "solar_peak365", Dict()), z, nothing))
                if a isa SF.Thermal && (sus != 1.0 || nls != 1.0)
                    a = SF.Thermal(a.id, a.zone, a.pmax, a.pmin, a.min_up, a.min_down, a.srmc, a.startup * sus, a.noload * nls)
                end
                cap = a isa SF.Thermal ? a.pmax : a isa SF.Storage ? a.p : a isa SF.Hydro ? a.p : a isa SF.PVBat ? 200.0 : 300.0
                for fmt in FORMATS[cls(a)]
                    ks = (a isa SF.Thermal && fmt != "hourly_mc") ? K_SU : [1.0]
                    for k in ks
                        # hourly bids on hourly prices, plus (post-MTU quarters) 60-min and 15-min products on quarters
                        cases = [(60, 60, P)]
                        if Q !== nothing && sus == 1.0 && nls == 1.0
                            push!(cases, (60, 15, Q)); push!(cases, (15, 15, Q))
                        end
                        for (rb, re, PP) in cases
                            FF = rb == 15 ? F96 : F
                            o = MarketOrder[x for (x, _) in offers(strategy_of(a, fmt; k_su=k), CompanyCtx(a, FF, day, rb))]
                            for pen in PEN
                                r = evaluate(a, o, PP, day; res=re, pen=pen)
                                dt = re / 60
                                unf = a isa SF.Thermal ? count(t -> PP[t] > a.srmc && r.phys[t] <= 0, eachindex(PP)) * dt : 0.0
                                @printf(io, "%s,%s,%s,%s,%.2f,%.2f,%.2f,%.1f,%d,%d,%.2f,%.2f,%.2f,%.3f,%.3f,%d,%d,%d,%.2f,%.1f,%.3f,%.1f,%.3f\n",
                                    day, z, arch, fmt, k, sus, nls, pen, rb, re, r.profit, r.rev, r.cost, r.dev_mwh, r.sold_mwh,
                                    r.starts, length(r.fam), count(>(0), values(r.fam)), unf, cap,
                                    a isa SF.Thermal ? a.srmc : NaN, a isa SF.Thermal ? a.startup : NaN, wv)
                                nrow += 1
                            end
                        end
                    end
                end
            end
        end
        flush(io)
        println("$day rows $nrow $(round(time() - t0, digits=1)) s")
    end
    close(io)
end
main()
