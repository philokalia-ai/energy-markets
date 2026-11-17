# Public gap-fill of a self-hosted open-meteo primary + the self-diagnosing retro
# skip reasons (#431 R3). Pure: the HTTP layer is a stub closure, no network.
#   julia --project=. test/test_weather_gapfill.jl

using Test, Dates

isdefined(@__MODULE__, :parse_openmeteo_response) ||
    include(joinpath(@__DIR__, "..", "bin", "weather_res.jl"))
isdefined(@__MODULE__, :easter_gregorian) ||
    include(joinpath(@__DIR__, "..", "bin", "weather_load.jl"))
isdefined(@__MODULE__, :parse_lgb_model) ||
    include(joinpath(@__DIR__, "..", "bin", "ml_inputs.jl"))
isdefined(@__MODULE__, :athens_market_day_window) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))

# A previous_day1 body for `cells` over `hours`, null where `isnull(cell, hour)`.
function _pd1_body(cells, hours; isnull=(c, h) -> false)
    locs = map(cells) do c
        t = join(("\"" * Dates.format(h, "yyyy-mm-ddTHH:MM") * "\"" for h in hours), ",")
        v = join((isnull(c, h) ? "null" : "7.5" for h in hours), ",")
        g = join((isnull(c, h) ? "null" : "100.0" for h in hours), ",")
        """{"latitude":$(c[1]),"longitude":$(c[2]),"hourly":{"time":[$t],""" *
        """"wind_speed_100m_previous_day1":[$v],"shortwave_radiation_previous_day1":[$g]}}"""
    end
    return "[" * join(locs, ",") * "]"
end

withenv_gapfill(f, v) = withenv(f, "EUPHEMIA_OPENMETEO_GAPFILL" => v)

