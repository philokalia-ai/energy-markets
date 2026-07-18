# Strategy 2 — TOP-SLICE MARKUP (realistic portfolio bidding).
# A rational incumbent bids its baseload/must-run tranches near cost (it wants
# them to run) and marks up only its FLEXIBLE upper tranches — the ones that set
# the price in tight hours.
#
# REVIEW FIX (July 2026). The original implementation anchored the slice to the
# unit's CHEAPEST tranche that hour. For committed units the book's deep
# must-run block is priced at 0.05×SRMC, so `slice_from × cheapest` ≈ 0.055×SRMC
# and the "top slice" actually marked up EVERYTHING above the deep must-run —
# including the below-cost second must-run block and the at-cost first flexible
# tranche. That near-uniform-on-committed behavior is preserved below as
# `nearuniform_markup` (it is what the original results.tsv "topslice_*" rows
# measured); the fixed `topslice_markup` anchors the slice to the unit-hour's
# QUANTITY-WEIGHTED MEDIAN tranche price, which sits in the at-cost flexible
# tranche (~0.95×SRMC), so `slice_from=1.10` marks up only tranches priced above
# ~1.05×SRMC — the genuinely flexible upper slice the strategy documents.
#
# factories:
#   topslice_markup(; markup=0.25, slice_from=1.10)    — true top slice (fixed)
#   nearuniform_markup(; markup=0.25, slice_from=1.10) — original behavior

function _qw_median_price(prices::Vector{Float64}, qtys::Vector{Float64})
    idx = sortperm(prices)
    tot = sum(qtys); half = tot / 2; run = 0.0
    for i in idx
        run += qtys[i]
        run >= half && return prices[i]
    end
    prices[idx[end]]
end

topslice_markup(; markup::Float64=0.25, slice_from::Float64=1.10) = (_day::Date) -> (ctx -> begin
    # quantity-weighted median tranche price per (unit tag, timeslot)
    pr = Dict{Tuple{String,String},Vector{Float64}}()
    qt = Dict{Tuple{String,String},Vector{Float64}}()
    for (o, tag) in ctx.tagged_orders
        (is_supply(o) && is_big(ctx.firm_of, tag)) || continue
        k = (tag, ts_of(o))
        push!(get!(pr, k, Float64[]), o.price)
        push!(get!(qt, k, Float64[]), o.quantity)
    end
    base = Dict(k => _qw_median_price(pr[k], qt[k]) for k in keys(pr))
    out = Tuple{SimpleOrder,String}[]
    for (o, tag) in ctx.tagged_orders
        if is_supply(o) && is_big(ctx.firm_of, tag)
            b = get(base, (tag, ts_of(o)), o.price)
            push!(out, (o.price > slice_from * b ? bump(o, 1 + markup) : o, tag))
        else
            push!(out, (o, tag))
        end
    end
    out
end)

nearuniform_markup(; markup::Float64=0.25, slice_from::Float64=1.10) = (_day::Date) -> (ctx -> begin
    minp = Dict{Tuple{String,String},Float64}()
    for (o, tag) in ctx.tagged_orders
        (is_supply(o) && is_big(ctx.firm_of, tag)) || continue
        k = (tag, ts_of(o))
        minp[k] = min(get(minp, k, Inf), o.price)
    end
    out = Tuple{SimpleOrder,String}[]
    for (o, tag) in ctx.tagged_orders
        if is_supply(o) && is_big(ctx.firm_of, tag)
            base = get(minp, (tag, ts_of(o)), o.price)
            push!(out, (o.price > slice_from * base ? bump(o, 1 + markup) : o, tag))
        else
            push!(out, (o, tag))
        end
    end
    out
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "topslice_25%" => topslice_markup(markup=0.25),
                      "nearuniform_25%" => nearuniform_markup(markup=0.25)])
    print_table(summarize(acc))
end
