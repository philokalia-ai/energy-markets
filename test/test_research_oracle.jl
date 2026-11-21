using Test, Dates, Euphemia
using Euphemia.MarketOrders: SimpleOrder, LinkedHourlyOrder, MarketOrder

@testset "Research opt-in and retired arms" begin
    cfg(env; backend=:duckdb, read_only=true) = Euphemia.research_oracle(env; backend, read_only)
    @test cfg(Dict()) === nothing
    for flag in Euphemia.ORACLE_FLAGS
        env = Dict(flag => "on")
        @test_throws ErrorException cfg(env)
        env["EUPHEMIA_RESEARCH_ORACLE"] = "1"
        @test cfg(env) === nothing
        env["EUPHEMIA_ORACLE_ZONES"] = " A, B,A "
        @test cfg(env).zones == Set(["A", "B"])
        @test_throws ErrorException cfg(env; backend=:postgres)
        @test_throws ErrorException cfg(env; read_only=false)
        @test flag in Euphemia.ORACLE_ENV
    end
    for flag in Euphemia.RETIRED_ORACLE_FLAGS
        @test_throws ErrorException cfg(Dict(flag => "on"))
    end
end

@testset "Missing inputs fall back by zone, hour and arm" begin
    mob = Euphemia.MeritOrderBook
    cfg = (; hydro_energy=true, fund=true)
    gen = Dict("Hydro Water Reservoir" => Dict(0=>20.0, 2=>5.0),
               "Hydro Run-of-river and pondage" => Dict(0=>3.0, 1=>0.0),
               "Hydro Pumped Storage" => Dict(0=>99.0),
               "Solar" => Dict(0=>0.0, 2=>2.5))
    q = mob._oracle_quantities(cfg, gen, Dict(0=>40.0, 1=>45.0, 2=>50.0))
    empty_q = mob._oracle_quantities(cfg, empty(gen), Dict{Int,Float64}())
    @test isempty(empty_q.fund) && isempty(empty_q.river) && isempty(empty_q.reservoir)
    zones = Dict("Z"=>q, "Y"=>empty_q)
    @test mob._oracle_fallback_counts(zones, cfg) == (; hydro_energy=47, river=46, reservoir=46, fund=46)
    slots = ["20260101-0000", "20260101-0100", "20260101-0200"]
    @test mob.oracle_fixed(zones, ["Z", "Y", "X"], slots) == Dict(("Z",first(slots))=>3.0)
    @test haskey(q.river, 1) && !haskey(q.river, 2)
    load = Dict(t=>100.0 for t in slots)
    res = Dict(t=>10.0 for t in slots)
    solar = Dict(0=>[8.0], 1=>[9.0])
    mob._apply_oracle_fund!(slots, load, res, solar, q.fund, Date(2026,1,1), 15)
    @test load["20260101-0100"] == 100.0 && res["20260101-0100"] == 10.0
    @test solar[1] == [9.0] && solar[0] == [0.0]
    @test load["20260101-0245"] == 50.0 && res["20260101-0245"] == 2.5
    @test first(slots) == "20260101-0000" && length(slots) == 9
    delete!(gen, "Solar")
    @test mob._oracle_quantities(cfg, gen, Dict(0=>40.0)).fund[0].res == 0.0
end

@testset "Observed reservoir energy constrains priced offers across hours" begin
    mob = Euphemia.MeritOrderBook
    day = Date(2026,1,1)
    times = DateTime(day) .+ Hour.(0:2)
    slots = Dates.format.(times, "yyyymmdd-HHMM")
    gen = Euphemia.Generator("R", "Reservoir", Symbol("Hydro Water Reservoir"), "", 100.0, 0.0, "Z", 10.0)
    # One member in each observed hour, plus a spill tranche and an unrelated unit.
    tagged = [(SimpleOrder(:supply, 10.0, 100.0, :Z, t, 60), "R") for t in times]
    push!(tagged, (SimpleOrder(:supply, 2.0, 5.0, :Z, times[1], 60), "R"),
                  (SimpleOrder(:supply, 12.0, 6.0, :Z, times[1], 60), "PS"))
    strategies = ["water_value_reservoir", "water_value_anchored", "water_value_reservoir",
                  "water_value_spill", "water_value_gas_anchored"]
    withenv("EUPHEMIA_COMPLEX_ORDERS"=>"off") do
        split(energy, grid=slots, minutes=60) = mob._split_storage_families(tagged,
            strategies, [gen], "Z", day, :reservoir_opportunity, grid, minutes; reservoir=energy)
        energy = Dict(0=>40.0, 1=>0.0)
        f = "ERES:observed:Z"
        keep, members, budgets = split(energy)
        @test keep == [false, false, true, false, true]
        @test budgets == Dict(f=>40.0)
        @test first.(members) == first.(tagged[.!keep])
        @test split(Dict(0=>0.0))[3][f] == 0.0
        @test all(first(split(empty(energy))))
        @test split(energy, ["20260101-0000","20260101-0015","20260101-0100"], 15)[3][f] == 20.0

        # The first hour observed all 40 MWh. The master can spend them in the
        # second hour against dearer gas, preserving reservoir bids for repricing.
        orders = MarketOrder[LinkedHourlyOrder(:supply, o.price, o.quantity, o.zone,
            o.date_time, o.resolution_code, family, budgets[family]) for (o,family) in members]
        for (t, price) in zip(times[1:2], [5.0, 90.0])
            push!(orders, SimpleOrder(:demand, 3000.0, 40.0, :Z, t, 60),
                  SimpleOrder(:supply, price, 100.0, :Z, t, 60))
        end
        mp = Euphemia.MPCC
        book = mp.MPCCOrderBook(orders, ["Z"], slots[1:2], (-500.0,3000.0), nothing)
        priced = mp.resolve_complex_orders(book; preferred_solver="highs", verbose=false)
        @test isempty(priced.fixed_injections)
        @test any(o -> o.price == 10.0 && o.date_time == times[2] && o.quantity ≈ 40.0, priced.orders)
        @test mp.LAST_COMPLEX_INFO[].families[f]["used"] ≈ 40.0
    end
end
