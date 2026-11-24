# st-impact: build_baseline's new clear_resolution_minutes kwarg (default 60) leaves the 24-step baseline unchanged.
# env DAYS. PASS: build_baseline(d; save=false) prices == cached baseline prices, every cell.
using Euphemia, Dates, Printf, Test
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
@testset "build_baseline default resolution == cache" begin
    for d in Date.(split(ENV["DAYS"], ","))
        c = load_baseline(d); b = build_baseline(d; save=false)
        n = sum(length(v) for v in values(c.prices))
        ex = count(c.prices[z][p] == b.prices[z][p] for z in keys(c.prices) for p in keys(c.prices[z]) if haskey(b.prices, z) && haskey(b.prices[z], p))
        @printf("RESDEF %s periods=%d exact %d/%d\n", d, length(b.book.periods), ex, n); flush(stdout)
        @test ex == n
    end
end
