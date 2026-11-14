using Test
using Euphemia

@testset "JAO scaling uses original capacities and is order independent" begin
    row(s, d, mw) = (source_zone=s, sink_zone=d, time_period=1, capacity=Float64(mw))
    original = [row("A", "B", 100), row("A", "C", 100), row("D", "B", 100),
                row("E", "B", 500), row("A", "F", 0)]
    jao = Set([("A", "B", 1), ("A", "C", 1), ("D", "B", 1), ("A", "F", 1)])
    pairs = [("A", "B"), ("A", "C"), ("D", "B"), ("E", "B"), ("A", "F")]
    footprint = Set(["A", "B", "C", "D", "E", "F"])
    limits = [("CORE", "A", 1) => (-1000.0, 100.0),
              ("CORE", "B", 1) => (-80.0, 1000.0)]
    capacities(rows) = Dict((r.source_zone, r.sink_zone) => r.capacity for r in rows)
    expected = Dict(("A", "B") => 40.0, ("A", "C") => 50.0,
                    ("D", "B") => 40.0, ("E", "B") => 500.0, ("A", "F") => 0.0)
    for hub_limits in (limits, reverse(limits)), borders in (pairs, reverse(pairs)),
        input_rows in (original, reverse(original))
        rows = copy(input_rows)
        count = Euphemia.Network._scale_jao_net_positions!(
            rows, hub_limits, Dict("CORE" => Set(borders)), jao, footprint)
        @test count == 4
        @test capacities(rows) == expected
        @test sum(r.capacity for r in rows if r.source_zone == "A") <= 100.0
        @test sum(r.capacity for r in rows if r.sink_zone == "B" &&
                  (r.source_zone, r.sink_zone, 1) in jao) <= 80.0
    end
    # A second CCR contributes another factor; factors are not multiplied.
    rows = copy(original)
    Euphemia.Network._scale_jao_net_positions!(rows,
        vcat(limits, [("OTHER", "A", 1) => (-1000.0, 20.0)]),
        Dict("CORE" => Set(pairs), "OTHER" => Set([("A", "B")])), jao, footprint)
    @test capacities(rows)[("A", "B")] == 20.0
    @test capacities(rows)[("A", "C")] == 50.0
    # Preserve default zero-bound no-op and opt-in gross-capacity zeroing.
    for enabled in (false, true)
        rows = copy(original)
        Euphemia.Network._scale_jao_net_positions!(rows,
            [("CORE", "A", 1) => (-1000.0, 0.0)],
            Dict("CORE" => Set(pairs)), jao, footprint; enable_zero_cap=enabled)
        @test capacities(rows)[("A", "B")] == (enabled ? 0.0 : 100.0)
        @test capacities(rows)[("E", "B")] == 500.0
    end
    rows = copy(original)
    @test Euphemia.Network._scale_jao_net_positions!(rows,
        [("CORE", "A", 1) => (-1000.0, 1000.0)],
        Dict("CORE" => Set(pairs)), jao, footprint) == 0
    @test rows == original
end
