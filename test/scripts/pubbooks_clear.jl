# Published-books clearing validation — HARNESS.
# See docs/experiments/pubbooks-clearing/protocol.md (frozen).
#
# Feeds the REAL published bids (converted to SimpleOrder by pubbooks_prep.py)
# into the Euphemia clearing engine and measures whether we reproduce the
# OFFICIAL clearing price. Two layers:
#   A (solver mechanics): engine price vs an INDEPENDENT merit-order crossing of
#     the identical order set (self-contained; no coupling).
#   B (book -> official): engine on the real book, DOMESTIC and DOMESTIC+injected
#     net position, vs the official price.
#
# Usage (one FRESH process per market day, per protocol §3):
#   julia --project=. test/scripts/pubbooks_clear.jl <GME|OMIE> <YYYY-MM-DD>
# Reads $PUBBOOKS_DIR/intermediate/{gme,omie}_{orders,cells}.tsv; appends metric
# rows to $PUBBOOKS_DIR/intermediate/metrics_<ex>.tsv. No raw/derived data is
# committed; this script only references paths via $PUBBOOKS_DIR.

using Euphemia
using Dates
using DelimitedFiles

const PUB = ENV["PUBBOOKS_DIR"]
const INT = joinpath(PUB, "intermediate")
const FLOOR = -500.0
const CEIL = 4000.0
const DT = DateTime(2000, 1, 1, 0, 0, 0)   # canonical single-period timestamp
const PERIODS = ["1"]

# ---- independent merit-order uniform-price crossing (NOT the MPCC solver) ----
# Returns (p_ref, p_sup_marg, p_dem_marg, qstar). p_ref = smallest price where
# cumulative supply(<=p) >= cumulative demand(>=p). The clearing price lies in
# the bracket [p_sup_marg, p_dem_marg] at the crossing quantity qstar.
function crossing(sup_p, sup_q, dem_p, dem_q)
    sp = sortperm(sup_p); dp = sortperm(dem_p; rev = true)
    scum = cumsum(sup_q[sp]); spr = sup_p[sp]
    dcum = cumsum(dem_q[dp]); dpr = dem_p[dp]
    prices = sort(unique(vcat(spr, dpr)))
    supply_at(p) = (i = searchsortedlast(spr, p); i > 0 ? scum[i] : 0.0)
    # demand at price >= p: dpr is descending; count where dpr >= p
    function demand_at(p)
        j = searchsortedlast(-dpr, -p)   # last index with dpr >= p
        j > 0 ? dcum[j] : 0.0
    end
    p_ref = NaN; qstar = 0.0
    for p in prices
        s = supply_at(p); d = demand_at(p)
        if s >= d - 1e-9
            p_ref = p; qstar = d
            break
        end
    end
    # marginal step prices at qstar
    si = searchsortedfirst(scum, qstar - 1e-6)
    di = searchsortedfirst(dcum, qstar - 1e-6)
    p_sup_marg = si <= length(spr) ? spr[si] : spr[end]
    p_dem_marg = di <= length(dpr) ? dpr[di] : dpr[end]
    return (p_ref, p_sup_marg, p_dem_marg, qstar)
end

# ---- run engine on a set of (side,price,mw) rows ----
function engine_price(zone::String, sides, prices, mws)
    orders = Euphemia.MarketOrders.MarketOrder[]
    for k in eachindex(sides)
        push!(orders, Euphemia.SimpleOrder(sides[k], prices[k], mws[k], Symbol(zone), DT, 60))
    end
    book = Euphemia.MPCCOrderBook(orders, [zone], PERIODS, (FLOOR, CEIL), nothing)
    r = Euphemia.solve_mpcc_market_clearing(book; preferred_solver = "highs",
        silent = true, verbose = false)
    if r.status in (:optimal, :time_limit) && haskey(r.market_prices, zone) &&
       haskey(r.market_prices[zone], "1")
        return (r.market_prices[zone]["1"], string(r.status))
    end
    return (NaN, string(r.status))
end

# Robust numeric coercion — readdlm types a column as String whenever ANY cell in
# it is empty/non-numeric (missing ES price hour in the 15-min OMIE months), so a
# plain Float64(x) throws on the SubString it then returns for numeric cells too.
fnum(x)::Float64 = x isa Real ? Float64(x) :
                   (s = strip(string(x)); isempty(s) ? NaN : parse(Float64, s))
