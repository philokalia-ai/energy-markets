# Per-firm behavior probe: apply the winning mechanism (near-uniform markup on
# a firm's committed dispatchable range) to ONE firm at a time, at two rates.
# The ΔMAE each firm alone produces = its price-setting power on these days;
# the rate at which its markup best fits settled = its implied exercised markup.
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_per_firm.jl
#
# Uses tiered_markup (min-price anchor == the winning near-uniform semantics).
# 60 main days; writes results_per_firm.tsv.

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "strat_tiered_markup.jl"))

const FIRMS = [
    ("PPC",        ["PPC"]),
    ("Mytilineos", ["Mytilineos", "Mytilineos (CHP)"]),
    ("Elpedison",  ["Elpedison"]),
    ("Heron",      ["Heron/GEK-TERNA"]),
    ("Korinthos",  ["Korinthos Power"]),
]

CONFIGS = Any["baseline" => nothing]
for (name, fs) in FIRMS, rate in (0.25, 0.50)
    push!(CONFIGS, "$(name)_$(Int(rate*100))" => tiered_markup(markups=firm_markup(fs, rate)))
end
push!(CONFIGS, "PPC25+Myt25+Elp25" => tiered_markup(markups=firm_markup(
    ["PPC", "Mytilineos", "Mytilineos (CHP)", "Elpedison"], 0.25)))

println("per-firm matrix: $(length(CONFIGS)) configs × $(length(DAYS)) days")
t0 = time()
acc = run_matrix(collect(CONFIGS))
@printf("done in %.1f min\n\n", (time() - t0) / 60)
rows = summarize(acc)
print_table(rows)
open(joinpath(@__DIR__, "results_per_firm.tsv"), "w") do io
    println(io, "strategy\tcorr\tmae\tabsresid\tresid\tmae_gain\tdays_better\tn")
    for r in rows
        g(x) = x === missing ? "" : @sprintf("%.4f", x)
        println(io, join([r.name, g(r.corr), g(r.mae), g(r.absresid), g(r.resid),
            g(r.mae_gain), string(r.days_better), string(r.n)], "\t"))
    end
end
println("\nwrote results_per_firm.tsv")
