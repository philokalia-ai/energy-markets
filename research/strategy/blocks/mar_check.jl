# st-blocks: per-period ratio check for partially accepted MAR blocks in the impact runs.
# A MAR block accepted at ratio r < 1 re-enters the pricing as SimpleOrders capped at r·q (one per period); the MPCC may
# accept less than the cap in a period (EUPHEMIA has one ratio for the whole block). For every impact row with
# 0 < MAR ratio < 1, re-clear the same book and count the periods whose capped order is accepted below its cap.
# usage: jl.sh marchk research/strategy/blocks/mar_check.jl IMPACT.csv KMAP.json OUT.txt
using Euphemia, Dates, JSON, Printf
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
import Euphemia.MarketOrders: MarketOrder, SimpleOrder, LinkedHourlyOrder
# carve reference = SRMC × 1.1, used in rounds 1-2; was the (inert) DEFAULT_MARKUP_FACTOR, deleted on main by #481
const CARVE_REF_SRMC_MULT = 1.1
const SF = StrategyFormats
const ROOT = joinpath(homedir(), "armada/em-team/strategy/runs")
const KEY_RE = r"^(.+)::order_\d+_z(.+)_h(\d+)_q(-?\d+)_p(-?\d+)$"
scale(a::SF.Thermal, s) = SF.Thermal(a.id, a.zone, a.pmax * s, a.pmin * s, a.min_up, a.min_down, a.srmc, a.startup * s, a.noload * s)
scale(a::SF.Hydro, s) = SF.Hydro(a.id, a.zone, a.p * s, a.e * s, a.wv)

function main()
    kj = JSON.parsefile(ARGS[2]; allownan=true)["kmap"]
    rows = [split(l, ',') for (i, l) in enumerate(eachline(ARGS[1])) if i > 1]
    cand = [r for r in rows if r[4] in ("mar", "mar_full") && r[20] != "-" && 0 < parse(Float64, r[20]) < 0.999]
    io = open(ARGS[3], "w")
    println(io, "MAR partial-acceptance rows: $(length(cand)) of $(count(r -> r[4] in ("mar", "mar_full"), rows)) MAR rows in $(ARGS[1])")
    ncell = 0; ndev = 0
    for r in cand
        day = Date(r[1]); z = String(r[2]); arch = String(r[3]); s = parse(Float64, r[5])
        base = load_baseline(day); per = base.book.periods
        inp = JSON.parsefile(joinpath(ROOT, "st-blocks/inputs/$day.json"))
        F = [base.prices[z][p] for p in per]
        a = scale(archetype(arch, z; ttf=inp["ttf"], eua=inp["eua"], wv=sum(F) / 24), s)
        carve = a isa SF.Thermal ?
            [Carve(z, a.pmax, 0.5 * a.srmc, 2.0 * a.srmc * CARVE_REF_SRMC_MULT;
                   ref=a.srmc * CARVE_REF_SRMC_MULT)] :
            [Carve(z, a.p, 0.5 * a.wv, 2.0 * a.wv; ref=a.wv)]
        kk = ["$z|$arch|$(r[4])|1.0|1.0", "$z|$arch|$(r[4])|1.0"]
        ik = findfirst(x -> haskey(kj, x), kk); ik === nothing && error("no calibrated k_su for $z $arch $(r[4])")
        company = bids(a, String(r[4]), F, day; k_su=Float64(kj[kk[ik]]))
        book, _ = StrategyHarness.company_book(base, company; carve=carve)
        res = mz_solve_pass(book; optimizer="highs", silent=true, decompose_periods=true)
        info = Euphemia.MPCC.LAST_COMPLEX_INFO[]
        for (f, b) in info.blocks
            startswith(f, "BLKM:") || continue
            b.ratio < 1 - 1e-6 || continue
            for o in company
                (o isa LinkedHourlyOrder && o.family == f) || continue
                p = StrategyHarness.period_of(book, o.date_time)
                key = (p, z, string(Dates.hour(o.date_time)), string(round(Int, o.quantity * b.ratio)), string(round(Int, o.price)))
                v = [acc for (k, acc) in res.stepwise_acceptance
                     if (m = match(KEY_RE, k)) !== nothing && (m[1], m[2], m[3], m[4], m[5]) == key]
                ncell += 1
                dev = !isempty(v) && minimum(v) < 1 - 1e-6
                dev && (ndev += 1)
                @printf(io, "%s %s %s %.0fx %s ratio %.3f period %s price %.2f bid %.2f acceptance %s%s\n", day, z, arch, s, f,
                    b.ratio, p, res.market_prices[z][p], o.price, isempty(v) ? "n/a" : string(round.(v, digits=4)),
                    dev ? "  <-- below cap" : "")
            end
        end
    end
    println(io, "cells (periods of partially accepted MAR blocks): $ncell; accepted below the cap: $ndev")
    close(io)
    println("cells $ncell, below cap $ndev")
end
main()
