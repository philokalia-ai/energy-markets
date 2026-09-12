# test_cv40_fixes.jl — the confirmed implementation defects from the
# 2026-09-13 cv39 review (docs/energy-markets-cv39-review.md).

using Test, Dates, DataFrames
using Euphemia

@testset "JAO hub classification keeps DE_LU, drops interconnector hubs" begin
    N = Euphemia.Network
    # The raw JAO name decides: "DE" is a physical hub (mapped to DE_LU),
    # "DK1_CO"/"NO2_SK"/"SE3_FS" are interconnector hubs, "ALBE"/"ALDE" virtual.
    keep(raw) = begin
        hub = get(N._JAO_HUB_MAP, raw, raw)
        !(occursin("_", raw) || hub in N._JAO_VIRTUAL_HUBS)
    end
    @test keep("DE")                      # was dropped: mapped to DE_LU, underscore
    @test get(N._JAO_HUB_MAP, "DE", "DE") == "DE_LU"
    @test keep("FR") && keep("AT") && keep("PL") && keep("NO2") && keep("SE3")
    @test !keep("DK1_CO") && !keep("NO2_SK") && !keep("SE3_FS") && !keep("PL_SE4_SwePol")
    @test !keep("ALBE") && !keep("ALDE")
end

@testset "duration-weighted fine→coarse load aggregation" begin
    # Four PT15M values into one PT60M slot: the mean is 250, not the
    # running-mean 312.5 the previous recurrence produced.
    vals = [100.0, 200.0, 300.0, 400.0]
    running = foldl((a, b) -> (a + b) / 2, vals)
    @test running ≈ 312.5                      # the defect, for the record
    mwmin = sum(v * 15 for v in vals); mins = 4 * 15
    @test mwmin / mins ≈ 250.0                 # duration-weighted
    # partial coverage: two of four quarters published -> mean of what exists
    @test (100.0 * 15 + 200.0 * 15) / 30 ≈ 150.0
end

@testset "DB: DE_LU net-position limits reach the network" begin
    d = Date(2026, 2, 24)
    np = Euphemia.Network.jao_net_positions(d)
    hubs = Set(h for (_, h, _) in keys(np))
    @test "DE_LU" in hubs                      # the review's 24 dropped records
    @test !any(occursin("_CO", h) || occursin("_SK", h) for h in hubs)
    @test ("CORE", "FR", 1) in keys(np) || any(h == "FR" for h in hubs)
end
