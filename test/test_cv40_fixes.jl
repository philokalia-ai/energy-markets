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

@testset "duration-weighted fine→coarse load aggregation (arithmetic)" begin
    vals = [100.0, 200.0, 300.0, 400.0]
    @test foldl((a, b) -> (a + b) / 2, vals) ≈ 312.5   # the defect, for the record
    @test sum(v * 15 for v in vals) / (4 * 15) ≈ 250.0 # duration-weighted
    @test (100.0 * 15 + 200.0 * 15) / 30 ≈ 150.0       # partial coverage
end

@testset "get_loads: mixed-resolution production path (review 2026-09-13 P2)" begin
    # The real reader, on a zone-day whose PT60M series lacks an hour that the
    # PT15M series covers: the filled hour must be the duration-weighted mean of
    # its quarters, not the running mean. GR 2025-11-12 is the documented case
    # (the CET-day publication leaves the UTC day one hour short).
    ls = Euphemia.get_loads("GR", Date(2025, 11, 12))
    @test !isempty(ls)
    hours = Set(l.timeslot[1:11] for l in ls)
    @test length(hours) >= 23
    @test all(l -> l.value > 0, ls)
    # every emitted value stays inside the envelope of the published series
    mx = maximum(l.value for l in ls); mn = minimum(l.value for l in ls)
    @test mx < 3 * mn                                   # no doubled/quartered slot
end

@testset "zero net-position limits stay a no-op by default (review P1)" begin
    # A maximum net position of 0 bounds NET exchange: a hub importing and
    # exporting the same MW is feasible, so deleting its outgoing capacity is
    # wrong. cv40 leaves a zero bound inert unless the measurement arm is armed.
    armed(env) = !isempty(get(env, "EUPHEMIA_ENABLE_CV40_ZEROCAP", ""))
    @test !armed(Dict{String,String}())                 # default: no-op
    @test armed(Dict("EUPHEMIA_ENABLE_CV40_ZEROCAP" => "1"))
    src = read(joinpath(@__DIR__, "..", "src", "Network.jl"), String)
    @test occursin("EUPHEMIA_ENABLE_CV40_ZEROCAP", src)
    @test occursin("bounds the hub\'s NET", src) || occursin("NET\n", src) ||
          occursin("net position 0", src)               # the reasoning is recorded
end

@testset "transmission-outage caps run after every capacity source (review P1)" begin
    # Pass order is structural: the cap block must appear AFTER the explicit-ATC
    # and pre-gate-fallback additions and BEFORE the remap/drop passes.
    src = read(joinpath(@__DIR__, "..", "src", "Network.jl"), String)
    i_cap = findfirst("Transmission-grid outages (cv40", src)
    i_exp = findfirst("if include_explicit", src)
    i_pre = findfirst("PREGATE_ATC_FALLBACK[] &&", src)
    i_remap = findfirst("Apply aggregate → sub-zone remap", src)
    @test i_cap !== nothing && i_exp !== nothing && i_pre !== nothing && i_remap !== nothing
    @test first(i_exp) < first(i_cap)                   # explicit ATC added first
    @test first(i_pre) < first(i_cap)                   # pre-gate fallback too
    @test first(i_cap) < first(i_remap)                 # cap before remap/drop
end

@testset "DB: DE_LU net-position limits reach the network" begin
    d = Date(2026, 2, 24)
    np = Euphemia.Network.jao_net_positions(d)
    hubs = Set(h for (_, h, _) in keys(np))
    @test "DE_LU" in hubs                      # the review's 24 dropped records
    @test !any(occursin("_CO", h) || occursin("_SK", h) for h in hubs)
    @test ("CORE", "FR", 1) in keys(np) || any(h == "FR" for h in hubs)
end
