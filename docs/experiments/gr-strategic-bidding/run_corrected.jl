# CORRECTED evaluation pass (post code-review). Three parts:
#
#  A. Main 60 days, fixed instruments: hour-averaged eval (symmetric on 15-min
#     days), TRUE top-slice (qty-weighted-median anchor) vs the original
#     near-uniform behavior (honestly renamed), fixed counterfactual-bid band,
#     plus an ANALYTIC post-hoc additive level-shift null — the strongest
#     trivial competitor any strategy must beat.
#  B. Held-out validation: the 94 medium-corr band days NOT in the 60-day
#     selection (heldout_days.json) — kills the winner's-curse objection for
#     the headline configs.
#  C. Fair coupled comparison: single-zone baseline + near-uniform 25% on
#     exactly the 24 days the coupled evaluation used (coupled_days.json), so
#     the coupled ΔMAE juxtaposition is paired on identical days.
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_corrected.jl
#
# Outputs: results_corrected.tsv, results_heldout.tsv, results_coupled_fair.tsv

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "strat_topslice_markup.jl"))
include(joinpath(@__DIR__, "strat_uniform_markup.jl"))
include(joinpath(@__DIR__, "strat_counterfactual_bid.jl"))
include(joinpath(@__DIR__, "strat_withholding.jl"))

const HELDOUT = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, "heldout_days.json"))]
const COUPLED24 = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, "coupled_days.json"))]

# --- analytic additive level-shift null (post-hoc optimal on the given days) --
# corr is invariant to an additive shift, so this null isolates how much of a
# strategy's MAE gain is mere level correction.
function additive_null(days)
    pairs = Dict{Date,Tuple{Vector{Float64},Vector{Float64}}}()
    for day in days
        sim = get_baseline(day)
        hsum = Dict{String,Float64}(); hn = Dict{String,Int}()
        for (ts, sp) in sim
            hk = ts[1:9] * ts[10:11] * "00"
            hsum[hk] = get(hsum, hk, 0.0) + sp; hn[hk] = get(hn, hk, 0) + 1
        end
        a = Float64[]; s = Float64[]
        for (hk, tot) in hsum
            ap = get(ACTUALS, hk, nothing); ap === nothing && continue
            push!(a, ap); push!(s, tot / hn[hk])
        end
        length(a) >= 12 && (pairs[day] = (a, s))
    end
    best = (Inf, 0.0)
    for c in 0.0:0.25:25.0
        m = mean(mean(abs.(a .- (s .+ c))) for (a, s) in values(pairs))
        m < best[1] && (best = (m, c))
    end
    mae, c = best
    resid = mean(mean(a .- (s .+ c)) for (a, s) in values(pairs))
    corr = mean_skip([(std(a) > 0 && std(s) > 0) ? cor(a, s) : missing
                      for (a, s) in values(pairs)])
    (mae=mae, shift=c, resid=resid, corr=corr, n=length(pairs))
end

function dump_tsv(path, rows)
    open(path, "w") do io
        println(io, "strategy\tcorr\tmae\tabsresid\tresid\tmae_gain\tdays_better\tn")
        for r in rows
            g(x) = x === missing ? "" : @sprintf("%.4f", x)
            println(io, join([r.name, g(r.corr), g(r.mae), g(r.absresid), g(r.resid),
                g(r.mae_gain), string(r.days_better), string(r.n)], "\t"))
        end
    end
end

# ---------- A. main 60 days ----------
println("== A. main 60 days (fixed eval + fixed strategies) ==")
CONFIGS_A = [
    "baseline"        => nothing,
    "ts_true_15"      => topslice_markup(markup=0.15),
    "ts_true_25"      => topslice_markup(markup=0.25),
    "ts_true_35"      => topslice_markup(markup=0.35),
    "ts_true_50"      => topslice_markup(markup=0.50),
    "nearuniform_25"  => nearuniform_markup(markup=0.25),
    "uniform_20"      => uniform_markup(markup=0.20),
    "cfbid_fix_20"    => counterfactual_bid(headroom=0.20),
    "cfbid_fix_35"    => counterfactual_bid(headroom=0.35),
    "withhold_10"     => withholding(w=0.10),
]
t0 = time()
accA = run_matrix(collect(CONFIGS_A))
rowsA = summarize(accA)
print_table(rowsA)
nullA = additive_null(DAYS)
@printf("\nadditive-null (best flat +%.2f €/MWh): MAE %.2f  corr %.3f  resid %.2f  [corr unchangeable by construction]\n",
    nullA.shift, nullA.mae, nullA.corr, nullA.resid)
dump_tsv(joinpath(@__DIR__, "results_corrected.tsv"), rowsA)
@printf("A done in %.1f min\n\n", (time() - t0) / 60)

# ---------- B. held-out 94 days ----------
println("== B. held-out 94 band days (winner's-curse check) ==")
CONFIGS_B = [
    "baseline"        => nothing,
    "ts_true_25"      => topslice_markup(markup=0.25),
    "nearuniform_25"  => nearuniform_markup(markup=0.25),
]
t0 = time()
accB = run_matrix(collect(CONFIGS_B); days=HELDOUT)
rowsB = summarize(accB)
print_table(rowsB)
nullB = additive_null(HELDOUT)
@printf("\nadditive-null (best flat +%.2f €/MWh): MAE %.2f  corr %.3f  resid %.2f\n",
    nullB.shift, nullB.mae, nullB.corr, nullB.resid)
dump_tsv(joinpath(@__DIR__, "results_heldout.tsv"), rowsB)
@printf("B done in %.1f min\n\n", (time() - t0) / 60)

# ---------- C. fair 24-day single-zone comparison for the coupled juxtaposition ----------
println("== C. single-zone on the 24 coupled-evaluated days ==")
CONFIGS_C = [
    "baseline"        => nothing,
    "nearuniform_25"  => nearuniform_markup(markup=0.25),   # what the coupled run used
    "ts_true_25"      => topslice_markup(markup=0.25),
]
t0 = time()
accC = run_matrix(collect(CONFIGS_C); days=COUPLED24)
rowsC = summarize(accC)
print_table(rowsC)
dump_tsv(joinpath(@__DIR__, "results_coupled_fair.tsv"), rowsC)
@printf("C done in %.1f min\n", (time() - t0) / 60)
println("ALL CORRECTED RUNS DONE")
