# cv44 retro backfill (#431 R1): the alongside write plan and its hard guards, the
# resumable day chunks, the clean-stop deadline, the live-only export predicate and
# the backfilled window wrapper. Pure, no DB (the DB writer test is
# test/scripts/retro_backfill_db_check.jl, run against a private Postgres).
#   julia --project=. test/test_retro_backfill.jl

using Test, Dates, Statistics, DataFrames

isdefined(@__MODULE__, :athens_market_day_window) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))
isdefined(@__MODULE__, :naive_cohort_fields) ||
    include(joinpath(@__DIR__, "..", "bin", "naive_baselines.jl"))
isdefined(@__MODULE__, :backfilled_entries) ||
    include(joinpath(@__DIR__, "..", "bin", "scoreboard_windows.jl"))

@testset "retro backfill (#431 R1)" begin
    @testset "write plan: alongside never skips, never supersedes" begin
        # legacy truth table unchanged
        @test retro_write_plan(is_retro=false, supersede=false, has_live=true) == :insert
        @test retro_write_plan(is_retro=true, supersede=false, has_live=true) == :refuse
        @test retro_write_plan(is_retro=true, supersede=true, has_live=true) == :supersede
        # alongside: a live vintage (other cv) does not block the reconstruction
        @test retro_write_plan(is_retro=true, supersede=false, has_live=true, alongside=true) == :alongside
        @test retro_write_plan(is_retro=true, supersede=false, has_live=false, alongside=true) == :alongside
        # a live row at the SAME code_version is the real record: skip
        @test retro_write_plan(is_retro=true, supersede=false, has_live=true, alongside=true,
                               has_live_same_cv=true) == :refuse_same_cv
        # hard guards
        @test_throws ArgumentError retro_write_plan(is_retro=true, supersede=true, has_live=true, alongside=true)
        @test_throws ArgumentError retro_write_plan(is_retro=true, supersede=true, has_live=false, alongside=true)
        @test_throws ArgumentError retro_write_plan(is_retro=false, supersede=false, has_live=false, alongside=true)
    end

    @testset "campaign tag forces alongside" begin
        withenv("EUPHEMIA_RETRO_ALONGSIDE" => nothing) do
            @test retro_alongside("cv44-backfill-2026-11")
            @test !retro_alongside("2026-08-01-reset")
            @test !retro_alongside(nothing)
        end
        withenv("EUPHEMIA_RETRO_ALONGSIDE" => "1") do
            @test retro_alongside("some-other-tag")
        end
        @test BACKFILL_RESET_TAG in ALONGSIDE_RESET_TAGS
    end

    @testset "day chunks: consecutive runs, at most n days" begin
        d(x) = Date(2026, 9, x)
        @test retro_day_chunks(d.(14:20), 7) == [d.(14:20)]
        @test retro_day_chunks(d.(14:23), 7) == [d.(14:20), d.(21:23)]
        @test retro_day_chunks([d(14), d(15), d(17), d(18)], 7) == [[d(14), d(15)], [d(17), d(18)]]   # gap = new chunk
        @test retro_day_chunks(d.(14:30), 0) == [d.(14:30)]          # legacy: whole window
        @test retro_day_chunks(Date[], 7) == Vector{Date}[]
        @test retro_day_chunks([d(16), d(14), d(15), d(15)], 2) == [[d(14), d(15)], [d(16)]]   # sorted, deduplicated
    end

    @testset "clean stop before the deadline" begin
        t = DateTime(2026, 11, 17, 5, 0)
        @test !retro_should_stop(t, nothing, Float64[])
        @test !retro_should_stop(t, DateTime(2026, 11, 17, 5, 35), Float64[])        # 600 s first guess fits
        @test retro_should_stop(t, DateTime(2026, 11, 17, 5, 9), Float64[])          # does not
        @test !retro_should_stop(t, DateTime(2026, 11, 17, 5, 35), [300.0, 1200.0])  # 1.25 x 1200 s = 25 min
        @test retro_should_stop(t, DateTime(2026, 11, 17, 5, 24), [300.0, 1200.0])
    end

    @testset "live-only predicate" begin
        withenv("EXPORT_LIVE_RETRO" => nothing) do
            @test live_only_sql("s") == " AND s.is_retro = false"
        end
        withenv("EXPORT_LIVE_RETRO" => "1") do
            @test live_only_sql("f") == ""
        end
    end

    @testset "backfilled window: cohorts, naive, kill switch, failure" begin
        sc = DataFrame(z=["GR", "GR", "DE_LU"], lead_days=[1, 1, 1], mode=fill("weather", 3),
                       market_date=Date.(["2026-10-01", "2026-10-02", "2026-10-01"]),
                       cv=[44, 44, 44], mae=[10.0, 30.0, 50.0])
        parts = Dict(("GR", 1, "weather", Date(2026, 10, 1)) => (n=24, model=240.0, d1=480.0, d7=720.0, epf=480.0),
                     ("GR", 1, "weather", Date(2026, 10, 2)) => (n=24, model=720.0, d1=480.0, d7=720.0, epf=480.0))
        build(zone, lead, mode, rows, p, made) = (zone=zone, n_days=length(unique(rows.market_date)),
            mae=mean(rows.mae), naive=naive_cohort_fields(p, rows), made=made)
        e = withenv(() -> backfilled_entries(build; load=() -> (sc, parts, "2026-11-17")), "EXPORT_BACKFILLED" => nothing)
        g = e[findfirst(x -> x.zone == "GR", e)]
        @test length(e) == 2 && g.n_days == 2 && g.mae ≈ 20.0 && g.made == "2026-11-17"
        @test g.naive["n_naive"] == 48 && g.naive["rmae_d1"] ≈ 1.0 && g.naive["mae_naive_d7"] ≈ 30.0
        de = e[findfirst(x -> x.zone == "DE_LU", e)]
        @test de.naive["n_naive"] == 0                               # no part for DE_LU: empty, not dropped
        @test isempty(backfilled_entries(build; load=() -> (sc[1:0, :], nothing, nothing)))
        withenv("EXPORT_BACKFILLED" => "0") do
            @test isempty(backfilled_entries((a...) -> error("never"); load=() -> error("never")))
        end
        @test isempty(@test_logs (:warn, r"backfilled window failed") match_mode = :any backfilled_entries(build; load=() -> error("db down")))
        k = Ref(0)
        boom(a...) = (k[] += 1; k[] == 2 ? error("boom") : build(a...))
        @test isempty(@test_logs (:warn, r"backfilled window failed") match_mode = :any backfilled_entries(boom; load=() -> (sc, parts, nothing)))
        @test isempty(backfilled_extra_fields("GR", 1, "weather", sc))  # R2 extension point, empty today
    end
end
