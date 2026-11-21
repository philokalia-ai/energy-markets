# test_inmerit_truth.jl — cv43 in-merit truthing merit test (review P1 of #401).
# DB-free: synthetic fuel closes are pre-seeded in the as-of caches (keyed by
# cutoff date), so no query runs. The D−30 side of the merit test must read the
# D−30 closes even inside a ForecastContext, whose own cutoff is the issuance
# date for every requested day.
using Test, Dates
using Euphemia
using Euphemia: with_context, gate_context, get_marginal_cost, legacy_fuel_cutoff

@testset "in-merit truthing — D−30 merit test inside a ForecastContext" begin
    MOB = Euphemia.MeritOrderBook
    d = Date(2026, 11, 2)
    ctx = gate_context(d)                       # issuance D−1 10:00 UTC
    issue_cut = Date(ctx.as_of_utc)             # context cutoff: closes < D−1
    then_cut = legacy_fuel_cutoff(d - Day(30))  # closes < D−31
    @test then_cut < issue_cut
    seeded = (Euphemia.TTF_PRICE_CACHE_ASOF, Euphemia.EUA_PRICE_CACHE_ASOF)
    saved = map(copy, seeded)
    try
        # current: TTF 90 / EUA 80 ⇒ gas 195.02; D−30: TTF 20 / EUA 80 ⇒ gas 67.75.
        # Hard coal = 37 + 0.9·80 = 109 on both dates: in merit now, NOT at D−30.
        Euphemia.TTF_PRICE_CACHE_ASOF[issue_cut] = 90.0
        Euphemia.EUA_PRICE_CACHE_ASOF[issue_cut] = 80.0
        Euphemia.TTF_PRICE_CACHE_ASOF[then_cut] = 20.0
        Euphemia.EUA_PRICE_CACHE_ASOF[then_cut] = 80.0
        gas_now, gas_then, gas_then_naive, coal = with_context(ctx) do
            (get_marginal_cost(d, "Fossil Gas", "DE_LU"),
             get_marginal_cost(d - Day(30), "Fossil Gas", "DE_LU"; cutoff=then_cut),
             get_marginal_cost(d - Day(30), "Fossil Gas", "DE_LU"),   # the P1 bug path
             get_marginal_cost(d, "Fossil Hard coal", "DE_LU"))
        end
        # cv45 GAS_HHV default-on: fuel term TTF/(η·0.90) (cv44: 195.02 / 67.75)
        @test gas_now ≈ 213.20 atol = 0.01
        @test gas_then ≈ 71.79 atol = 0.01
        @test gas_then_naive ≈ gas_now          # documents why the explicit cutoff is needed
        @test coal ≈ 109.0
        # The merit test: coal was out of merit at D−30 ⇒ must NOT be released.
        inmerit = with_context(ctx) do
            MOB._inmerit_types(d, "DE_LU", ["Fossil Hard coal", "Nuclear"])
        end
        @test !("Fossil Hard coal" in inmerit)
        @test "Nuclear" in inmerit              # 10 + 0 < gas on both dates
        # Gas also above coal at D−30 ⇒ released.
        Euphemia.TTF_PRICE_CACHE_ASOF[then_cut] = 85.0
        inmerit2 = with_context(ctx) do
            MOB._inmerit_types(d, "DE_LU", ["Fossil Hard coal"])
        end
        @test inmerit2 == ["Fossil Hard coal"]
        # An explicit cutoff never reaches past issuance.
        @test Euphemia._fuel_cutoff(d) == d                       # no context: as given
        @test with_context(() -> Euphemia._fuel_cutoff(d + Day(5)), ctx) == issue_cut
        @test with_context(() -> Euphemia._fuel_cutoff(then_cut), ctx) == then_cut
    finally
        for (c, s) in zip(seeded, saved)
            empty!(c); merge!(c, s)
        end
    end
end
