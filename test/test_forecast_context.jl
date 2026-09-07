# test_forecast_context.jl — the as-of input contract (issue #368, phase 1).
# Pure fixtures first (gate rule, DST, context scoping, classification, audit);
# then DB-backed identity checks: the legacy path is untouched, and a lead-1
# gate context reproduces the legacy fuel close.

using Test, Dates, DataFrames
using Euphemia
using Euphemia:
    ForecastContext,
    gate_context,
    issuance_context,
    auction_gate_utc,
    is_eu_summer_time_utc,
    with_context,
    current_context,
    ctx_key,
    stamp_status,
    classify_stamps!,
    record_asof_status!,
    asof_audit,
    reset_asof_audit!,
    asof_audit_table

@testset "auction gate — fixed 10 UTC vs auction-local (EU DST)" begin
    # summer: both rules give D-1 10:00 UTC
    @test auction_gate_utc(Date(2026, 7, 15)) == DateTime(2026, 7, 14, 10)
    @test auction_gate_utc(Date(2026, 7, 15); rule = :auction_local) ==
          DateTime(2026, 7, 14, 10)
    # winter: fixed rule stays at 10:00, local rule moves to 11:00 UTC
    @test auction_gate_utc(Date(2026, 1, 15)) == DateTime(2026, 1, 14, 10)
    @test auction_gate_utc(Date(2026, 1, 15); rule = :auction_local) ==
          DateTime(2026, 1, 14, 11)
    # 2026 transitions: last Sunday of March = 03-29, of October = 10-25
    @test is_eu_summer_time_utc(DateTime(2026, 3, 29, 0, 59)) == false
    @test is_eu_summer_time_utc(DateTime(2026, 3, 29, 1, 0)) == true
    @test is_eu_summer_time_utc(DateTime(2026, 10, 25, 0, 59)) == true
    @test is_eu_summer_time_utc(DateTime(2026, 10, 25, 1, 0)) == false
    # D-1 that IS the transition Sunday: by noon the new regime is in force
    @test auction_gate_utc(Date(2026, 3, 30); rule = :auction_local) ==
          DateTime(2026, 3, 29, 10)   # 23-h local day D-1
    @test auction_gate_utc(Date(2026, 10, 26); rule = :auction_local) ==
          DateTime(2026, 10, 25, 11) # 25-h local day D-1
    # the delivery day itself being the transition day changes nothing about D-1's gate
    @test auction_gate_utc(Date(2026, 3, 29); rule = :auction_local) ==
          DateTime(2026, 3, 28, 11)
    @test auction_gate_utc(Date(2026, 10, 25); rule = :auction_local) ==
          DateTime(2026, 10, 24, 10)
    @test_throws ArgumentError auction_gate_utc(Date(2026, 1, 1); rule = :bogus)
end

@testset "contexts and scoping" begin
    d = Date(2026, 8, 20)
    c1 = gate_context(d)
    @test c1.lead == 1 && c1.as_of_utc == DateTime(2026, 8, 19, 10) && c1.delivery == d
    c3 = issuance_context(d, 3)
    @test c3.lead == 3 && c3.as_of_utc == DateTime(2026, 8, 17, 6, 30)
    @test issuance_context(d, 1) == c1                       # lead 1 keeps the gate
    @test_throws ArgumentError issuance_context(d, 0)

    @test current_context() === nothing && ctx_key() === nothing
    seen = with_context(c1) do
        inner = with_context(c3) do
            (current_context(), ctx_key())
        end
        (current_context(), ctx_key(), inner)
    end
    @test seen[1] === c1 && seen[2] == c1.as_of_utc
    @test seen[3][1] === c3 && seen[3][2] == c3.as_of_utc
    @test current_context() === nothing                       # gone after the scope
    # spawned tasks inherit the scope
    got = with_context(c3) do
        fetch(Threads.@spawn current_context())
    end
    @test got === c3
end

@testset "stamp classification and audit" begin
    reset_asof_audit!()
    c = gate_context(Date(2026, 8, 20))
    @test stamp_status("load_forecast_d1", DateTime(2026, 8, 19, 9, 30), c) == :verified
    @test stamp_status("load_forecast_d1", DateTime(2026, 8, 19, 13, 35), c) == :post_gate
    @test stamp_status("load_forecast_d1", missing, c) == :unverifiable
    @test stamp_status("res_forecast_d1", DateTime(2026, 8, 19, 9, 0), c) == :unverifiable
    old = gate_context(Date(2025, 8, 20))
    @test stamp_status("load_forecast_d1", DateTime(2025, 8, 19, 9, 0), old) ==
          :legacy_stamp
    @test stamp_status("outages_generation", DateTime(2025, 8, 19, 9, 0), old) ==
          :legacy_stamp

    # outside a context nothing is recorded
    @test isempty(classify_stamps!("load_forecast_d1", [DateTime(2026, 8, 19, 9)]))
    record_asof_status!("x", :verified)
    @test isempty(asof_audit())
    with_context(c) do
        counts = classify_stamps!(
            "load_forecast_d1",
            [DateTime(2026, 8, 19, 9), DateTime(2026, 8, 19, 13, 35), missing],
        )
        @test counts == Dict(:verified => 1, :post_gate => 1, :unverifiable => 1)
        record_asof_status!("outages_generation", :verified, 2)
    end
    a = asof_audit()
    @test a["load_forecast_d1"] == Dict(:verified => 1, :post_gate => 1, :unverifiable => 1)
    @test a["outages_generation"] == Dict(:verified => 2)
    t = asof_audit_table()
    @test names(t) == ["source", "status", "rows"] && nrow(t) == 4
    reset_asof_audit!()
    @test isempty(asof_audit())
end

@testset "DB: legacy path untouched, lead-1 context reproduces the fuel close" begin
    d = Date(2026, 8, 20)
    legacy_ttf = Euphemia.get_ttf_price(d)
    legacy_eua = Euphemia.get_daily_eua_price(d)
    @test legacy_ttf !== nothing
    ctx_ttf, ctx_eua = with_context(gate_context(d)) do
        (Euphemia.get_ttf_price(d), Euphemia.get_daily_eua_price(d))
    end
    @test ctx_ttf == legacy_ttf && ctx_eua == legacy_eua
    # lead L reads the close available at issuance D-L, i.e. the legacy close of delivery D-L+1
    l3 = with_context(issuance_context(d, 3)) do
        Euphemia.get_ttf_price(d)
    end
    @test l3 == Euphemia.get_ttf_price(d - Day(2))

    # outage table: a context returns a DataFrame with the same schema and
    # records its status; the legacy cache entry is left alone.
    reset_asof_audit!()
    Euphemia.clear_generator_caches!()
    leg = Euphemia.get_day_outages(d)
    ctx = with_context(gate_context(d)) do
        Euphemia.get_day_outages(d)
    end
    @test names(ctx) == names(leg)
    @test asof_audit()["outages_generation"] == Dict(:verified => 1)
    @test haskey(Euphemia._OUTAGE_DAY_CACHE, (d, nothing))
    @test haskey(Euphemia._OUTAGE_DAY_CACHE, (d, DateTime(2026, 8, 19, 10)))
    # the load reader classifies inside a context and stays silent outside
    reset_asof_audit!()
    Euphemia.get_loads("DE_LU", d)
    @test isempty(asof_audit())
    with_context(gate_context(d)) do
        Euphemia.get_loads("DE_LU", d)
    end
    @test haskey(asof_audit(), "load_forecast_d1")
    reset_asof_audit!()
end
