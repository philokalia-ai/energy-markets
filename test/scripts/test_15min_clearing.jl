#!/usr/bin/env julia
# Acceptance guards for the 15-minute coupled multi-zone clear (INCREMENT 1).
#
# Runs against the public DuckDB extract with a MILP solver (Gurobi recommended):
#
#   GRB_LICENSE_FILE=/path/to/gurobi.lic \
#   EUPHEMIA_DATA_STORE=duckdb \
#   EUPHEMIA_DUCKDB_PATH=data/public/euphemia-public.duckdb \
#     julia --project=. test/scripts/test_15min_clearing.jl
#
# Guards:
#   1. REDUCES-TO-HOURLY (the correctness proof). On a footprint whose zones are
#      ALL natively hourly (BG, RS — both load and renewables PT60M on the test
#      day), the 96-period 15-min clear must yield 4 IDENTICAL quarter prices per
#      hour, each equal to the 24-period hourly clear's price for that hour, to
#      ~1e-9 €/MWh. Replication makes each quarter's clearing problem identical
#      to the hourly one — including the coupled RS↔BG flow, whose hourly ATC cap
#      is replicated to all 4 quarters. Any failure here means divide-instead-of-
#      replicate or a period-grid misalignment.
#   2. NATIVE-15 SANITY. On a footprint containing native-15 zones (GR), the
#      15-min clear must show intra-hour price variation, and the mean of each
#      hour's 4 quarter prices should be close to (not equal to) the 60-min clear.

using Euphemia, Dates, Printf, Statistics, Test

const OPT = get(ENV, "EUPHEMIA_TEST_OPTIMIZER", "gurobi")
const DAY = Date(2026, 4, 3)
clear(zs, res) = run_multi_zone_market_clearing(DAY; zones=zs,
    order_method=:merit_order, optimizer=OPT, enrich_network=true,
    apply_zone_profiles=true, save_to_db=false, silent=true,
    clear_resolution_minutes=res)

hourof(p) = parse(Int, p[10:11])

@testset "15-min coupled clear" begin
    @testset "reduces-to-hourly (fully-hourly footprint BG,RS)" begin
        zs = ["BG", "RS"]
        r60 = clear(zs, 60)
        r15 = clear(zs, 15)
        maxeq = 0.0    # max |quarter - hourly|
        maxintra = 0.0 # max |quarter - first quarter of its hour|
        for z in zs
            href = Dict(hourof(k) => v for (k, v) in r60.market_prices[z])
            @test length(href) == 24
            @test length(r15.market_prices[z]) == 96
            byhr = Dict{Int,Vector{Float64}}()
            for (k, v) in r15.market_prices[z]
                push!(get!(byhr, hourof(k), Float64[]), v)
            end
            for h in 0:23
                qs = byhr[h]
                @test length(qs) == 4
                for q in qs
                    maxeq = max(maxeq, abs(q - href[h]))
                    maxintra = max(maxintra, abs(q - qs[1]))
                end
            end
        end
        @printf("   reduces-to-hourly max|quarter-hourly| = %.3e €/MWh\n", maxeq)
        @printf("   intra-hour spread  max|quarter-quarter| = %.3e €/MWh\n", maxintra)
        @test maxeq <= 1e-9
        @test maxintra <= 1e-9
    end

    @testset "native-15 intra-hour variation (GR present)" begin
        zs = ["GR", "BG", "RS"]
        r60 = clear(zs, 60)
        r15 = clear(zs, 15)
        p15 = r15.market_prices["GR"]
        href = Dict(hourof(k) => v for (k, v) in r60.market_prices["GR"])
        byhr = Dict{Int,Vector{Float64}}()
        for (k, v) in p15
            push!(get!(byhr, hourof(k), Float64[]), v)
        end
        varying = count(h -> (maximum(byhr[h]) - minimum(byhr[h])) > 1e-6, 0:23)
        agg_mae = mean(abs(mean(byhr[h]) - href[h]) for h in 0:23)
        @printf("   GR hours with intra-hour spread = %d/24; 15→hourly-mean MAE vs 60 = %.2f €/MWh\n",
            varying, agg_mae)
        @test varying > 0                 # genuine sub-hourly structure
        @test agg_mae < 25.0              # close, but not identical (Jensen)
    end
end
