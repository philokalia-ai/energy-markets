# cv46 P3a Italian unit gas efficiency (src/merit_order/cv46_it_eff.jl). DB-free, < 1 s.
using Test
using Euphemia
using Dates

const _MOB = Euphemia.MeritOrderBook

@testset "cv46 P3a IT_EFF" begin
    ttf, eua = 31.7, 74.2
    @testset "formula = get_marginal_cost's at the fleet efficiency (bitwise)" begin
        for hhv in (true, false)
            fleet = Euphemia._gas_fuel_cost(ttf, Euphemia.GAS_PLANT_EFFICIENCY, hhv) +
                    Euphemia.GAS_EMISSION_FACTOR / Euphemia.GAS_PLANT_EFFICIENCY * eua + Euphemia.GAS_VOM_COST
            @test _MOB.cv46_gas_mc_at_efficiency(ttf, eua, Euphemia.GAS_PLANT_EFFICIENCY, hhv) === fleet
        end
        @test _MOB.cv46_gas_mc_at_efficiency(ttf, eua, 0.46, true) > _MOB.cv46_gas_mc_at_efficiency(ttf, eua, 0.57, true)
    end

    @testset "shipped crosswalk" begin
        t = _MOB.cv46_it_eff_load()
        @test length(t) == 9          # ppm v0.9.1: Mincio 2, Porto Corsini 3/4, Gissi 1/2, Rizziconi 1/2, Sparanise 1/2
        @test all(0.45 .<= values(t) .<= 0.64)                   # CCGT plausibility band
        @test t["26WUUUUUUGISSI19"] == 0.57
        @test t["26WUURIZZICONI1S"] == 0.56
        @test !haskey(t, "26WUUMONCALRPW2S")                     # Moncalieri: CHP excluded
        @test !haskey(t, "26WUUUUUULEINI1V")                     # Leini: CHP excluded
    end

    @testset "malformed crosswalk is an error" begin
        p = tempname()
        write(p, "generation_unit_code,ppm_efficiency,status\nA,0.5,use\nB,0.5\n")
        @test_throws ErrorException _MOB.cv46_it_eff_load(p)
        write(p, "generation_unit_code,ppm_efficiency,status\nA,1.5,use\n")
        @test_throws ErrorException _MOB.cv46_it_eff_load(p)
        write(p, "generation_unit_code,ppm_efficiency,status\nA,0.5,use\nA,0.6,use\n")
        @test_throws ErrorException _MOB.cv46_it_eff_load(p)
        write(p, "generation_unit_code,ppm_efficiency,status\nA,0.5,use\nB,,excluded_chp\n")
        @test _MOB.cv46_it_eff_load(p) == Dict("A" => 0.5)
        rm(p)
    end

    @testset "reprice" begin
        G = Euphemia.Generator
        fleet = _MOB.cv46_gas_mc_at_efficiency(ttf, eua, Euphemia.GAS_PLANT_EFFICIENCY, true)
        gas_doc = G("U1", "UP_ONE", Symbol("Fossil Gas"), "x", 400.0, 160.0, "IT-NORTH", fleet)
        gas_undoc = G("U2", "UP_TWO", Symbol("Fossil Gas"), "x", 300.0, 120.0, "IT-NORTH", fleet)
        other_doc = G("U3", "UP_THREE", Symbol("Other"), "x", 200.0, 0.0, "IT-NORTH", 99.0)
        gens = [gas_doc, gas_undoc, other_doc]
        tab = Dict("U1" => 0.46, "U3" => 0.60)
        r = _MOB.cv46_it_eff_reprice(gens, "IT-NORTH", Date(2026, 10, 19); table=tab, ttf=ttf, eua=eua, hhv=true, verbose=false)
        @test r[1].marginal_cost === _MOB.cv46_gas_mc_at_efficiency(ttf, eua, 0.46, true)
        @test r[1].marginal_cost > fleet
        @test (r[1].p_max, r[1].p_min, r[1].code, r[1].fuel_type) == (400.0, 160.0, "U1", Symbol("Fossil Gas"))
        @test r[2] === gas_undoc && r[3] === other_doc           # untouched objects
        @test gens[1] === gas_doc && gas_doc.marginal_cost === fleet   # input never mutated
        # outside Italy / no TTF close: the same vector back
        @test _MOB.cv46_it_eff_reprice(gens, "DE_LU", Date(2026, 10, 19); table=tab, ttf=ttf, eua=eua, hhv=true) === gens
        @test _MOB.cv46_it_eff_reprice(gens, "IT-NORTH", Date(2026, 10, 19); table=tab, ttf=nothing, eua=eua, hhv=true) === gens
        # a unit at exactly the fleet efficiency is repriced to the bitwise-identical fleet cost
        r2 = _MOB.cv46_it_eff_reprice(gens, "IT-NORTH", Date(2026, 10, 19);
                                      table=Dict("U1" => Euphemia.GAS_PLANT_EFFICIENCY), ttf=ttf, eua=eua, hhv=true, verbose=false)
        @test r2[1].marginal_cost === fleet
    end
end
