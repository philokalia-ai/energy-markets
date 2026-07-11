# Tests for the multi-zone scenario API (ZoneScenario threaded through
# run_multi_zone_market_clearing / _create_multi_zone_order_book_merit) and the
# new fleet_modifier capacity primitive.
#
# The book-level guards and the fleet_modifier / targeting checks run against
# the DuckDB EU extract (offline, no solver) and are fast. The solve-based
# two-pass propagation check is gated behind MZ_SCENARIO_SOLVE=1 (it runs a
# small HiGHS two-pass clear) and lives in
# test/scripts/scenario_two_pass_propagation.jl for the full 39-zone version.

using Test
using Euphemia
using Dates
using Statistics

const MZ_DAY = Date(2026, 4, 3)
const SEE_ZONES = ["GR", "BG", "RO", "RS", "HU"]
const EU_FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

# Tag-independent fingerprint of an MPCCOrderBook.
book_fp(ob) = sort([(String(o.zone), round(o.price, digits=6),
                     round(o.quantity, digits=6), o.type, o.date_time)
                    for o in ob.orders])

# Per-slot offered supply capacity of a single-zone book result.
supply_per_slot(res) =
    sum((o.quantity for o in res.order_book.orders if o.type == :supply); init=0.0) /
    length(res.order_book.periods)

# Locate the EU extract: explicit env override, else the published public
# extract next to the repo. Skip the whole suite if neither is present.
function eu_extract_path()
    p = get(ENV, "EUPHEMIA_EU_EXTRACT", "")
    !isempty(p) && isfile(p) && return p
    for c in (joinpath(dirname(@__DIR__), "data", "public", "euphemia-public-v1.1.duckdb"),
              joinpath(dirname(@__DIR__), "data", "public", "euphemia-public.duckdb"),
              joinpath(dirname(@__DIR__), "data", "extracts", "euphemia_2026_eu.duckdb"))
        isfile(c) && return c
    end
    return ""
end

@testset "ZoneScenario resolution (pure)" begin
    # nothing everywhere
    @test Euphemia.zone_scenario(nothing, "GR") === nothing
    # empty ZoneScenario resolves to nothing (byte-identical path)
    @test Euphemia.is_empty_scenario(ZoneScenario())
    @test Euphemia.zone_scenario(ZoneScenario(), "GR") === nothing
    # a single non-empty ZoneScenario applies to every zone
    s = ZoneScenario(load_modifier = (ts, v) -> v + 1.0)
    @test !Euphemia.is_empty_scenario(s)
    @test Euphemia.zone_scenario(s, "GR") === s
    @test Euphemia.zone_scenario(s, "DE_LU") === s
    # a Dict targets only its keys; absent zones get nothing
    d = Dict("GR" => s)
    @test Euphemia.zone_scenario(d, "GR") === s
    @test Euphemia.zone_scenario(d, "BG") === nothing
    # an empty ZoneScenario value in the Dict still resolves to nothing
    d2 = Dict("GR" => ZoneScenario())
    @test Euphemia.zone_scenario(d2, "GR") === nothing
end

const EXTRACT = eu_extract_path()

if isempty(EXTRACT)
    @info "EU DuckDB extract not found — skipping multi-zone scenario book guards"
    @testset "multi-zone scenario book guards (skipped)" begin
        @test_skip false
    end
