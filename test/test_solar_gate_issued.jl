# cv31 solar-regime share on the weather track: the issued (typed) weather
# solar drives the gate regardless of which TSO RES rows exist for the hour
# (PR #401 review, P2 — the reviewer's three-case repro). With no issued solar
# the pre-existing TSO-row rule is unchanged.
#
# Standalone:  julia --project=. test/test_solar_gate_issued.jl

using Test
using Euphemia

@testset "solar-regime share: issued weather solar independent of TSO coverage" begin
    MOB = Euphemia.MeritOrderBook
    RGF = Euphemia.RenewablesGenerationForecast
    share = MOB._solar_share_by_hour
    ts = "20260920-1200"
    load = Dict(ts => 100.0)
    issued = Dict(12 => [50.0])                 # issued solar / load = 0.50
    # (1) no TSO rows
    @test share(RGF[], load, issued)[12] ≈ 0.50
    # (2) a wind-only TSO row covers the hour (gap-fill skips the typed rows)
    @test share([RGF(ts, "60", "DE_LU", "Wind Onshore", 30.0)], load, issued)[12] ≈ 0.50
    # (3) a 5-MW TSO solar row covers the hour
    @test share([RGF(ts, "60", "DE_LU", "Solar", 5.0)], load, issued)[12] ≈ 0.50
    # no issued solar ⇒ the pre-existing TSO-row rule (entsoe track / record path)
    @test share([RGF(ts, "60", "DE_LU", "Solar", 5.0)], load)[12] ≈ 0.05
    @test !haskey(share([RGF(ts, "60", "DE_LU", "Wind Onshore", 30.0)], load), 12)
end
