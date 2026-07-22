# Symbolic regression on the markup dataset (model C).
#
# Two runs on GR: core features (margin, d_hat) and a rich set.
# Deliverable: the Pareto front (complexity vs loss) with test-set price MAE
# for every front member. Run with:  julia -t auto --project=. sr_fit.jl
using CSV, DataFrames, SymbolicRegression
using SymbolicRegression: calculate_pareto_frontier, eval_tree_array, string_tree,
    compute_complexity

using Dates
df = CSV.read("dataset.tsv.gz", DataFrame)
gr = df[df.zone.=="GR", :]
train = gr[(gr.day .>= Date(2023, 7, 1)) .& (gr.day .<= Date(2025, 6, 30)), :]
test = gr[(gr.day .>= Date(2025, 7, 1)) .& (gr.day .<= Date(2026, 6, 30)), :]

square(x) = x * x
cube(x) = x * x * x

function run_sr(feats::Vector{Symbol}, label::String; niter=60, timeout=900)
    tr = dropmissing(train, [feats; :y])
    te = dropmissing(test, [feats; :y])
    X = permutedims(Matrix{Float64}(tr[:, feats]))
    y = Float64.(tr.y)
    Xte = permutedims(Matrix{Float64}(te[:, feats]))

    opts = SymbolicRegression.Options(
        binary_operators=[+, -, *, /],
        unary_operators=[square, cube, relu, exp],
        maxsize=30,
        timeout_in_seconds=Float64(timeout),
        parsimony=0.001,
        deterministic=false,
        seed=0,
    )
    hof = equation_search(X, y; options=opts, niterations=niter,
        parallelism=:multithreading,
        variable_names=String.(feats))
    front = calculate_pareto_frontier(hof)

    rows = DataFrame(complexity=Int[], train_loss=Float64[],
        test_mae_eur=Float64[], test_corr=Float64[], equation=String[])
    for m in front
        pred, ok = eval_tree_array(m.tree, Xte, opts)
        ok || continue
        pp = pred .* te.srmc_gas
        mae = sum(abs.(pp .- te.price)) / length(pp)
        corr = cor(pp, te.price)
        push!(rows, (compute_complexity(m.tree, opts), m.loss, mae, corr,
            string_tree(m.tree, opts, variable_names=String.(feats))))
    end
    CSV.write("sr_front_$(label).tsv", rows; delim='\t')
    println("== $label pareto front ==")
    show(rows, allrows=true, allcols=true, truncate=200)
    println()
    rows
end

using Statistics: cor
run_sr([:margin, :d_hat], "core")
run_sr([:margin, :d_hat, :res_share, :imp_share, :fill_frac], "rich")
