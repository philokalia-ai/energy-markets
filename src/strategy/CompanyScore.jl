# src/strategy/CompanyScore.jl — score ANY company strategy value: price-taker on realised prices and, optionally, with
# impact (re-clear of our baseline book). strategy/DESIGN-pluggable.md (round 2).
#
# Load after the harness and the formats module (both standalone, never included from Euphemia.jl):
#     using Euphemia
#     include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
#     include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
#     include(joinpath(pkgdir(Euphemia), "src", "strategy", "CompanyScore.jl")); using .CompanyScore
module CompanyScore

using Dates
using Euphemia
import Euphemia.MarketOrders: MarketOrder, SimpleOrder, LinkedHourlyOrder
using ..StrategyHarness: BaselineDay, Carve, reclear
using ..StrategyFormats: CompanyStrategy, CompanyCtx, offers, cost_reflective, label, evaluate, settle

export score, forecast_vector

"""Our forecast of `zone` on the baseline book's periods, in period order (24 or 96 values)."""
forecast_vector(base::BaselineDay, zone::String) = [base.prices[zone][p] for p in base.book.periods]

"""
    score(s, asset, base; realised=nothing, carve=Carve[], impact=true, pen=0.0, allow_flagged=false, extra=(;))

Score company strategy `s` for `asset` on the baseline day `base`:
- the orders are `offers(s, CompanyCtx(asset, F, day, res))` with F = our forecast of the asset's zone (`base.prices`)
  and res = 1440 / number of book periods (60 at 24 steps, 15 at 96);
- `pricetaker`: `evaluate` at `realised` (the zone's realised prices of D, 24 or 96 values; SCORING ONLY), or nothing;
- `impact` (if `impact=true`): `reclear(base, orders; carve)`, then the clear's own acceptance settled at the
  simulated prices; with the zone's simulated prices `P`, their change `dp` vs our forecast and the per-order ratio.
Asserts `cost_reflective(s)` unless `allow_flagged=true` (only to reproduce round-1 rows).
"""
function score(s::CompanyStrategy, asset, base::BaselineDay; realised::Union{Nothing,Vector{Float64}}=nothing,
               carve::Vector{Carve}=Carve[], impact::Bool=true, pen::Float64=0.0, allow_flagged::Bool=false,
               extra::NamedTuple=(;))
    (cost_reflective(s) || allow_flagged) ||
        error("$(typeof(s)) is not cost-reflective (owner addendum 2026-11-23 22:35Z); pass allow_flagged=true only to reproduce round-1 rows")
    zone = String(asset.zone); day = base.day
    F = forecast_vector(base, zone)
    res = 1440 ÷ length(F)
    tagged = offers(s, CompanyCtx(asset, F, day, res; extra=extra))
    orders = MarketOrder[o for (o, _) in tagged]
    pt = realised === nothing ? nothing :
         evaluate(asset, orders, realised, day; res=1440 ÷ length(realised), pen=pen)
    im = nothing
    if impact
        r = reclear(base, orders; carve=carve)
        ratio = Float64[o.quantity > 0 ? r.accepted[i] / o.quantity : 0.0 for (i, o) in enumerate(orders)]
        P = [r.prices[zone][p] for p in base.book.periods]
        im = (result=settle(asset, orders, ratio, P, day; res=res, pen=pen), P=P, dp=P .- F, ratio=ratio,
              status=r.status, solve_s=r.solve_s, carve_shortfall=sum(values(r.carve_shortfall); init=0.0),
              reclear=r)
    end
    return (strategy=label(s), orders=orders, F=F, res=res, pricetaker=pt, impact=im)
end

end # module
