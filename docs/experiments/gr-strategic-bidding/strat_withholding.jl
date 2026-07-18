# Strategy 5 — ECONOMIC WITHHOLDING (quantity, not price).
# Instead of marking up, the incumbent removes a slice of its CHEAPEST capacity
# from the book, so a costlier unit sets the margin. Per timeslot we withhold a
# fraction `w` of the big firm's total offered supply, taken from the low-price
# end (the tranches it would otherwise undercut itself with). Physical/strategic
# withholding is the classic alternative lever to price markup.
#
# factory: withholding(; w=0.15) -> (day -> strategist)

withholding(; w::Float64=0.15) = (_day::Date) -> (ctx -> begin
    # big-firm supply orders grouped by timeslot, ascending price
    byts = Dict{String,Vector{Int}}()
    for (i, (o, tag)) in enumerate(ctx.tagged_orders)
        (is_supply(o) && is_big(ctx.firm_of, tag)) || continue
        push!(get!(byts, ts_of(o), Int[]), i)
    end
    drop = Set{Int}(); shrink = Dict{Int,Float64}()
    for (ts, idxs) in byts
        total = sum(ctx.tagged_orders[i][1].quantity for i in idxs)
        budget = w * total
        for i in sort(idxs, by=i -> ctx.tagged_orders[i][1].price)   # cheapest first
            budget <= 1e-6 && break
            q = ctx.tagged_orders[i][1].quantity
            if q <= budget
                push!(drop, i); budget -= q
            else
                shrink[i] = q - budget; budget = 0.0
            end
        end
    end
    out = Tuple{SimpleOrder,String}[]
    for (i, (o, tag)) in enumerate(ctx.tagged_orders)
        i in drop && continue
        haskey(shrink, i) ? push!(out, (setqty(o, shrink[i]), tag)) : push!(out, (o, tag))
    end
    out
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "withhold_10%" => withholding(w=0.10),
                      "withhold_20%" => withholding(w=0.20)])
    print_table(summarize(acc))
end
