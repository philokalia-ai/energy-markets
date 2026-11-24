# st-impact markup model: the record pipeline's 2-pass day (as StrategyHarness.build_baseline) with a ZoneScenario per
# study zone. Writes nothing to runs/baseline. Used by mk_days.jl and test/strategy/test_strategist_labels.jl.
using Euphemia, Dates, Printf
import Euphemia.MarketOrders: SimpleOrder

_usable_mk(r) = r.status == :optimal || (r.status == :time_limit && !isempty(r.market_prices))

"""build_with_scenario(day, scenario; footprint) -> (prices zone => period => €/MWh, pass)"""
function build_with_scenario(day::Date, scenario; footprint, optimizer="highs")
    ctx() = Euphemia.gate_context(day)
    ob1 = Euphemia.with_context(ctx()) do
        mz_build_books(footprint, day; enrich_network=true, apply_zone_profiles=true, scenario=scenario)
    end
    r1 = mz_solve_pass(ob1; optimizer=optimizer, silent=true, decompose_periods=true)
    _usable_mk(r1) || error("mk $day: pass-1 unusable ($(r1.status))")
    ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
    res, pass = r1, 1
    if !isempty(ai.anchored)
        ob2 = Euphemia.with_context(ctx()) do
            mz_rebuild_anchored(footprint, day, ai.refs, ai.cached; transfer_capacity=ai.network,
                enrich_network=true, apply_zone_profiles=true, scenario=scenario)
        end
        r2 = mz_solve_pass(ob2; optimizer=optimizer, silent=true, decompose_periods=true)
        _usable_mk(r2) && ((res, pass) = (r2, 2))
    end
    return res.market_prices, pass
end

"""No-op strategists: `triples=true` returns (order, tag, strategy) (labels kept: the fix); false returns (order, tag)
pairs — the pre-fix contract, whose relabel to "strategist" drops the storage families."""
noop_strategist(triples::Bool) = ctx -> triples ?
    [(o, t, s) for ((o, t), s) in zip(ctx.tagged_orders, ctx.strategies)] :
    [(o, t) for (o, t) in ctx.tagged_orders]

"""Markup strategist: every `srmc_base` / `peak_tranche_*` order of the zone is re-priced at gmc × (1 + m[hour]),
gmc = the unit-hour's srmc_base price / 0.95 (TRANCHES[1], zone_profiles.jl:238). m: Dict(hour_utc => markup);
hours without an entry keep the book's ladder. Labels kept (triples)."""
function markup_strategist(m::Dict{Int,Float64})
    return function (ctx)
        gmc = Dict{Tuple{String,DateTime},Float64}()
        for ((o, t), s) in zip(ctx.tagged_orders, ctx.strategies)
            s == "srmc_base" && (gmc[(t, o.date_time)] = o.price / 0.95)
        end
        out = Tuple{SimpleOrder,String,String}[]
        for ((o, t), s) in zip(ctx.tagged_orders, ctx.strategies)
            h = Dates.hour(o.date_time)
            if (s == "srmc_base" || startswith(s, "peak_tranche")) && haskey(m, h) && haskey(gmc, (t, o.date_time))
                o = SimpleOrder(o.type, gmc[(t, o.date_time)] * (1.0 + m[h]), o.quantity, o.zone, o.date_time, o.resolution_code)
            end
            push!(out, (o, t, s))
        end
        return out
    end
end
