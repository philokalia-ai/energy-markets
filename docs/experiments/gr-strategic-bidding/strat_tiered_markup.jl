# Strategy 8 — TIERED TOP-SLICE MARKUP (per-firm markup rates).
# Generalizes the winning top-slice to an arbitrary firm→markup map, so we can
# ask the follow-up questions: do the SMALLER players move the price (mark up
# the fringe, not PPC)? does a COMBINED markup (PPC + fringe, or PPC deeper)
# close more of the residual? Each firm in `markups` has its flexible upper
# tranches (price > slice_from × the unit's cheapest tranche that hour) lifted by
# its own rate; every other order is untouched.
#
# factory: tiered_markup(; markups::Dict{String,Float64}, slice_from=1.10)
#            -> (day -> strategist)
#
# Firm-group shorthands (GR):
const GR_PPC    = ["PPC"]
const GR_FRINGE = ["Mytilineos", "Mytilineos (CHP)", "Elpedison",
                   "Heron/GEK-TERNA", "Korinthos Power"]

tiered_markup(; markups::Dict{String,Float64}, slice_from::Float64=1.10) =
    (_day::Date) -> (ctx -> begin
        minp = Dict{Tuple{String,String},Float64}()
        for (o, tag) in ctx.tagged_orders
            f = get(ctx.firm_of, tag, "")
            (is_supply(o) && haskey(markups, f)) || continue
            k = (tag, ts_of(o)); minp[k] = min(get(minp, k, Inf), o.price)
        end
        out = Tuple{SimpleOrder,String}[]
        for (o, tag) in ctx.tagged_orders
            f = get(ctx.firm_of, tag, "")
            if is_supply(o) && haskey(markups, f)
                base = get(minp, (tag, ts_of(o)), o.price)
                push!(out, (o.price > slice_from * base ?
                    bump(o, 1 + markups[f]) : o, tag))
            else
                push!(out, (o, tag))
            end
        end
        out
    end)

# convenience builders
firm_markup(firms::Vector{String}, m::Float64) = Dict(f => m for f in firms)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix([
        "baseline"     => nothing,
        "ppc_25"       => tiered_markup(markups=firm_markup(GR_PPC, 0.25)),
        "fringe_25"    => tiered_markup(markups=firm_markup(GR_FRINGE, 0.25)),
        "combined_25"  => tiered_markup(markups=firm_markup([GR_PPC; GR_FRINGE], 0.25)),
    ])
    print_table(summarize(acc))
end
