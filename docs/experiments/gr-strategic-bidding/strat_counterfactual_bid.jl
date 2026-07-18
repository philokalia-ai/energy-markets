# Strategy 4 — COUNTERFACTUAL-AWARE BID (the "players see the counterfactual").
# The incumbent knows the competitive clearing price p0[h] (the model's own
# baseline — what the market WOULD clear at). It lifts every one of its supply
# tranches that currently sits just below a target of p0[h] × (1 + headroom)
# UP to that target — pricing into the headroom it knows the demand curve can
# absorb, dragging the marginal price up toward the level it can sustain. It
# does not touch tranches already above target (no volume gain) or far below
# (deep-inframarginal must-run it still wants dispatched).
#
# This is the most literal test of the user's question: give the players the
# counterfactual and let them bid against it.
#
# factory: counterfactual_bid(; headroom=0.20, floor_frac=0.75) -> (day -> strategist)
# needs the baseline; get_baseline(day) from common.jl.

function counterfactual_bid(; headroom::Float64=0.20, floor_frac::Float64=0.75)
    return (day::Date) -> begin
        p0 = get_baseline(day)             # ts "yyyymmdd-HHMM" => competitive €/MWh
        ctx -> begin
            out = Tuple{SimpleOrder,String}[]
            for (o, tag) in ctx.tagged_orders
                if is_supply(o) && is_big(ctx.firm_of, tag)
                    base = get(p0, ts_of(o), nothing)
                    if base !== nothing && base > 0
                        target = base * (1 + headroom)
                        # Lift tranches in (floor_frac·BASE, target) to the target.
                        # Review fix: the band floor was previously floor_frac·target,
                        # which for headroom ≥ 1/floor_frac − 1 (≈0.33 at 0.75) put
                        # the whole band ABOVE the competitive clearing price — the
                        # strategy then repriced only never-accepted orders, a
                        # provable no-op (cf_bid_35% ≡ baseline in the original
                        # results.tsv is that artifact, not a real saturation).
                        if floor_frac * base < o.price < target
                            push!(out, (setprice(o, target), tag)); continue
                        end
                    end
                end
                push!(out, (o, tag))
            end
            out
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "cf_bid_15%" => counterfactual_bid(headroom=0.15),
                      "cf_bid_25%" => counterfactual_bid(headroom=0.25)])
    print_table(summarize(acc))
end
