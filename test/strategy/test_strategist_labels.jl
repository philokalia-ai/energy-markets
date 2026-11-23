# st-impact: the strategist hook keeps storage families when it returns (order, tag, strategy) triples.
# env DAYS (comma list, cached baseline days), ZONES (default the 6 study zones). Run in the baseline env
# (research/strategy/impact/rd.sh with SCRIPT=test/strategy/test_strategist_labels.jl).
# PASS: a no-op strategist returning triples reproduces the cached baseline prices exactly (all 39 zones x 24 h).
# Also prints the size of the pre-fix behaviour: the same no-op returning (order, tag) pairs.
using Euphemia, Dates, Printf, Test
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "research", "strategy", "impact", "mk_lib.jl"))
zones = !isempty(get(ENV, "ZONES", "")) ? String.(split(ENV["ZONES"], ",")) : STUDY_ZONES
function cmp(a, b)
    d = [abs(a[z][p] - b[z][p]) for z in keys(b) for p in keys(b[z]) if haskey(a, z) && haskey(a[z], p)]
    n = sum(length(v) for v in values(b))
    return (n=n, cells=length(d), exact=count(==(0.0), d), mae=sum(d) / length(d), maxd=maximum(d))
end
@testset "strategist keeps storage families" begin
    for d in Date.(split(ENV["DAYS"], ","))
        base = load_baseline(d)
        for (lab, trip) in (("fixed(triples)", true), ("prefix(pairs)", false))
            sc = Dict(z => ZoneScenario(strategist=noop_strategist(trip)) for z in zones)
            p, pass = build_with_scenario(d, sc; footprint=FOOTPRINT)
            c = cmp(p, base.prices)
            zz = [cmp(Dict(z => p[z]), Dict(z => base.prices[z])) for z in zones if haskey(p, z)]
            @printf("STRAT %s %-15s pass=%d cells %d/%d exact=%d mae=%.4f max=%.3f | study zones mae=%.3f max=%.3f\n",
                d, lab, pass, c.cells, c.n, c.exact, c.mae, c.maxd, sum(x.mae for x in zz) / length(zz),
                maximum(x.maxd for x in zz))
            flush(stdout)
            trip && @test c.exact == c.n
        end
    end
end