inum(x)::Int = x isa Integer ? Int(x) : round(Int, fnum(x))

function main()
    ex = uppercase(ARGS[1]); day = ARGS[2]
    exl = lowercase(ex)
    ocells, hc = readdlm(joinpath(INT, "$(exl)_cells.tsv"), '\t'; header = true)
    oorders, ho = readdlm(joinpath(INT, "$(exl)_orders.tsv"), '\t'; header = true)
    hc = vec(hc); ho = vec(ho)
    ci = Dict(String(hc[i]) => i for i in eachindex(hc))
    oi = Dict(String(ho[i]) => i for i in eachindex(ho))
    # filter to this day
    cmask = String.(ocells[:, ci["day"]]) .== day
    omask = String.(oorders[:, oi["day"]]) .== day
    cells = ocells[cmask, :]; ords = oorders[omask, :]
    # index orders by (zone,hour)
    zcol = String.(ords[:, oi["zone"]]); hcol = inum.(ords[:, oi["hour"]])
    scol = String.(ords[:, oi["side"]]); pcol = fnum.(ords[:, oi["price"]])
    qcol = fnum.(ords[:, oi["mw"]])
    keyidx = Dict{Tuple{String,Int},Vector{Int}}()
    for r in 1:size(ords, 1)
        push!(get!(keyidx, (zcol[r], hcol[r]), Int[]), r)
    end
    out = IOBuffer()
    for r in 1:size(cells, 1)
        zone = String(cells[r, ci["zone"]]); hour = inum(cells[r, ci["hour"]])
        p_off = fnum(cells[r, ci["p_off"]])
        ni = cells[r, ci["net_import_mw"]]
        net_import = (ni == "" || (ni isa Real && isnan(ni))) ? 0.0 : fnum(ni)
        espt = inum(cells[r, ci["espt_eq"]])
        idx = get(keyidx, (zone, hour), Int[])
        isempty(idx) && continue
        sides = [scol[i] == "supply" ? :supply : :demand for i in idx]
        prices = pcol[idx]; mws = qcol[idx]
        # independent crossing (domestic only)
        smask = sides .== :supply
        (p_ref, psm, pdm, qstar) = crossing(prices[smask], mws[smask],
            prices[.!smask], mws[.!smask])
        # engine domestic
        (p_dom, st_dom) = engine_price(zone, sides, prices, mws)
        # engine + injected net position
        sides2 = copy(sides); prices2 = copy(prices); mws2 = copy(mws)
        if net_import > 1e-6
            push!(sides2, :supply); push!(prices2, FLOOR); push!(mws2, net_import)
        elseif net_import < -1e-6
            push!(sides2, :demand); push!(prices2, CEIL); push!(mws2, -net_import)
        end
        (p_net, st_net) = engine_price(zone, sides2, prices2, mws2)
        # bracket membership for Layer A
        blo = min(psm, pdm); bhi = max(psm, pdm)
        inbrk = (p_dom >= blo - 1e-6 && p_dom <= bhi + 1e-6) ? 1 : 0
        max_sup_p = maximum(prices[smask])
        tot_sup = sum(mws[smask]); tot_dem = sum(mws[.!smask])
        write(out, join([ex, zone, day, hour, round(p_off, digits = 4),
                round(net_import, digits = 2), espt,
                round(p_ref, digits = 4), round(psm, digits = 4), round(pdm, digits = 4),
                round(p_dom, digits = 4), st_dom, inbrk,
                round(p_net, digits = 4), st_net,
                round(max_sup_p, digits = 2), round(qstar, digits = 1),
                round(tot_sup, digits = 1), round(tot_dem, digits = 1)], '\t'), '\n')
    end
    # Per-day file (no cross-process append race); analysis globs them.
    hdr = "exchange\tzone\tday\thour\tp_off\tnet_import\tespt\tp_ref\tp_sup_marg\t" *
          "p_dem_marg\tp_dom\tst_dom\tinbrk\tp_net\tst_net\tmax_sup_p\tqstar\ttot_sup\ttot_dem\n"
    mfile = joinpath(INT, "metrics_$(exl)_$(day).tsv")
    open(mfile, "w") do io
        write(io, hdr)
        write(io, String(take!(out)))
    end
    println("$(ex) $(day): wrote $(size(cells,1)) cells -> $(basename(mfile))")
end

main()