else
    # Open the extract read-only so we never contend with a running backfill's
    # write lock. Restore Postgres afterwards.
    prev_backend = Euphemia.DATA_STORE[]
    configure_data_store!(backend = :duckdb, duckdb_path = EXTRACT, read_only = true)
    try
        @testset "single-zone book: nothing hooks == plain (byte-identical)" begin
            plain = create_merit_order_book("GR", MZ_DAY)
            hooked = create_merit_order_book("GR", MZ_DAY;
                load_modifier = nothing, renewable_modifier = nothing,
                extra_orders = nothing, strategist = nothing, fleet_modifier = nothing)
            @test plain.success && hooked.success
            @test book_fp(plain.order_book) == book_fp(hooked.order_book)
        end

        @testset "SEE 5-zone guard: no scenario == scenario=nothing/empty" begin
            base = mz_build_books(SEE_ZONES, MZ_DAY)
            none = mz_build_books(SEE_ZONES, MZ_DAY; scenario = nothing)
            emptys = mz_build_books(SEE_ZONES, MZ_DAY; scenario = ZoneScenario())
            emptyd = mz_build_books(SEE_ZONES, MZ_DAY;
                scenario = Dict{String,ZoneScenario}())
            @test book_fp(base) == book_fp(none)
            @test book_fp(base) == book_fp(emptys)
            @test book_fp(base) == book_fp(emptyd)
        end

        @testset "EU 39-zone guard: no scenario == scenario=nothing (byte-identical)" begin
            base = mz_build_books(EU_FOOTPRINT, MZ_DAY; enrich_network = true)
            none = mz_build_books(EU_FOOTPRINT, MZ_DAY; enrich_network = true,
                scenario = nothing)
            @test length(base.orders) > 10_000          # sanity: real 39-zone book
            @test book_fp(base) == book_fp(none)
            # An empty per-zone Dict must also be a no-op.
            emptyd = mz_build_books(EU_FOOTPRINT, MZ_DAY; enrich_network = true,
                scenario = Dict{String,ZoneScenario}())
            @test book_fp(base) == book_fp(emptyd)
        end

        @testset "fleet_modifier removes a unit under :installed truth mode" begin
            prof = Euphemia.get_zone_profile("DE_LU")
            @test prof.fleet_truth_mode == :installed   # guards the ordering claim
            gens = Euphemia.get_generators("DE_LU", MZ_DAY)
            hc = sort([g for g in gens if g.fuel_type == Symbol("Fossil Hard coal")],
                      by = g -> abs(g.p_max - 500))
            @test !isempty(hc)
            unit = hc[1]
            base = create_merit_order_book("DE_LU", MZ_DAY; profile = prof)
            remover = (z, gs) -> [g for g in gs if g.code != unit.code]
            cut = create_merit_order_book("DE_LU", MZ_DAY; profile = prof,
                fleet_modifier = remover)
            @test base.success && cut.success
            # The removed unit's capacity actually leaves the offered stack —
            # it is NOT re-added by the installed-fleet completion (which runs
            # BEFORE the modifier). Drop equals the unit's p_max per slot.
            drop = supply_per_slot(base) - supply_per_slot(cut)
            @test isapprox(drop, unit.p_max; atol = 1.0)
        end

        @testset "Dict scenario targets only its zone" begin
            ships = ctx -> ctx.zone == "GR" ?
                [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
                    DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                 for ts in ctx.timeslots] : SimpleOrder[]
            base = mz_build_books(SEE_ZONES, MZ_DAY)
            tgt = mz_build_books(SEE_ZONES, MZ_DAY;
                scenario = Dict("GR" => ZoneScenario(extra_orders = ships)))
            gr_base = filter(t -> t[1] == "GR", book_fp(base))
            gr_tgt = filter(t -> t[1] == "GR", book_fp(tgt))
            other_base = filter(t -> t[1] != "GR", book_fp(base))
            other_tgt = filter(t -> t[1] != "GR", book_fp(tgt))
            @test gr_base != gr_tgt        # GR changed
            @test other_base == other_tgt  # every other SEE zone untouched
        end

        # Solve-based two-pass propagation (opt-in — runs a small HiGHS clear).
        if get(ENV, "MZ_SCENARIO_SOLVE", "") == "1"
            @testset "two-pass propagation: DE_LU demand moves NO2 water value" begin
                cluster = ["DE_LU", "NO2", "NL"]
                avgz(z, r) = haskey(r.market_prices, z) ?
                    mean(values(r.market_prices[z])) : NaN
                r0 = run_multi_zone_market_clearing(MZ_DAY; zones = cluster,
                    order_method = :merit_order, enrich_network = true, passes = 2,
                    optimizer = "highs", save_to_db = false, mpcc_time_limit = 180.0)
                bigd = ctx -> ctx.zone == "DE_LU" ?
                    [SimpleOrder(:demand, 3000.0, 4000.0, Symbol(ctx.zone),
                        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                     for ts in ctx.timeslots] : SimpleOrder[]
                r1 = run_multi_zone_market_clearing(MZ_DAY; zones = cluster,
                    order_method = :merit_order, enrich_network = true, passes = 2,
                    optimizer = "highs", save_to_db = false, mpcc_time_limit = 180.0,
                    scenario = ZoneScenario(extra_orders = bigd))
                @test !isnan(avgz("NO2", r0)) && !isnan(avgz("NO2", r1))
                # NO2 is an opportunity-anchored (:hydro) zone; its pass-2 water
                # value tracks the pass-1 coupled reference, which DE_LU's extra
                # demand lifts. The move must be strictly positive.
                @test avgz("DE_LU", r1) > avgz("DE_LU", r0) + 1e-6
                @test avgz("NO2", r1) > avgz("NO2", r0) + 1e-6
            end
        end
    finally
        configure_data_store!(backend = prev_backend == :duckdb ? :duckdb : :postgres,
            duckdb_path = prev_backend == :duckdb ? EXTRACT : nothing,
            read_only = prev_backend == :duckdb)
    end
end
