# test_effective_res.jl — the effective-RES component contract (#387, #390 §1).
#
# Everything here is pure: synthetic Load / RenewablesGenerationForecast rows
# through the real Stage-2 pipeline. No DB, no solver.

using Test, Dates
using Euphemia
const MOB = Euphemia.MeritOrderBook

res(ts, ptype, mw; resolution = "60", source = :tso) =
    Euphemia.RenewablesGenerationForecast(ts, resolution, "ZZ", ptype, mw, source)
ld(ts, mw; resolution = "60") = Euphemia.Load(ts, resolution, "ZZ", mw)

day_slots(res_min = 60) = [
    Dates.format(DateTime(2026, 3, 1) + Minute(res_min * i), "yyyymmdd-HHMM") for
    i = 0:(div(24*60, res_min)-1)
]

@testset "component classification" begin
    @test Euphemia.res_component("Solar") === :solar
    @test Euphemia.res_component("Wind Onshore") === :wind
    @test Euphemia.res_component("Wind Offshore") === :wind
    @test Euphemia.res_component("Wind") === :wind
    @test Euphemia.res_component("WeatherFill") === :other   # unsplit: never counted as solar
end

@testset "published zero is coverage; a coalesced zero is not" begin
    rows = [
        res("20260301-1200", "Solar", 0.0),                      # TSO says: no sun
        res("20260301-1200", "Wind Onshore", 0.0; source = :absent),
    ] # nothing published
    m = MOB.res_source_map(rows)
    @test MOB.res_covered(m, :solar, "20260301-1200")
    @test !MOB.res_covered(m, :wind, "20260301-1200")
    @test !MOB.res_covered(m, :solar, "20260301-1300")               # no row at all
end

@testset "res-fill: a published wind row no longer blocks an absent solar one" begin
    # The #387 shape: the TSO publishes wind for the hour, nothing for solar.
    rows = [res("20260301-1200", "Wind Onshore", 400.0)]
    fill = Dict(
        :solar => Dict("20260301-1200" => 900.0, "20260301-1300" => 950.0),
        :wind => Dict("20260301-1200" => 111.0, "20260301-1300" => 222.0),
    )
    added = MOB._apply_res_fill!(rows, fill, "ZZ")
    @test added[:solar] == 2        # both hours: 12:00 uncovered for solar, 13:00 empty
    @test added[:wind] == 1         # 12:00 published, only 13:00 filled
    solar12 = only(
        r for r in rows if r.date_time == "20260301-1200" &&
            Euphemia.res_component(r.production_type) === :solar
    )
    @test solar12.aggregated_generation_forecast == 900.0
    @test solar12.source === :weather_fill
    @test only(
        r for r in rows if r.date_time == "20260301-1200" &&
            Euphemia.res_component(r.production_type) === :wind
    ).aggregated_generation_forecast == 400.0   # published wind untouched
end

@testset "res-fill: legacy combined shape stays out of the solar axis" begin
    rows = Euphemia.RenewablesGenerationForecast[]
    added = MOB._apply_res_fill!(rows, Dict("20260301-1200" => 500.0), "ZZ")
    @test added[:other] == 1
    @test Euphemia.res_component(only(rows).production_type) === :other
end

@testset "Stage 2: components reconcile to the aggregate, at every resolution" begin
    for res_min in (15, 30, 60)
        slots = day_slots(res_min)
        loads = [ld(ts, 5000.0; resolution = "PT$(res_min)M") for ts in slots]
        rows = vcat(
            [res(ts, "Solar", 1000.0; resolution = "PT$(res_min)M") for ts in slots],
            [res(ts, "Wind Onshore", 600.0; resolution = "PT$(res_min)M") for ts in slots],
        )
        _, load_by_time, ren, _, er =
            MOB._demand_series(loads, rows, nothing, nothing, nothing)
        @test er.alloc === :exact
        for ts in keys(ren)
            @test MOB.component_series(er, :solar)[ts] +
                  MOB.component_series(er, :wind)[ts] ≈ ren[ts]
        end
        # and after down-aggregation to the hourly clearing grid
        _, lbt60, ren60, rmin, er60 = MOB._demand_series(loads, rows, 60, nothing, nothing)
        @test rmin == 60 && length(ren60) == 24
        @test all(
            MOB.component_series(er60, :solar)[ts] + MOB.component_series(er60, :wind)[ts] ≈
            ren60[ts] for ts in keys(ren60)
        )
        @test MOB.solar_share_by_hour(er60, lbt60)[12] ≈ 1000.0 / 5000.0
    end
end

@testset "the regime axis is the effective series, not the raw rows (#387)" begin
    slots = day_slots()
    loads = [ld(ts, 5000.0) for ts in slots]
    # A zone that publishes WIND only: raw solar is nil, so the old gate could
    # never fire here however sunny the weather model said it was.
    rows = [res(ts, "Wind Onshore", 300.0) for ts in slots]
    _, lbt, ren, _, er0 = MOB._demand_series(loads, copy(rows), nothing, nothing, nothing)
    @test get(MOB.solar_share_by_hour(er0, lbt), 12, 0.0) == 0.0

    filled = copy(rows)
    MOB._apply_res_fill!(filled, Dict(:solar => Dict(ts => 2500.0 for ts in slots)), "ZZ")
    _, lbt2, ren2, _, er1 = MOB._demand_series(loads, filled, nothing, nothing, nothing)
    share = MOB.solar_share_by_hour(er1, lbt2)
    @test share[12] ≈ 0.5                       # crosses the shipped θ = 0.4
    @test ren2["20260301-1200"] ≈ 2800.0        # and it IS in the supply stack
    @test er1.coverage[:solar] == 24
