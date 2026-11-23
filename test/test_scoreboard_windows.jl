# The "since_freeze" scoreboard window (#431 PR G, bin/scoreboard_windows.jl): the
# cv >= 46 / market_date >= 2026-11-24 filter, per-cohort build, naive fields on the
# window's zone-days only, kill switch, and all-or-nothing failure. Pure, no DB.
#   julia --project=. test/test_scoreboard_windows.jl

using Test, Dates, Statistics, DataFrames

isdefined(@__MODULE__, :athens_market_day_window) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))
isdefined(@__MODULE__, :naive_cohort_fields) ||
    include(joinpath(@__DIR__, "..", "bin", "naive_baselines.jl"))
include(joinpath(@__DIR__, "..", "bin", "scoreboard_windows.jl"))

# A chosen-slice score frame like export_scoreboard's query (z, lead_days, mode,
# market_date, cv, mae).
sc = DataFrame(
    z         = ["GR", "GR", "GR", "GR", "GR", "DE_LU", "DE_LU", "AT"],
    lead_days = [1,    1,    1,    1,    2,    1,       1,       1],
    mode      = fill("weather", 8),
    market_date = Date.(["2026-11-22", "2026-11-23", "2026-11-24", "2026-11-25", "2026-11-25",
                         "2026-11-24", "2026-11-25", "2026-11-25"]),
    cv        = [45,   46,   46,   46,   46,   46,      46,      45],
    mae       = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0,    70.0,    80.0])
build(zone, lead, mode, rows) = (zone=zone, lead=lead, mode=mode,
                                 n_days=length(unique(rows.market_date)), mae=mean(rows.mae))

@testset "since-freeze window (#431 G)" begin
    @test FREEZE_CODE_VERSION == 46 && FREEZE_DATE == Date(2026, 11, 24) && FREEZE_MIN_DAYS == 14
    @test SINCE_FREEZE_WINDOW == "since_freeze"

    @testset "filter: cv >= 46 AND market_date >= 2026-11-24" begin
        f = since_freeze_rows(sc)
        @test nrow(f) == 5
        @test all(f.cv .>= 46) && all(f.market_date .>= Date(2026, 11, 24))
        @test !any((f.z .== "GR") .& (f.market_date .== Date(2026, 11, 23)))   # cv46 but before the freeze
        @test !any(f.z .== "AT")                                               # after the freeze but cv45
    end

    @testset "one entry per cohort, aggregated on the window rows only" begin
        e = withenv(() -> since_freeze_entries(build, sc), "EXPORT_SINCE_FREEZE" => nothing)
        byk = Dict((x.zone, x.lead) => x for x in e)
        @test length(e) == 3                                   # GR/1, GR/2, DE_LU/1; AT absent
        @test byk[("GR", 1)].n_days == 2 && byk[("GR", 1)].mae ≈ 35.0
        @test byk[("GR", 2)].n_days == 1 && byk[("GR", 2)].mae ≈ 50.0
        @test byk[("DE_LU", 1)].n_days == 2 && byk[("DE_LU", 1)].mae ≈ 65.0
        @test !haskey(byk, ("AT", 1))
    end

    @testset "naive fields follow the window's zone-days" begin
        parts = Dict(("GR", 1, "weather", Date(2026, 11, d)) => (n=24, model=240.0 * d, d1=24.0 * d,
                     d7=48.0 * d, epf=24.0 * d) for d in 22:25)
        e = since_freeze_entries(sc) do zone, lead, mode, rows
            naive_cohort_fields(parts, rows)
        end
        gr1 = e[findfirst(x -> x !== nothing && x["n_naive"] == 48, e)]
        @test gr1["n_naive"] == 48                              # 11-24 and 11-25 only
        @test gr1["mae_naive_d1"] ≈ 24.0 * (24 + 25) / 48     # pooled: sum of the two days / 48 hours
        @test gr1["rmae_d1"] ≈ 10.0
    end

    @testset "empty, kill switch, failure (all-or-nothing, never throws)" begin
        @test isempty(since_freeze_entries(build, sc[sc.cv .== 45, :]))
        @test isempty(since_freeze_entries(build, sc[1:0, :]))
        withenv("EXPORT_SINCE_FREEZE" => "0") do
            @test isempty(since_freeze_entries((a...) -> error("must not be called"), sc))
        end
        calls = Ref(0)
        boom(zone, lead, mode, rows) = (calls[] += 1; calls[] == 2 ? error("boom") : build(zone, lead, mode, rows))
        e = @test_logs (:warn, r"since-freeze window failed") match_mode = :any since_freeze_entries(boom, sc)
        @test isempty(e) && calls[] == 2                       # first cohort built, then dropped
        bad = select(sc, Not(:cv))                             # a missing column fails the filter
        @test isempty(@test_logs (:warn, r"since-freeze window failed") match_mode = :any since_freeze_entries(build, bad))
    end
end
