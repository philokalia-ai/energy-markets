# st-impact: inertness of the strategist-label fix — a no-scenario 2-pass rebuild reproduces the cached baseline prices
# exactly (all zones x 24 h). env DAYS (comma). Run in the baseline env (rd.sh SCRIPT=...).
using Euphemia, Dates, Printf, Test
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "research", "strategy", "impact", "mk_lib.jl"))
@testset "no-scenario rebuild == baseline" begin
    for d in Date.(split(ENV["DAYS"], ","))
        b = load_baseline(d)
        p, pass = build_with_scenario(d, nothing; footprint=FOOTPRINT)
        n = sum(length(v) for v in values(b.prices))
        ex = count(b.prices[z][q] == p[z][q] for z in keys(b.prices) for q in keys(b.prices[z]) if haskey(p, z) && haskey(p[z], q))
        @printf("IDENT %s pass=%d exact %d/%d\n", d, pass, ex, n); flush(stdout)
        @test ex == n
    end
end