end

@testset "component modifier: solar moves the axis, wind does not" begin
    slots = day_slots()
    loads = [ld(ts, 5000.0) for ts in slots]
    rows = vcat(
        [res(ts, "Solar", 1000.0) for ts in slots],
        [res(ts, "Wind Onshore", 500.0) for ts in slots],
    )
    base_share = 1000.0 / 5000.0

    solar_up = (ts, c, mw) -> c === :solar ? mw + 1000.0 : mw
    _, lbt, ren, _, er =
        MOB._demand_series(loads, rows, nothing, nothing, nothing, solar_up)
    @test ren["20260301-1200"] ≈ 2500.0                        # supply moved
    @test MOB.solar_share_by_hour(er, lbt)[12] ≈ 2000.0 / 5000.0  # and the axis

    wind_up = (ts, c, mw) -> c === :wind ? mw + 1000.0 : mw
    _, lbt2, ren2, _, er2 =
        MOB._demand_series(loads, rows, nothing, nothing, nothing, wind_up)
    @test ren2["20260301-1200"] ≈ 2500.0                       # same supply change
    @test MOB.solar_share_by_hour(er2, lbt2)[12] ≈ base_share   # axis unmoved
end

@testset "an aggregate modifier is split pro rata, and says so" begin
    slots = day_slots()
    loads = [ld(ts, 5000.0) for ts in slots]
    rows = vcat(
        [res(ts, "Solar", 1000.0) for ts in slots],
        [res(ts, "Wind Onshore", 1000.0) for ts in slots],
    )
    _, lbt, ren, _, er = MOB._demand_series(loads, rows, nothing, nothing, (ts, v) -> 2 * v)
    @test er.alloc === :pro_rata
    @test ren["20260301-1200"] ≈ 4000.0
    @test MOB.component_series(er, :solar)["20260301-1200"] ≈ 2000.0
    @test MOB.solar_share_by_hour(er, lbt)[12] ≈ 2000.0 / 5000.0
end

@testset "no hooks: the effective solar axis reproduces the raw-row gate" begin
    # The guard for the record path: with no fill, no corrections and no
    # scenario, the new axis must equal the pre-#387 computation over raw rows.
    slots = day_slots(15)
    loads = [ld(ts, 4000.0 + 10 * i; resolution = "PT15M") for (i, ts) in enumerate(slots)]
    rows = vcat(
        [
            res(ts, "Solar", 300.0 + 3 * i; resolution = "PT15M") for
            (i, ts) in enumerate(slots)
        ],
        [res(ts, "Wind Onshore", 100.0; resolution = "PT15M") for ts in slots],
    )
    _, lbt, _, _, er = MOB._demand_series(loads, rows, 60, nothing, nothing)

    sol_hr = Dict{Int,Vector{Float64}}();
    ld_hr = Dict{Int,Vector{Float64}}()
    for r in rows
        r.production_type == "Solar" || continue
        push!(
            get!(sol_hr, parse(Int, r.date_time[10:11]), Float64[]),
            r.aggregated_generation_forecast,
        )
    end
    for (ts, v) in lbt
        push!(get!(ld_hr, parse(Int, ts[10:11]), Float64[]), v)
    end
    old = Dict(
        h => (sum(vs) / length(vs)) / (sum(ld_hr[h]) / length(ld_hr[h])) for
        (h, vs) in sol_hr
    )
    new = MOB.solar_share_by_hour(er, lbt)
    @test keys(new) == keys(old)
    @test all(new[h] ≈ old[h] for h in keys(old))
end

@testset "a reallocation splits an aggregate edit without re-applying it" begin
    # The cv32 input corrections are applied ONCE, to the aggregate. Handing the
    # same per-target deltas to the component series must record WHICH component
    # they were, not add them a second time — the defect this test pins was
    # caught on IT-Sicily, where solar read 1014 MW instead of 1051 MW.
    slots = day_slots()
    loads = [ld(ts, 5000.0) for ts in slots]
    rows = vcat([res(ts, "Solar", 1000.0) for ts in slots],
                [res(ts, "Wind Onshore", 500.0) for ts in slots])
    agg = (ts, v) -> v + 200.0                       # the aggregate correction
    realloc = (ts, c, mw) -> c === :solar ? mw + 200.0 : mw   # ... which was solar
    _, lbt, ren, _, er = MOB._demand_series(loads, rows, nothing, nothing, agg,
                                            nothing, realloc)
    @test ren["20260301-1200"] ≈ 1700.0              # 1500 + 200, counted ONCE
    @test MOB.component_series(er, :solar)["20260301-1200"] ≈ 1200.0
    @test MOB.component_series(er, :wind)["20260301-1200"] ≈ 500.0
    @test er.alloc === :exact                        # the split already adds up
    @test MOB.solar_share_by_hour(er, lbt)[12] ≈ 1200.0 / 5000.0
end
