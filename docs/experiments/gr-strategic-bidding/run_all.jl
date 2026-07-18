# Run the whole strategy matrix over the 60 medium-correlation GR days and rank
# by paired MAE gain vs the competitive baseline (the shared same-day reference).
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_all.jl
#   NDAYS=6 julia ... run_all.jl          # quick smoke on the first 6 days
#   EUPHEMIA_BIG_FIRMS="PPC,Mytilineos,Elpedison" julia ... run_all.jl
#
# Day-outer: each day is built once (warm caches), then every config re-clears
# it cheaply, so the full matrix is roughly one baseline pass in wall time.

include(joinpath(@__DIR__, "common.jl"))
for f in ["strat_uniform_markup", "strat_topslice_markup", "strat_pivotal_markup",
          "strat_counterfactual_bid", "strat_withholding", "strat_share_proportional",
          "strat_peak_hour_markup"]
    include(joinpath(@__DIR__, f * ".jl"))
end

const CONFIGS = [
    "baseline"            => nothing,
    # 1 uniform
    "uniform_10%"         => uniform_markup(markup=0.10),
    "uniform_20%"         => uniform_markup(markup=0.20),
    "uniform_35%"         => uniform_markup(markup=0.35),
    # 2 top-slice
    "topslice_25%"        => topslice_markup(markup=0.25, slice_from=1.10),
    "topslice_40%"        => topslice_markup(markup=0.40, slice_from=1.10),
    # 3 pivotal
    "pivotal_30%"         => pivotal_markup(markup=0.30),
    "pivotal_50%"         => pivotal_markup(markup=0.50),
    "pivotal_80%"         => pivotal_markup(markup=0.80),
    # 4 counterfactual-aware
    "cf_bid_10%"          => counterfactual_bid(headroom=0.10),
    "cf_bid_20%"          => counterfactual_bid(headroom=0.20),
    "cf_bid_35%"          => counterfactual_bid(headroom=0.35),
    # 5 withholding
    "withhold_10%"        => withholding(w=0.10),
    "withhold_20%"        => withholding(w=0.20),
    "withhold_35%"        => withholding(w=0.35),
    # 6 share-proportional
    "share_e2.0"          => share_proportional(elasticity=2.0),
    "share_e1.0"          => share_proportional(elasticity=1.0),
    # 7 peak-hour
    "peak6_30%"           => peak_hour_markup(markup=0.30, topk=6),
    "peak10_40%"          => peak_hour_markup(markup=0.40, topk=10),
]

days = DAYS
if haskey(ENV, "NDAYS")
    days = DAYS[1:min(parse(Int, ENV["NDAYS"]), length(DAYS))]
end

println("GR strategic-bidding matrix: $(length(CONFIGS)) configs × $(length(days)) days")
println("big firms: ", join(sort(collect(BIG_FIRMS)), ", "))
t0 = time()
acc = run_matrix(collect(CONFIGS); days=days)
@printf("\nmatrix done in %.1f min\n\n", (time() - t0) / 60)

rows = summarize(acc)
println("Ranked by paired ΔMAE vs baseline (positive = closer to settled price):\n")
print_table(rows)

# machine-readable dump for the README / third parties
open(joinpath(@__DIR__, "results.tsv"), "w") do io
    println(io, "strategy\tcorr\tmae\tabsresid\tresid\tmae_gain\tdays_better\tn")
    for r in rows
        g(x) = x === missing ? "" : @sprintf("%.4f", x)
        println(io, join([r.name, g(r.corr), g(r.mae), g(r.absresid), g(r.resid),
            g(r.mae_gain), string(r.days_better), string(r.n)], "\t"))
    end
end
println("\nwrote results.tsv")
