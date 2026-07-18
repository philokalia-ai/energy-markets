# Focused confirmation pass: fine sweep of the winning top-slice strategy, plus
# the withholding runner-up, under whatever big-firm set EUPHEMIA_BIG_FIRMS
# selects (default PPC ~69%; set "PPC,Mytilineos,Mytilineos (CHP),Elpedison,
# Heron/GEK-TERNA,Korinthos Power" for ~80% of the mapped registry).
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_focus.jl
#   EUPHEMIA_BIG_FIRMS="PPC,Mytilineos,Mytilineos (CHP),Elpedison,Heron/GEK-TERNA,Korinthos Power" \
#     julia --project=. docs/experiments/gr-strategic-bidding/run_focus.jl

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "strat_topslice_markup.jl"))
include(joinpath(@__DIR__, "strat_withholding.jl"))
include(joinpath(@__DIR__, "strat_uniform_markup.jl"))

const CONFIGS = [
    "baseline"          => nothing,
    "topslice_15%"      => topslice_markup(markup=0.15, slice_from=1.10),
    "topslice_25%"      => topslice_markup(markup=0.25, slice_from=1.10),
    "topslice_35%"      => topslice_markup(markup=0.35, slice_from=1.10),
    "topslice_25%_s105" => topslice_markup(markup=0.25, slice_from=1.05),
    "topslice_25%_s120" => topslice_markup(markup=0.25, slice_from=1.20),
    "withhold_08%"      => withholding(w=0.08),
    "withhold_12%"      => withholding(w=0.12),
    "uniform_10%"       => uniform_markup(markup=0.10),
]

println("focus matrix: big firms = ", join(sort(collect(BIG_FIRMS)), ", "))
t0 = time()
acc = run_matrix(collect(CONFIGS))
@printf("done in %.1f min\n\n", (time() - t0) / 60)
print_table(summarize(acc))
