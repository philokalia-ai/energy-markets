# Tests for the merit-order scenario hooks (Features 3/4/5) and the DuckDB
# data-store round-trip (Features 1/2).
#
# Uses Date(2026, 1, 26) — a benchmark day with complete GR data.

using Test
using Euphemia
using Dates
using Statistics
# SimpleOrder is exported by Euphemia

const HOOK_ZONE = "GR"
const HOOK_DAY = Date(2026, 1, 26)

# Sorted, tag-independent fingerprint of an order book for identity checks.
function order_fingerprint(ob)
    return sort([(round(o.price, digits=6), round(o.quantity, digits=6),
                  o.type, o.date_time) for o in ob.orders])
end

avgprice(prices) = mean(values(prices))

# Clear a scenario end-to-end and return the mean cleared price.
function clear_avg(; kwargs...)
    prices = generate_energy_prices(HOOK_ZONE, HOOK_DAY;
        order_method=:merit_order, optimizer="auto", save_to_db=false, kwargs...)
    @test !isempty(prices)
    return avgprice(prices), prices
end

@testset "Scenario hooks" begin

    # Baseline book + prices (no hooks)
    base_result = create_merit_order_book(HOOK_ZONE, HOOK_DAY)
    @test base_result.success
    base_avg, base_prices = clear_avg()

    @testset "(a) all hooks nothing == no-kwargs book" begin
        hooked = create_merit_order_book(HOOK_ZONE, HOOK_DAY;
            load_modifier=nothing, renewable_modifier=nothing,
            extra_orders=nothing, strategist=nothing)
        @test hooked.success
        @test order_fingerprint(hooked.order_book) == order_fingerprint(base_result.order_book)
    end

    @testset "(b) load_modifier +500 raises price" begin
        avg, _ = clear_avg(load_modifier=(ts, v) -> v + 500.0)
        @test avg >= base_avg - 1e-6
    end

    @testset "(c) renewable_modifier +300 daylight lowers price" begin
        # +300 MW during daylight slots (hours 08..17)
        rmod = (ts, v) -> (8 <= parse(Int, ts[10:11]) <= 17) ? v + 300.0 : v
        avg, _ = clear_avg(renewable_modifier=rmod)
        @test avg <= base_avg + 1e-6
    end

    @testset "(d) extra_orders +200MW demand at cap raises price" begin
        eo = ctx -> [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
                        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                     for ts in ctx.timeslots]
        avg, _ = clear_avg(extra_orders=eo)
        @test avg >= base_avg - 1e-6
    end

    @testset "(e) strategist identity and firm markup" begin
        # Identity strategist returns the tagged orders unchanged → identical prices
        _, id_prices = clear_avg(strategist=ctx -> ctx.tagged_orders)
        @test keys(id_prices) == keys(base_prices)
        for k in keys(base_prices)
            @test isapprox(id_prices[k], base_prices[k]; atol=1e-6)
        end

        # "What if PPC marked up its units 20%?" — multiply the offer price of
        # every supply order owned by a PPC unit by 1.2, leave the rest.
        ppc_markup = function (ctx)
            out = Tuple{SimpleOrder,String}[]
            for (o, tag) in ctx.tagged_orders
                if o.type == :supply && get(ctx.firm_of, tag, "") == "PPC"
                    push!(out, (SimpleOrder(o.type, o.price * 1.2, o.quantity,
                        o.zone, o.date_time, o.resolution_code), tag))
                else
                    push!(out, (o, tag))
                end
            end
            return out
        end
        avg, _ = clear_avg(strategist=ppc_markup)
        @test avg >= base_avg - 1e-6
    end

    @testset "(e2) strategist plain-vector return is re-tagged" begin
        # Returning a plain Vector{SimpleOrder} (no tags) must still clear
        plain = ctx -> [o for (o, _tag) in ctx.tagged_orders]
        _, pv_prices = clear_avg(strategist=plain)
        for k in keys(base_prices)
            @test isapprox(pv_prices[k], base_prices[k]; atol=1e-6)
        end
    end

    @testset "(f) DuckDB round-trip matches Postgres" begin
        extract = joinpath(dirname(@__DIR__), "data", "extracts", "euphemia_2026_see.duckdb")
        if !isfile(extract)
            @info "DuckDB extract not found ($extract) — skipping round-trip test"
            @test_skip false
        else
            # Postgres baseline (already have base_prices for the same call)
            pg_prices = base_prices
            try
                configure_data_store!(backend=:duckdb, duckdb_path=extract)
                duck_prices = generate_energy_prices(HOOK_ZONE, HOOK_DAY;
                    order_method=:merit_order, optimizer="auto", save_to_db=false)
                @test !isempty(duck_prices)
                @test keys(duck_prices) == keys(pg_prices)
                for k in keys(pg_prices)
                    @test isapprox(duck_prices[k], pg_prices[k]; atol=0.01)
                end
            finally
                configure_data_store!(backend=:postgres)
            end
        end
    end

end
