# cv46: the 15-minute clear is the product default (CLEAR_RESOLUTION_MINUTES).
# DB-free: the resolution guards fire before any data access.
using Test
using Dates
using Euphemia

@testset "cv46 clear resolution" begin
    @test Euphemia.CLEAR_RESOLUTION_MINUTES == 15
    @test 1440 ÷ Euphemia.CLEAR_RESOLUTION_MINUTES == 96

    # a resolution that does not divide the hour is refused up front, on both
    # entry points (before any book build, DB read or worker start)
    @test_throws ErrorException Euphemia.run_multi_zone_market_clearing(Date(2026, 11, 13);
        zones=["GR", "BG"], clear_resolution_minutes=7)
    @test_throws ErrorException Euphemia.run_pipelined_backfill([Date(2026, 11, 13)], ["GR", "BG"];
        clear_resolution_minutes=45, save_to_db=false)

    # flat intra-hour storage is unconditional: no source file reads the old env
    src = joinpath(pkgdir(Euphemia), "src")
    readers = String[]
    for (root, _, files) in walkdir(src), f in files
        endswith(f, ".jl") || continue
        p = joinpath(root, f)
        occursin("\"EUPHEMIA_PS_INTRAHOUR\"", read(p, String)) && push!(readers, relpath(p, src))
    end
    @test isempty(readers)
end
