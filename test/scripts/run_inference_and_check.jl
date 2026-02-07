# Compare gas classification before and after behavioral validation (Stage 1 vs Stage 1+2)
#
# Stage 1: Name keywords + capacity fallback (at generator load time)
# Stage 2: Behavioral validation from historical generation data (at inference time)
#
# Usage:
#   julia --project=. test/scripts/run_inference_and_check.jl

using Dates
include(joinpath(@__DIR__, "..", "..", "src", "Euphemia.jl"))
using .Euphemia

const REFERENCE_DATE = Date(2024, 6, 15)
const ZONES = ["DE_LU", "FR", "NL", "PL", "IT-NORTH", "GR", "ES", "BE", "AT", "HU"]

const GAS_CCGT = Symbol("Fossil Gas")
const GAS_CHP = Symbol("Fossil Gas CHP")
const GAS_OCGT = Symbol("Fossil Gas OCGT")

function count_gas_classes(generators)
    ccgt = count(g -> g.fuel_type == GAS_CCGT, generators)
    chp  = count(g -> g.fuel_type == GAS_CHP, generators)
    ocgt = count(g -> g.fuel_type == GAS_OCGT, generators)
    return (ccgt=ccgt, chp=chp, ocgt=ocgt)
end

function find_reclassifications(gens_before, gens_after)
    before_map = Dict(g.code => g.fuel_type for g in gens_before)
    results = NamedTuple{(:name, :code, :p_max, :from, :to, :cost), Tuple{String, String, Float64, Symbol, Symbol, Float64}}[]
    for g in gens_after
        if haskey(before_map, g.code) && before_map[g.code] != g.fuel_type
            push!(results, (name=g.name, code=g.code, p_max=g.p_max,
                            from=before_map[g.code], to=g.fuel_type, cost=g.marginal_cost))
        end
    end
    return sort(results, by=x -> x.p_max, rev=true)
end

function run_comparison()
    println("=" ^ 80)
    println("STAGE 1+2: Running inference on all zones (behavioral validation active)")
    println("Reference date: $REFERENCE_DATE")
    println("=" ^ 80)

    before_counts = Dict{String, NamedTuple}()
    after_counts = Dict{String, NamedTuple}()

    for zone in ZONES
        println("\n--- $zone ---")

        # BEFORE: get_generators (Stage 1 only)
        gens_before = try
            get_generators(zone, REFERENCE_DATE; exclude_variable_renewables=true)
        catch e
            println("  WARNING: Failed to load generators: $e")
            continue
        end

        before_counts[zone] = count_gas_classes(gens_before)
        b = before_counts[zone]
        println("  Before inference: $(b.ccgt) CCGT, $(b.chp) CHP, $(b.ocgt) OCGT")

        # AFTER: get_generators_with_inferred_params (Stage 1 + Stage 2)
        gens_after = try
            get_generators_with_inferred_params(zone, REFERENCE_DATE;
                use_cache=false, exclude_variable_renewables=true)
        catch e
            println("  WARNING: Inference failed: $e")
            continue
        end

        after_counts[zone] = count_gas_classes(gens_after)
        a = after_counts[zone]
        println("  After inference:  $(a.ccgt) CCGT, $(a.chp) CHP, $(a.ocgt) OCGT")

        # Show reclassifications
        reclassified = find_reclassifications(gens_before, gens_after)
        if !isempty(reclassified)
            println("\n  Behavioral reclassifications:")
            for r in reclassified
                from_cost = Euphemia.get_marginal_cost(REFERENCE_DATE, string(r.from))
                println("    $(rpad(r.name, 40)) $(lpad(string(round(Int, r.p_max)), 5)) MW  " *
                        "$(r.from) -> $(r.to)  cost: $(round(from_cost, digits=1)) -> $(round(r.cost, digits=1)) EUR/MWh")
            end
        else
            println("  No behavioral reclassifications")
        end
    end

    # Summary table
    println("\n" * "=" ^ 80)
    println("SUMMARY: Before vs After Inference")
    println("=" ^ 80)
    println(rpad("Zone", 12), rpad("CCGT", 16), rpad("CHP", 16), rpad("OCGT", 16))
    println(rpad("", 12), rpad("before->after", 16), rpad("before->after", 16), rpad("before->after", 16))
    println("-" ^ 60)

    total_ccgt_b, total_chp_b, total_ocgt_b = 0, 0, 0
    total_ccgt_a, total_chp_a, total_ocgt_a = 0, 0, 0

    for zone in ZONES
        if !haskey(before_counts, zone) || !haskey(after_counts, zone)
            continue
        end
        b = before_counts[zone]
        a = after_counts[zone]

        ccgt_str = "$(b.ccgt)->$(a.ccgt)" * (a.ccgt != b.ccgt ? " *" : "")
        chp_str  = "$(b.chp)->$(a.chp)"  * (a.chp != b.chp ? " *" : "")
        ocgt_str = "$(b.ocgt)->$(a.ocgt)" * (a.ocgt != b.ocgt ? " *" : "")

        println(rpad(zone, 12), rpad(ccgt_str, 16), rpad(chp_str, 16), rpad(ocgt_str, 16))

        total_ccgt_b += b.ccgt; total_chp_b += b.chp; total_ocgt_b += b.ocgt
        total_ccgt_a += a.ccgt; total_chp_a += a.chp; total_ocgt_a += a.ocgt
    end

    println("-" ^ 60)
    println(rpad("TOTAL", 12),
            rpad("$(total_ccgt_b)->$(total_ccgt_a)", 16),
            rpad("$(total_chp_b)->$(total_chp_a)", 16),
            rpad("$(total_ocgt_b)->$(total_ocgt_a)", 16))
    println("=" ^ 80)
end

run_comparison()
