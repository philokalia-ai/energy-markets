# Strategy 1 — UNIFORM MARKUP.
# The crudest exercise of market power: every big-firm SUPPLY order is offered
# at (1 + markup) × its short-run marginal cost, regardless of hour or
# pivotality. A flat Lerner index applied portfolio-wide. Baseline sanity check
# for "does any markup at all move sim toward actual".
#
# factory: uniform_markup(; markup=0.15) -> (day -> strategist)
# (day is ignored — this strategy is stateless.)

uniform_markup(; markup::Float64=0.15) = (_day::Date) -> (ctx -> begin
    [(is_supply(o) && is_big(ctx.firm_of, tag) ? bump(o, 1 + markup) : o, tag)
     for (o, tag) in ctx.tagged_orders]
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "uniform_10%" => uniform_markup(markup=0.10),
                      "uniform_20%" => uniform_markup(markup=0.20)])
    print_table(summarize(acc))
end
