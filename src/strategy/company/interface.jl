# company/interface.jl — the CompanyStrategy plug-in interface (strategy/DESIGN-pluggable.md, round 2).
# Included by ../formats.jl inside `module StrategyFormats`.
#
# A company strategy is a VALUE: a struct (its parameters) with an `offers` method per asset class it supports.
# Choosing one is passing that value; there is no env flag. Every strategy is one file in this directory.
# `bids(asset, "format", F, day; …)` (round 1's entry point) is a thin wrapper that maps the string to a struct.

# One shared abstract root with the market-conduct half when Euphemia defines it (st-impact, main-bound);
# standalone until then.
if isdefined(Euphemia, :BiddingStrategy)
    abstract type CompanyStrategy <: Euphemia.BiddingStrategy end
else
    abstract type CompanyStrategy end
end
if isdefined(Euphemia, :offers)
    import Euphemia: offers
else
    """offers(s, ctx) -> Vector{Tuple{MarketOrder,String}}: the orders strategy `s` submits for `ctx`, each with the
    strategy's label."""
    function offers end
end

"""
    CompanyCtx(asset, F, day, res; extra=(;))

What a company strategy may read when it builds its orders for `day`: the asset, our FORECAST prices `F` of the
asset's zone (one per period of `res` minutes), and `extra` (named, ex-ante inputs a strategy needs). Never realised
prices of `day` (as-of rule, strategy/DESIGN.md).
"""
struct CompanyCtx{A}
    asset::A
    F::Vector{Float64}
    day::Date
    res::Int
    zone::String
    extra::NamedTuple
end
CompanyCtx(asset, F::AbstractVector{<:Real}, day::Date, res::Int; extra::NamedTuple=(;)) =
    CompanyCtx(asset, Vector{Float64}(F), day, res, String(asset.zone), extra)

"""cost_reflective(s) -> Bool: every price the strategy submits is the asset's own marginal / opportunity cost
(incl. start-up and no-load spread over a block) under a stated ex-ante rule (owner addendum 2026-11-23 22:35Z)."""
cost_reflective(::CompanyStrategy) = true

"""label(s) -> String: the round-1 format id of a strategy (CSV `format` column)."""
function label end

_tag(s::CompanyStrategy, o::Vector{MarketOrder}) = Tuple{MarketOrder,String}[(x, label(s)) for x in o]

_k_ok(k) = (k <= 1.0 + 1e-9 || error("k_su = $k > 1 would price above cost incl. start-up"); Float64(k))

"""
    strategy_of(asset, fmt; k_su=1.0, nx=5, mar=0.5) -> CompanyStrategy

Round 1's format strings → strategy values (thermal `mar` = the flagged min-ratio MAR `MarMin`; hydro `mar` = the
cost-reflective `MarFull` at ratio `mar`).
"""
function strategy_of(a, fmt::String; k_su=1.0, nx=5, mar=0.5)
    fmt == "hourly_mc" && return HourlyMC()
    fmt == "hourly_ac" && return HourlyAC(k_su)
    fmt == "hourly_oc" && return HourlyOC()
    fmt == "hourly_sched" && return HourlySched()
    fmt == "block" && return Block(k_su)
    fmt == "linked" && return Linked(k_su)
    fmt == "exclusive" && return Exclusive(k_su, nx)
    fmt == "mar_full" && return MarFull(k_su, NaN)
    fmt == "mar" && return a isa Thermal ? MarMin(k_su) : MarFull(k_su, Float64(mar))
    fmt == "block_hac" && return BlockHAC(k_su)
    error("unknown format $fmt")
end

"""
    bids(asset, format, F, day; res=60, k_su=1.0, nx=5, mar=0.5) -> Vector{MarketOrder}

Round 1's entry point, kept as a thin wrapper: `offers(strategy_of(asset, format; …), CompanyCtx(asset, F, day, res))`
without the labels. Never pass realised prices of `day` as F.
"""
bids(a, fmt::String, F::Vector{Float64}, day::Date; res=60, k_su=1.0, nx=5, mar=0.5, kw...) =
    MarketOrder[o for (o, _) in offers(strategy_of(a, fmt; k_su=k_su, nx=nx, mar=mar), CompanyCtx(a, F, day, res))]

offers(s::CompanyStrategy, c::CompanyCtx) = error("$(typeof(s)) has no offers method for $(typeof(c.asset))")

# --- shared thermal pieces (cost-reflective pricing rule, ex ante, fleet data): a block's price = SRMC +
# (k_su·start-up + no-load × run hours) / block energy, k_su ≤ 1, so no price exceeds the unit's average cost incl.
# start-up and no-load over the block.
_th(c::CompanyCtx{Thermal}) = (a = c.asset; T = length(c.F); dt = c.res / 60;
    hrs = h -> max(1, round(Int, h / dt)); (a=a, T=T, dt=dt, z=a.zone, Ls=hrs(a.min_up):T))
_fixc(a::Thermal, k, dt) = L -> k * a.startup + a.noload * L * dt      # € per run of L periods

# --- shared retailer pieces: firm (1 − shift − curt) at the cap and curtailable at WTP, in every format
function _flex_base(c::CompanyCtx{Flex})
    a = c.asset; T = length(c.F); dt = c.res / 60; z = a.zone; o = MarketOrder[]
    L = length(a.load) == T ? a.load : repeat(a.load; inner=T ÷ length(a.load))
    firm = 1.0 - a.shift - a.curt
    for i in 1:T
        push!(o, _so(:demand, PRICE_CAP, firm * L[i], z, c.day, i, c.res))
        push!(o, _so(:demand, a.wtp, a.curt * L[i], z, c.day, i, c.res))
    end
    Es = a.shift * sum(L) * dt
    function plan(G)   # least-cost purchase of Es on G, ≤ pshift_max per period
        m = _lp(); @variable(m, 0 <= q[1:T] <= a.pshift_max); @constraint(m, en, sum(q) * dt >= Es)
        @objective(m, Min, sum(G[t] * dt * q[t] for t in 1:T)); optimize!(m)
        return value.(q), abs(dual(en))
    end
    return o, plan, T, dt, z
end

_pv(c::CompanyCtx{PVBat}) = (T = length(c.F); length(c.asset.pv) == T ? c.asset.pv : repeat(c.asset.pv; inner=T ÷ length(c.asset.pv)))
