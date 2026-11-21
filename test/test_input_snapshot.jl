using Test, Euphemia, Dates, DataFrames

@testset "Frozen input cache boundaries and failure behavior" begin
    calls = Threads.Atomic{Int}(0)
    closed = Ref(0)
    query = (sql,args) -> begin
        Threads.atomic_add!(calls, 1)
        sleep(.02)
        DataFrame(v=[isempty(args) ? 7 : args[1]])
    end
    s = Euphemia.InputSnapshot(query, ["GR"]; revision="fixture:1", captured_at="2026-11-17T00:00:00",
                              cleanup=()->(closed[] += 1))
    Euphemia.with_input_snapshot(s) do
        tasks = [Threads.@spawn Euphemia.sql2df_with_retry("SELECT 7") for _ in 1:16]
        @test all(t -> fetch(t).v == [7], tasks)
        @test calls[] == 1
        df = Euphemia.sql2df("SELECT 7")
        df.v[1] = 100
        @test Euphemia.sql2df("SELECT 7").v == [7]
        # Live backend bypass is exercised against real PG by the integration test.
        @test calls[] == 1
        for issue in (DateTime(2026,9,13,6,30), DateTime(2026,9,14,6,30))
            ctx=Euphemia.ForecastContext(Date(2026,9,15),issue,1,:fixed_10utc,"fixture")
            Euphemia.with_context(ctx) do
                @test Euphemia.sql2df("SELECT 7").v == [7]
            end
        end
        @test calls[] == 3 # context cannot share a cached request from another issuance
        @test Euphemia.sql2df("SELECT param", [1]).v == [1]
        @test Euphemia.sql2df("SELECT param", [2]).v == [2]
    end
    @test Euphemia.CURRENT_INPUT_SNAPSHOT[] === nothing
    Euphemia.close_input_snapshot!(s)
    Euphemia.close_input_snapshot!(s)
    @test closed[] == 1
    @test_throws ErrorException Euphemia.with_input_snapshot(()->nothing,s)

    tiny = Euphemia.InputSnapshot(query,["GR"]; revision="tiny",captured_at="fixture",max_bytes=1)
    Euphemia.with_input_snapshot(tiny) do
        @test Euphemia.sql2df("SELECT 7").v == [7]
        @test Euphemia.sql2df("SELECT 7").v == [7]
        @test tiny.bytes == 0
        @test tiny.misses == 2
    end
    Euphemia.close_input_snapshot!(tiny)

    failed = Euphemia.InputSnapshot((sql,args)->error("fixture read failed"),["GR"];
                                    revision="failed",captured_at="fixture")
    @test_throws ErrorException Euphemia.with_input_snapshot(failed) do
        # Even a legacy loader swallowing its SQL exception cannot authorize a write.
        try Euphemia.sql2df("SELECT bad") catch end
        :fallback
    end
    @test failed.failure !== nothing
    @test failed.misses == 1
    @test_throws ErrorException Euphemia.with_input_snapshot(()->nothing, failed)
    Euphemia.close_input_snapshot!(failed)

    optional_reader = (sql,args) -> occursin("FROM", sql) ?
        throw(Euphemia.DuckDB.QueryException("Catalog Error: Table does not exist")) : DataFrame(v=[8])
    optional = Euphemia.InputSnapshot(optional_reader,["GB"];
                                      revision="optional",captured_at="fixture")
    Euphemia.with_input_snapshot(optional) do
        @test_throws Exception Euphemia.sql2df_optional_input("SELECT price_eur FROM carbon.uka_price", [])
        @test optional.failure === nothing
        @test Euphemia.sql2df("SELECT 8 AS v").v == [8]
    end
    @test_throws Exception Euphemia.with_input_snapshot(optional) do
        try Euphemia.sql2df("SELECT * FROM missing_required_input") catch end
    end
    @test optional.failure !== nothing
    Euphemia.close_input_snapshot!(optional)

    transient = Euphemia.InputSnapshot((sql,args)->error("connection lost"),["GB"];
                                       revision="transient",captured_at="fixture")
    @test_throws Exception Euphemia.with_input_snapshot(transient) do
        try Euphemia.sql2df_optional_input("SELECT price_eur FROM carbon.uka_price", []) catch end
    end
    @test transient.failure !== nothing
    Euphemia.close_input_snapshot!(transient)
end

@testset "One snapshot per chunk; legacy memo invalidation and default off" begin
    created=Ref(0); closed=Ref(0)
    factory = zones -> begin
        created[] += 1
        Euphemia.InputSnapshot((sql,args)->DataFrame(v=[created[]]), zones;
            revision="fixture:$(created[])",captured_at="fixture",cleanup=()->(closed[] += 1))
    end
    Euphemia.with_retro_input_chunk(["GR"],Date(2026,9,14),Date(2026,9,15);factory=factory) do s
        @test s === nothing
    end
    @test created[] == 0
    for _ in 1:2
        Euphemia.TTF_PRICE_CACHE[Date(2026,9,14)] = 999.0
        Euphemia.with_retro_input_chunk(["GR"],Date(2026,9,14),Date(2026,9,15);enabled=true,factory=factory) do s
            @test isempty(Euphemia.TTF_PRICE_CACHE)
            @test Euphemia.CURRENT_INPUT_SNAPSHOT[] === nothing # state/write scope stays live
            for _ in 1:2
                Euphemia.with_input_snapshot(s) do
                    @test Euphemia.sql2df("SELECT v").v == [created[]]
                end
            end
            @test s.misses == 1
        end
    end
    @test created[] == closed[] == 2
end
