# Validation script for CCGT/OCGT gas classification
#
# Queries actual generation data for gas plants classified as CCGT vs OCGT
# and compares dispatch patterns (capacity factor, run duration, starts/week).
#
# Expected: OCGTs show lower capacity factors, shorter runs, and more starts.
#
# Usage:
#   julia --project=. test/scripts/validate_gas_classification.jl

using Dates
include(joinpath(@__DIR__, "..", "..", "src", "Euphemia.jl"))
using .Euphemia

function validate_gas_classification(zones::Vector{String}, date::Date)
    println("=" ^ 70)
    println("Gas CCGT/OCGT Classification Validation")
    println("Reference date: $date")
    println("Threshold: $(GAS_OCGT_CAPACITY_THRESHOLD_MW) MW")
    println("=" ^ 70)
    println()

    for zone in zones
        println("─" ^ 50)
        println("Zone: $zone")
        println("─" ^ 50)

        gens = try
            get_generators(zone, date; exclude_variable_renewables=true)
        catch e
            println("  ⚠ Failed to load generators: $e")
            continue
        end

        # Split gas generators
        ccgt = filter(g -> g.fuel_type == Symbol("Fossil Gas"), gens)
        ocgt = filter(g -> g.fuel_type == Symbol("Fossil Gas OCGT"), gens)

        if isempty(ccgt) && isempty(ocgt)
            println("  No gas generators found")
            continue
        end

        println("  CCGT (>$(GAS_OCGT_CAPACITY_THRESHOLD_MW) MW): $(length(ccgt)) plants")
        println("  OCGT (≤$(GAS_OCGT_CAPACITY_THRESHOLD_MW) MW): $(length(ocgt)) plants")
        println()

        for (label, group) in [("CCGT", ccgt), ("OCGT", ocgt)]
            if isempty(group)
                continue
            end

            println("  [$label] Analyzing $(length(group)) plants...")

            total_capacity = sum(g.p_max for g in group)
            avg_capacity = total_capacity / length(group)
            min_cap = minimum(g.p_max for g in group)
            max_cap = maximum(g.p_max for g in group)

            println("    Capacity: avg=$(round(avg_capacity, digits=0)) MW, range=$(round(min_cap, digits=0))-$(round(max_cap, digits=0)) MW, total=$(round(total_capacity, digits=0)) MW")

            # Sample up to 5 plants for dispatch analysis
            sample = group[1:min(5, length(group))]
            cap_factors = Float64[]
            run_durations = Float64[]
            starts_per_week = Float64[]

            for gen in sample
                hist = try
                    Euphemia.get_historical_generation(gen.code, date; months_back=3)
                catch
                    continue
                end

                if nrow(hist) < 100
                    continue
                end

                sort!(hist, :date_time_utc)
                values = hist.actual_generation_output_mw

                # Capacity factor
                cf = mean(filter(v -> v > 0, values)) / gen.p_max
                push!(cap_factors, cf)

                # Count starts and run durations
                is_on = values .> 1.0
                n_starts = 0
                current_run = 0
                runs = Float64[]

                for i in 1:length(is_on)
                    if is_on[i]
                        if i == 1 || !is_on[i-1]
                            n_starts += 1
                            current_run = 1
                        else
                            current_run += 1
                        end
                    else
                        if current_run > 0
                            res_min = Euphemia.parse_resolution_to_minutes(hist.resolution_code[1])
                            push!(runs, current_run * res_min / 60.0)
                            current_run = 0
                        end
                    end
                end
                if current_run > 0
                    res_min = Euphemia.parse_resolution_to_minutes(hist.resolution_code[1])
                    push!(runs, current_run * res_min / 60.0)
                end

                # Normalize starts to per week
                total_hours = nrow(hist) * Euphemia.parse_resolution_to_minutes(hist.resolution_code[1]) / 60.0
                weeks = total_hours / (7 * 24)
                if weeks > 0
                    push!(starts_per_week, n_starts / weeks)
                end

                if !isempty(runs)
                    push!(run_durations, Statistics.mean(runs))
                end
            end

            if !isempty(cap_factors)
                println("    Avg capacity factor: $(round(Statistics.mean(cap_factors) * 100, digits=1))%")
            end
            if !isempty(run_durations)
                println("    Avg run duration: $(round(Statistics.mean(run_durations), digits=1)) hours")
            end
            if !isempty(starts_per_week)
                println("    Avg starts/week: $(round(Statistics.mean(starts_per_week), digits=1))")
            end

            # Show marginal cost
            mc = group[1].marginal_cost
            println("    Marginal cost: $(round(mc, digits=1)) EUR/MWh")
            println()
        end
    end
end

# Run validation
zones = try
    get_available_zones(Date(2024, 6, 15))
catch
    ["GR", "BG", "RO", "HU"]
end

validate_gas_classification(zones, Date(2024, 6, 15))
