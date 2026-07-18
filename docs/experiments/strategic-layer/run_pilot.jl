# Phase B pilot: the GR winning mechanism per big firm, on the zone's own
# calibrated book. Pre-registered expectation from the residual-sign gate:
# DE_LU/FR band residuals are +4/+3 (vs GR's +13 on its selected days), so
# markups should yield LITTLE — a clean "no exercisable markup" here is the
# placebo half of the GR finding, not a failure.
#
#   SL_ZONE=DE_LU julia --project=. docs/experiments/strategic-layer/run_pilot.jl
#   SL_ZONE=FR    julia --project=. docs/experiments/strategic-layer/run_pilot.jl
#
# Writes results_<ZONE>.tsv (+ heldout eval of the best config if any beats the
# additive null on calibration).

include(joinpath(@__DIR__, "zone_common.jl"))

const BIG = Dict(
    "DE_LU" => [
        ("RWE",    Set(["RWE"])),
        ("LEAG",   Set(["LEAG"])),
        ("Uniper", Set(["Uniper"])),
        ("EnBW",   Set(["EnBW"])),
        ("big4",   Set(["RWE", "LEAG", "Uniper", "EnBW"])),
    ],
    "FR" => [
        ("EDF",    Set(["EDF", "EDF (CNR/SHEM excepted)"])),
        ("Engie",  Set(["Engie"])),
        ("Total",  Set(["TotalEnergies"])),
    ],
)

CONFIGS = Any["baseline" => nothing]
for (name, firms) in BIG[ZONE]
    push!(CONFIGS, "$(name)_15" => firm_nearuniform(firms; markup=0.15))
    push!(CONFIGS, "$(name)_25" => firm_nearuniform(firms; markup=0.25))
end

println("PILOT $ZONE: $(length(CONFIGS)) configs × $(length(DAYS)) calibration days")
t0 = time()
acc = run_matrix(collect(CONFIGS))
@printf("matrix done in %.1f min\n\n", (time() - t0) / 60)
rows = summarize(acc)
print_table(rows)
nul = additive_null(DAYS)
nul !== nothing && @printf("\nadditive-null (best flat %+.2f €/MWh): MAE %.2f  resid %+.2f  [n=%d]\n",
    nul.shift, nul.mae, nul.resid, nul.n)
dump_tsv(joinpath(@__DIR__, "results_$(ZONE).tsv"), rows)
println("wrote results_$(ZONE).tsv")

# held-out check of the best non-baseline config IFF it beat the null on cal
best = first(r for r in rows if r.name != "baseline")
if nul !== nothing && best.mae !== missing && best.mae < nul.mae - 0.05
    println("\nbest config '$(best.name)' beats the additive null on calibration — evaluating held-out ($(length(HELDOUT)) days)")
    cfg = Dict(CONFIGS)[best.name]
    accH = run_matrix(["baseline" => nothing, best.name => cfg]; days=HELDOUT)
    rowsH = summarize(accH)
    print_table(rowsH)
    nulH = additive_null(HELDOUT)
    nulH !== nothing && @printf("\nheldout additive-null (%+.2f): MAE %.2f\n", nulH.shift, nulH.mae)
    dump_tsv(joinpath(@__DIR__, "results_heldout_$(ZONE).tsv"), rowsH)
else
    println("\nno config beats the additive null on calibration — GATE FAILED (the pre-registered placebo outcome); held-out not run")
end