@testset "weather gap-fill + skip diagnosis (#431 R3)" begin
    cells = [(48.0, 17.0), (49.0, 18.0)]
    hours = openmeteo_request_hours(Date(2026, 10, 11), Date(2026, 10, 12))   # 48 h
    @test length(hours) == 48 && first(hours) == DateTime(2026, 10, 11) && last(hours) == DateTime(2026, 10, 12, 23)
    PRI = "http://open-meteo.local/v1/forecast"; PUB = "https://previous-runs-api.open-meteo.com/v1/forecast"
    url = PRI * "?latitude=48.0,49.0&longitude=17.0,18.0&hourly=x&start_date=2026-10-11&end_date=2026-10-12"
    parse = b -> parse_openmeteo_response(b, cells; var_suffix="_previous_day1")
    boundary = DateTime(2026, 10, 12, 3)   # the self-hosted history starts here (cf. 2026-10-17 03:00 in prod)
    full = _pd1_body(cells, hours)
    allnull = _pd1_body(cells, hours; isnull=(c, h) -> true)
    partial = _pd1_body(cells, hours; isnull=(c, h) -> h < boundary)
    stub(primary_body; public_body=full, calls=String[]) = u -> begin
        push!(calls, u)
        startswith(u, PUB) ? (public_body isa Exception ? throw(public_body) : public_body) : primary_body
    end
    run(get_fn; prevruns=true, can_fallback=true) = _fetch_batch_with_fallback(
        "ml-res", url, PRI, PUB, cells, hours; get_fn, parse_fn=parse, prevruns, can_fallback)

    @testset "pure helpers" begin
        p = parse(partial)
        @test _batch_missing_cell_hours(p, cells, hours) == 2 * 27
        @test _batch_missing_cell_hours(Dict(), cells, hours) == 96
        @test _first_hour(p) == boundary
        @test _first_hour(Dict()) === nothing
        withenv_gapfill("1") do
            @test _public_fallback_mode(parse(allnull), cells, hours; prevruns=true, can_fallback=true) == :all_null
            @test _public_fallback_mode(p, cells, hours; prevruns=true, can_fallback=true) == :gaps
            @test _public_fallback_mode(p, cells, hours; prevruns=false, can_fallback=true) == :none   # live lag 0
            @test _public_fallback_mode(p, cells, hours; prevruns=true, can_fallback=false) == :none
            @test _public_fallback_mode(parse(full), cells, hours; prevruns=true, can_fallback=true) == :none
        end
        withenv_gapfill("0") do
            @test _public_fallback_mode(p, cells, hours; prevruns=true, can_fallback=true) == :none
            @test _public_fallback_mode(parse(allnull), cells, hours; prevruns=true, can_fallback=true) == :all_null
        end
        # merge never overwrites a primary hour
        a = Dict(cells[1] => Dict(DateTime(2026, 10, 11) => (1.0, 2.0)))
        b = Dict(cells[1] => Dict(DateTime(2026, 10, 11) => (9.0, 9.0), DateTime(2026, 10, 11, 1) => (3.0, 4.0)),
                 cells[2] => Dict(DateTime(2026, 10, 11) => (5.0, 6.0)))
        @test _gapfill_merge!(a, b, cells) == 2
        @test a[cells[1]][DateTime(2026, 10, 11)] == (1.0, 2.0)
        @test a[cells[1]][DateTime(2026, 10, 11, 1)] == (3.0, 4.0) && a[cells[2]][DateTime(2026, 10, 11)] == (5.0, 6.0)
    end

    @testset "fetch driver: the production failure shapes" begin
        withenv_gapfill("1") do
            reset_weather_fetch_log!()
            calls = String[]
            # complete primary → no public call
            @test _batch_missing_cell_hours(run(stub(full; calls)), cells, hours) == 0
            @test length(calls) == 1
            # all-null primary (chunks 1-2) → public answer
            empty!(calls)
            @test _batch_missing_cell_hours(run(stub(allnull; calls)), cells, hours) == 0
            @test length(calls) == 2 && startswith(calls[2], PUB) && occursin("start_date=2026-10-11", calls[2])
            # partial primary (the chunk straddling the boundary) → gaps filled, primary kept
            pub_marked = replace(full, "7.5" => "8.5")
            r = run(stub(partial; public_body=pub_marked))
            @test _batch_missing_cell_hours(r, cells, hours) == 0
            @test r[cells[1]][boundary][1] == 7.5                       # primary hour kept
            @test r[cells[1]][boundary - Hour(1)][1] == 8.5            # gap from public
            # public fails on the gap-fill → partial primary kept (the pre-R3 answer)
            r = run(stub(partial; public_body=ErrorException("429 after retries")))
            @test _batch_missing_cell_hours(r, cells, hours) == 54
            # HTTP error on the primary → public
            r = run(u -> startswith(u, PUB) ? full : error("connection refused"))
            @test _batch_missing_cell_hours(r, cells, hours) == 0
            s = weather_fetch_summary()
            @test length(s) == 1
            # review P3: the failed public gap-fill counts as attempted, not filled
            @test occursin("ml-res: 5 batch(es); primary complete 1, all-null→public 1, " *
                           "gaps→public attempted 2, filled 1 (54 cell-hours)", s[1])
            @test occursin("primary data from 2026-10-11 00:00", s[1])
            @test occursin("still missing 54/480 cell-hours", s[1])
        end
        withenv_gapfill("0") do
            # kill switch: the partial answer stays partial (old behaviour), and the
            # record says the missing hours had NO fallback
            reset_weather_fetch_log!()
            calls = String[]
            r = run(stub(partial; calls))
            @test _batch_missing_cell_hours(r, cells, hours) == 54 && length(calls) == 1
            # no fallback allowed at all (the ML fetch with the switch off): all-null stays empty
            r = run(stub(allnull; calls); can_fallback=false)
            @test _batch_all_empty(r, cells) && length(calls) == 2
            @test_throws ErrorException run(u -> error("down"); can_fallback=false)
            s = weather_fetch_summary()
            @test occursin("missing with NO fallback 2", s[1]) && occursin("primary data from 2026-10-12 03:00", s[1])
        end
    end

    @testset "gap-fill summary: exhausted 429 is not a fill (review P3)" begin
        withenv_gapfill("1") do
            reset_weather_fetch_log!()
            r = run(stub(partial; public_body=ErrorException("HTTP 429 after retries")))
            @test _batch_missing_cell_hours(r, cells, hours) == 54
            s = weather_fetch_summary()
            @test occursin("gaps→public attempted 1, filled 0 (0 cell-hours)", s[1])
            @test occursin("still missing 54/96 cell-hours", s[1])
            # a public answer that is itself null in the gap recovers nothing → not filled
            reset_weather_fetch_log!()
            run(stub(partial; public_body=allnull))
            @test occursin("gaps→public attempted 1, filled 0 (0 cell-hours)", weather_fetch_summary()[1])
        end
    end

    @testset "ML RES fetch: fallback only for previous-run vintages (review P2)" begin
        mlbody(cs, hs; sfx="", isnull=false) = "[" * join(map(cs) do c
            t = join(("\"" * Dates.format(h, "yyyy-mm-ddTHH:MM") * "\"" for h in hs), ",")
            v(x) = join((isnull ? "null" : x for _ in hs), ",")
            """{"latitude":$(c[1]),"longitude":$(c[2]),"hourly":{"time":[$t],""" *
            """"wind_speed_100m$sfx":[$(v("5.0"))],"shortwave_radiation$sfx":[$(v("100.0"))],""" *
            """"cloud_cover$sfx":[$(v("10.0"))],"surface_pressure$sfx":[$(v("1000.0"))]}}"""
        end, ",") * "]"
        days = [Date(2026, 10, 11), Date(2026, 10, 12)]
        LIVE_PRI = "http://open-meteo.local/v1/forecast"
        mlstub(primary; public, calls) = u -> begin
            push!(calls, u)
            if startswith(u, "https://")
                public isa Exception ? throw(public) : public
            else
                primary isa Exception ? throw(primary) : primary
            end
        end
        for flag in ("1", "0")
            withenv("EUPHEMIA_OPENMETEO_GAPFILL" => flag, "EUPHEMIA_OPENMETEO_URL" => LIVE_PRI,
                    "EUPHEMIA_OPENMETEO_PREVRUNS_URL" => LIVE_PRI) do
                # live lag 0, self-hosted all-null → ONE request, empty result (as on main)
                calls = String[]
                r = fetch_ml_res_weather(cells, days; vintage_lag=0,
                        get_fn=mlstub(mlbody(cells, hours; isnull=true); public=mlbody(cells, hours), calls))
                @test length(calls) == 1 && startswith(calls[1], LIVE_PRI)
                @test all(isempty(get(r, c, Dict())) for c in cells)
                # live lag 0, self-hosted partial → ONE request, partial kept
                calls = String[]
                fetch_ml_res_weather(cells, days; vintage_lag=0,
                        get_fn=mlstub(mlbody(cells, hours[1:10]); public=mlbody(cells, hours), calls))
                @test length(calls) == 1
                # live lag 0, HTTP error → propagates (the caller keeps its pack series), no public call
                calls = String[]
                @test_throws ErrorException fetch_ml_res_weather(cells, days; vintage_lag=0,
                        get_fn=mlstub(ErrorException("connection refused"); public=mlbody(cells, hours), calls))
                @test length(calls) == 1
                # previous-run lag 1, all-null → public fallback only with the switch on
                calls = String[]
                r = fetch_ml_res_weather(cells, days; vintage_lag=1,
                        get_fn=mlstub(mlbody(cells, hours; sfx="_previous_day1", isnull=true);
                                      public=mlbody(cells, hours; sfx="_previous_day1"), calls))
                if flag == "1"
                    @test length(calls) == 2 && startswith(calls[2], OPENMETEO_PREVRUNS_URL_DEFAULT)
                    @test all(length(r[c]) == 48 for c in cells)
                else
                    @test length(calls) == 1 && all(isempty(get(r, c, Dict())) for c in cells)
                end
            end
        end
    end

    @testset "ML RES parser drops any-null hours" begin
        body = """[{"latitude":48.0,"longitude":17.0,"hourly":{"time":["2026-10-11T00:00","2026-10-11T01:00"],
            "wind_speed_100m_previous_day1":[5.0,5.0],"shortwave_radiation_previous_day1":[0.0,1.0],
            "cloud_cover_previous_day1":[10.0,null],"surface_pressure_previous_day1":[1000.0,1001.0]}}]"""
        p = parse_ml_res_response(body, [(48.0, 17.0)], "_previous_day1")
        @test collect(keys(p[(48.0, 17.0)])) == [DateTime(2026, 10, 11)]
        @test p[(48.0, 17.0)][DateTime(2026, 10, 11)] == (5.0, 0.0, 10.0, 1000.0)
    end

    @testset "skip diagnosis names the input" begin
        day = Date(2026, 9, 14)
        exp = expected_market_day_hours(day)
        fullz = Dict(h => 1.0 for h in exp)
        load = Dict("AT" => fullz, "BE" => fullz, "GR" => Dict(h => 1.0 for h in exp[1:10]))
        res = Dict("AT" => Dict{DateTime,Float64}(), "BE" => Dict{DateTime,Float64}(), "GR" => fullz)
        r = input_coverage_reasons(day, ["AT", "BE", "GR", "NL"], load, res;
                                   res_src=Dict("AT" => "ml", "BE" => "ml", "GR" => "ml"))
        @test r == ["RES[ml] 0/24 h: AT,BE (2)", "load[pack] 10/24 h: GR (1)",
                    "load[pack] absent + RES[pack] absent: NL (1)"]
        @test isempty(input_coverage_reasons(day, ["AT"], load, Dict("AT" => fullz)))
        # DST day: 25 expected hours
        @test input_coverage_reasons(Date(2026, 10, 25), ["AT"], Dict("AT" => fullz), Dict("AT" => fullz)) ==
              ["load[pack] 0/25 h + RES[pack] 0/25 h: AT (1)"]
    end
end
