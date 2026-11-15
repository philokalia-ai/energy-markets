# A negative offered capacity must not become an infeasible flow bound.
# ENTSO-E published DK1->NL Day-ahead = -700 MW for 2026-09-01 22:00..09-02 21:45
# (TSO outage, new NTC 0). Unfloored, flow[DK1,NL] got ub = -700 < lb = -backward
# and HiGHS reported every such period INFEASIBLE, so the days could not clear.
# DB-free. Standalone: julia --project=. test/test_negative_atc.jl
using Test, Euphemia, DataFrames
const NW = Euphemia.Network

@testset "negative offered capacity is floored at 0" begin
    df = DataFrame(source_zone = ["DK1", "NL", "DK1", "NL"],
                   sink_zone   = ["NL", "DK1", "NL", "DK1"],
                   time_period = [4, 4, 10, 10],
                   capacity    = [-700.0, 550.0, -700.0, 700.0])
    tc = @test_logs (:warn, r"2 negative offered") NW.build_transfer_capacity_from_dataframe(df)
    # the hour that was infeasible (backward 550 < 700) and the one that was
    # pinned at a fictitious 700 MW NL->DK1 import (backward 700)
    for p in ("4", "10")
        f = tc.capacity_forward[("DK1", "NL", p)]
        b = tc.capacity_backward[("DK1", "NL", p)]
        @test f == 0.0
        @test -b <= f                       # a non-empty flow interval
    end
    @test tc.capacity_backward[("DK1", "NL", "4")] == 550.0
    @test tc.capacity_forward[("NL", "DK1", "10")] == 700.0
    # non-negative inputs pass through untouched, without a warning
    ok = DataFrame(source_zone = ["A", "B"], sink_zone = ["B", "A"],
                   time_period = [1, 1], capacity = [0.0, 300.0])
    tc2 = @test_logs NW.build_transfer_capacity_from_dataframe(ok)
    @test tc2.capacity_forward[("A", "B", "1")] == 0.0
    @test tc2.capacity_forward[("B", "A", "1")] == 300.0
end
