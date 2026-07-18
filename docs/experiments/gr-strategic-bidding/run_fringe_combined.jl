# Follow-up matrix (single-zone GR, fast): do the SMALLER players control the
# price, and does a COMBINED / deeper markup close more of the residual?
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_fringe_combined.jl
#
# All single-zone GR on the 60 medium-corr days (baseline resid +13.2). Answers:
#   Q2 (fringe power): fringe-only markup vs PPC-only.
#   Q1 (close the gap): combined PPC+fringe, and deeper PPC (coupling gives it
#       headroom, so test 25/35/50% PPC too).

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "strat_tiered_markup.jl"))

const CONFIGS = [
    "baseline"              => nothing,
    # PPC alone (the winner), depth sweep
    "ppc_25"                => tiered_markup(markups=firm_markup(GR_PPC, 0.25)),
    "ppc_35"                => tiered_markup(markups=firm_markup(GR_PPC, 0.35)),
    "ppc_50"                => tiered_markup(markups=firm_markup(GR_PPC, 0.50)),
    # fringe alone — do the small players move price? (Q2)
    "fringe_25"             => tiered_markup(markups=firm_markup(GR_FRINGE, 0.25)),
    "fringe_50"             => tiered_markup(markups=firm_markup(GR_FRINGE, 0.50)),
    "fringe_100"            => tiered_markup(markups=firm_markup(GR_FRINGE, 1.00)),
    # combined PPC + fringe (Q1)
    "combined_25"           => tiered_markup(markups=firm_markup([GR_PPC; GR_FRINGE], 0.25)),
    "ppc35_fringe25"        => tiered_markup(markups=merge(
                                    firm_markup(GR_PPC, 0.35), firm_markup(GR_FRINGE, 0.25))),
    "ppc25_fringe50"        => tiered_markup(markups=merge(
                                    firm_markup(GR_PPC, 0.25), firm_markup(GR_FRINGE, 0.50))),
]

days = DAYS
haskey(ENV, "NDAYS") && (days = DAYS[1:min(parse(Int, ENV["NDAYS"]), length(DAYS))])
println("fringe/combined matrix: $(length(CONFIGS)) configs × $(length(days)) days")
t0 = time()
acc = run_matrix(collect(CONFIGS); days=days)
@printf("done in %.1f min\n\n", (time() - t0) / 60)
rows = summarize(acc)
print_table(rows)

open(joinpath(@__DIR__, "results_fringe.tsv"), "w") do io
    println(io, "strategy\tcorr\tmae\tabsresid\tresid\tmae_gain\tdays_better\tn")
    for r in rows
        g(x) = x === missing ? "" : @sprintf("%.4f", x)
        println(io, join([r.name, g(r.corr), g(r.mae), g(r.absresid), g(r.resid),
            g(r.mae_gain), string(r.days_better), string(r.n)], "\t"))
    end
end
println("\nwrote results_fringe.tsv")
