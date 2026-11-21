using Test, Dates, Euphemia

@testset "Guard and exact exchange accounting" begin
    cfg(env; backend=:duckdb, read_only=true) = Euphemia.research_oracle(env; backend, read_only)
    @test cfg(Dict()) === nothing
    for flag in Euphemia.ORACLE_FLAGS
        env = Dict(flag => "on")
        @test_throws ErrorException cfg(env)
        env["EUPHEMIA_RESEARCH_ORACLE"] = "1"
        @test cfg(env) === nothing
        env["EUPHEMIA_ORACLE_ZONES"] = " A, B,A "
        @test cfg(env).zones == Set(["A","B"])
        @test_throws ErrorException cfg(env; backend=:postgres)
        @test_throws ErrorException cfg(env; read_only=false)
    end
    mob = Euphemia.MeritOrderBook
    row(h,a,b,mw) = (; h, out_code=a, in_code=b, mw=Float64(mw))
    rows = [row(0,"A","B",9), row(0,"B","A",2), row(0,"A","C",2),
            row(0,"D","A",3), row(0,"D_IPS","A",3), row(0,"SHADOW","A",99),
            row(1,"A","B",4)]
    hours = BitSet(0:1)
    targets = Set(["A"])
    net = mob._oracle_borders(rows, targets, ["SHADOW"], hours)
    @test hours == BitSet([0])
    @test_throws ErrorException mob._oracle_borders(rows, Set(["Z"]), [], BitSet(0:1))
    zones = ["A","B","C","Z"]
    f = mob._oracle_exchange(net, [("B","A"),("Z","A")], zones, targets, hours)
    @test f.pins[("B","A","1")] == -7
    @test f.pins[("Z","A","1")] == 0
    @test f.total["A"][0] == -6
    @test f.residual["A"][0] == 1    # +3 external, -2 on unmodeled A–C
    @test f.residual["C"][0] == 2
    @test isempty(f.residual["B"])
    period = "20261110-0000"
    day = (; quantities=Dict("A" => (; hydro=Dict(0=>50.0))), flow=f)
    @test mob.oracle_fixed(day, zones, [period]) == Dict(("A",period)=>51.0, ("C",period)=>2.0)
    @test isempty(mob.oracle_fixed(nothing, zones, [period]))
    @test !("Hydro Pumped Storage" in mob.ORACLE_HYDRO_FUELS)
    N = Euphemia.Network
    tc = N.TransferCapacity(zones, ["1"], Dict(("A","B","1")=>25.0), Dict(("A","B","1")=>12.0))
    @test N.flow_bounds(tc,"A","B","1") == (-12.0,25.0)
    tc.pinned_flows[("A","B","1")] = -3
    @test N.flow_bounds(tc,"A","B","1") == (-3.0,-3.0)
end

@testset "Typed actuals, absent technologies and incomplete hours" begin
    mob = Euphemia.MeritOrderBook
    cfg = (; hydro=true, fund=true)
    gen = Dict("Hydro Water Reservoir" => Dict(0=>10.0,1=>11.0,2=>12.0),
               "Hydro Run-of-river and pondage" => Dict(0=>3.0,1=>4.0,2=>5.0),
               "Hydro Pumped Storage" => Dict(0=>99.0),
               "Solar" => Dict(0=>0.0,2=>2.5))
    load = Dict(0=>40.0,1=>45.0,2=>50.0)
    x = mob._oracle_quantities(cfg, "Z", Date(2026,1,1), gen, load)
    @test x.hours == BitSet([0,2])
    @test [x.hydro[h] for h in x.hours] == [13.0,17.0]
    @test [l.value for l in x.fund.loads] == [40.0,50.0]
    @test [r.production_type for r in x.fund.res] == ["Solar","Solar"]
    @test [r.aggregated_generation_forecast for r in x.fund.res] == [0.0,2.5]
    delete!(gen, "Solar")
    x = mob._oracle_quantities(cfg, "Z", Date(2026,1,1), gen, load)
    @test isempty(x.fund.res)
    @test length(x.fund.loads) == 3
end
