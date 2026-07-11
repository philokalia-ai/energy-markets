# Acceptance test: the pipelined backfill must produce EXACTLY the prices the
# sequential two-pass path produces, on the same backend.
#
# Runs 2026-04-01..03 (default) both ways and compares every (day, zone,
# timeslot) price. Target: bit-identical (Δ == 0). Reports the max abs diff and
# the first few mismatches; exits nonzero if any diff exceeds --tol (default 0).
#
#   julia --project=. test/scripts/pipeline_identity.jl [START END] [--tol X] [--optimizer gurobi|highs]

using Euphemia, Dates, Printf

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

function parse_cli(argv)
    sd, ed = Date(2026, 4, 1), Date(2026, 4, 3)
    tol = 0.0; optimizer = "gurobi"
    pos = String[]
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--tol"; tol = parse(Float64, argv[i+1]); i += 1
        elseif a == "--optimizer"; optimizer = argv[i+1]; i += 1
        else push!(pos, a) end
        i += 1
    end
    length(pos) >= 2 && (sd = Date(pos[1]); ed = Date(pos[2]))
    return sd, ed, tol, optimizer
end

sd, ed, tol, optimizer = parse_cli(ARGS)
days = collect(sd:Day(1):ed)
const CM = "pipeline_identity"   # scratch clearing_mode; nothing is saved

println("Backend: ", Euphemia.DATA_STORE[], "  optimizer=", optimizer,
        "  days=", sd, "..", ed, "  tol=", tol)

# --- Sequential reference (existing entry point, passes=2, save_to_db=false) ---
println("\n=== SEQUENTIAL (reference) ===")
seq = Dict{Date,Dict{String,Dict{String,Float64}}}()
t0 = time()
for d in days
    res = Euphemia.run_multi_zone_market_clearing(d; zones=FOOTPRINT,
        order_method=:merit_order, optimizer=optimizer, enrich_network=true,
        apply_zone_profiles=true, passes=2, clearing_mode=CM, save_to_db=false,
        silent=true)
    seq[d] = deepcopy(res.market_prices)
    println(">>> seq $d status=$(res.status) zones=$(length(res.market_prices))")
end
@printf("sequential wall: %.0f s\n", time() - t0)

# --- Pipeline (collect_prices, no save, no resume) ---
println("\n=== PIPELINE ===")
t1 = time()
pr = Euphemia.run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=2, optimizer=optimizer, clearing_mode=CM,
    save_to_db=false, resume=false, collect_prices=true)
pip = pr.day_prices
@printf("pipeline wall: %.0f s (%.1f days/h, solver util %s)\n",
    time() - t1, pr.days_per_hour, string(round.(pr.solver_utilization .* 100, digits=1)))

# --- Compare ---
println("\n=== IDENTITY COMPARISON ===")
maxdiff = 0.0
nmiss = 0
ncmp = 0
mismatches = Tuple{Date,String,String,Float64,Float64}[]
for d in days
    sp = get(seq, d, nothing); pp = get(pip, d, nothing)
    if sp === nothing || pp === nothing
        println("MISSING day $d  seq=$(sp!==nothing) pip=$(pp!==nothing)"); global nmiss += 1; continue
    end
    zs = union(Set(keys(sp)), Set(keys(pp)))
    for z in zs
        szp = get(sp, z, nothing); pzp = get(pp, z, nothing)
        if szp === nothing || pzp === nothing
            println("MISSING zone $d/$z  seq=$(szp!==nothing) pip=$(pzp!==nothing)"); global nmiss += 1; continue
        end
        ts = union(Set(keys(szp)), Set(keys(pzp)))
        for t in ts
            a = get(szp, t, NaN); b = get(pzp, t, NaN)
            global ncmp += 1
            dif = abs(a - b)
            if dif > maxdiff; global maxdiff = dif; end
            if !(dif <= tol) && length(mismatches) < 25
                push!(mismatches, (d, z, t, a, b))
            end
        end
    end
end

@printf("\ncompared %d zone-hour prices across %d day(s)\n", ncmp, length(days))
@printf("max |Δ price| = %.3e €/MWh\n", maxdiff)
if nmiss > 0
    println("⚠️  $nmiss missing day/zone entries");
end
if isempty(mismatches) && nmiss == 0
    println("✅ IDENTICAL within tol=$tol — pipeline == sequential")
    exit(0)
else
    println("❌ MISMATCH (first $(length(mismatches))):")
    for (d, z, t, a, b) in mismatches
        @printf("   %s %s %s  seq=%.6f  pip=%.6f  Δ=%.3e\n", d, z, t, a, b, abs(a - b))
    end
    exit(1)
end
