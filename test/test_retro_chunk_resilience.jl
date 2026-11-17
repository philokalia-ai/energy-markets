# Retro backfill resilience (#431 R3 follow-up, run 44083012266): the on-disk
# previous-runs cache keyed by the exact request, the per-chunk public breaker, the
# public weighted-call cost lines and the grid-aligned retro chunks. Pure: the HTTP
# layer is a stub closure, the cache a temp dir. No network, no DB.
#   julia --project=. test/test_retro_chunk_resilience.jl

using Test, Dates

isdefined(@__MODULE__, :parse_openmeteo_response) ||
    include(joinpath(@__DIR__, "..", "bin", "weather_res.jl"))
isdefined(@__MODULE__, :retro_aligned_chunks) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))

function _rcr_body(cells, hours; isnull=(c, h) -> false)
    locs = map(cells) do c
        t = join(("\"" * Dates.format(h, "yyyy-mm-ddTHH:MM") * "\"" for h in hours), ",")
        v = join((isnull(c, h) ? "null" : "7.5" for h in hours), ",")
        g = join((isnull(c, h) ? "null" : "100.0" for h in hours), ",")
        """{"latitude":$(c[1]),"longitude":$(c[2]),"hourly":{"time":[$t],""" *
        """"wind_speed_100m_previous_day1":[$v],"shortwave_radiation_previous_day1":[$g]}}"""
    end
    return "[" * join(locs, ",") * "]"
end

@testset "retro chunk resilience (#431 R3 follow-up)" begin
    @testset "open-meteo weighted-call cost (server formula)" begin
        @test openmeteo_call_weight(1, 15, 14) ≈ 1.5     # open-meteo pricing page example
        @test openmeteo_call_weight(1, 15, 28) ≈ 3.0     # "4 weeks equals 3.0"
        @test openmeteo_call_weight(50, 2, 15) == 50     # pack RES/load batch, 14-day chunk
        @test openmeteo_call_weight(50, 4, 35) == 50     # ML RES: flat up to 35 days
        @test openmeteo_call_weight(50, 4, 36) ≈ 50 * 0.4 * 36 / 14
        u = "http://h/v1/forecast?latitude=48.0,49.0,50.0&longitude=1,2,3&hourly=a_previous_day1,b_previous_day1" *
            "&models=gfs_seamless&start_date=2026-09-13&end_date=2026-09-27&timezone=UTC"
        @test openmeteo_url_shape(u) == (locations=3, variables=2, days=15)
        @test openmeteo_url_shape("http://h/v1/forecast?latitude=1&hourly=a,b,c&models=m1,m2").variables == 6
        @test openmeteo_url_shape("http://h/x") === nothing
        @test _is_public_openmeteo("https://previous-runs-api.open-meteo.com/v1/forecast?x=1")
        @test _is_public_openmeteo("https://api.open-meteo.com/v1/forecast")
        @test !_is_public_openmeteo("http://open-meteo.weather.svc.cluster.local/v1/forecast?x")
        @test !_is_public_openmeteo("http://127.0.0.1:8080/v1/forecast?u=open-meteo.com")
    end

    @testset "cache: only past previous-run windows, exact request" begin
        today = Date(2026, 11, 17)
        @test _openmeteo_cacheable("h?hourly=a_previous_day1&end_date=2026-11-16"; today)
        @test !_openmeteo_cacheable("h?hourly=a_previous_day1&end_date=2026-11-17"; today)   # touches today
        @test !_openmeteo_cacheable("h?hourly=a&end_date=2026-10-01"; today)                 # live lag 0
        @test length(_openmeteo_cache_key("x")) == 32 && _openmeteo_cache_key("x") != _openmeteo_cache_key("y")
        @test _openmeteo_cache_key("abc") == "e71fa2190541574b" * string(_fnv1a64("abc", 0x84222325cbf29ce4); base=16, pad=16)
        dir = mktempdir()
        u = "https://previous-runs-api.open-meteo.com/v1/forecast?latitude=1&hourly=a_previous_day1&end_date=2026-10-01"
        withenv("EUPHEMIA_OPENMETEO_CACHE_DIR" => nothing) do
            @test !_openmeteo_cache_write(u, "B") && _openmeteo_cache_read(u) === nothing   # off by default
        end
        withenv("EUPHEMIA_OPENMETEO_CACHE_DIR" => dir) do
            @test _openmeteo_cache_read(u) === nothing
            @test _openmeteo_cache_write(u, "BODY")
            @test _openmeteo_cache_read(u) == "BODY"
            @test _openmeteo_cache_read(u * "&x=1") === nothing                 # a different request
            write(joinpath(dir, _openmeteo_cache_key(u) * ".url"), u * "#")      # stem collision guard
            @test _openmeteo_cache_read(u) === nothing
        end
    end

    cells = [(48.0, 17.0), (49.0, 18.0)]
    hours = openmeteo_request_hours(Date(2026, 10, 11), Date(2026, 10, 12))
    PRI = "http://open-meteo.local/v1/forecast"; PUB = "https://previous-runs-api.open-meteo.com/v1/forecast"
    url = PRI * "?latitude=48.0,49.0&longitude=17.0,18.0&hourly=wind_speed_100m_previous_day1,shortwave_radiation_previous_day1" *
          "&models=gfs_seamless&start_date=2026-10-11&end_date=2026-10-12&timezone=UTC"
    parse = b -> parse_openmeteo_response(b, cells; var_suffix="_previous_day1")
    full = _rcr_body(cells, hours)
    allnull = _rcr_body(cells, hours; isnull=(c, h) -> true)
    partial = _rcr_body(cells, hours; isnull=(c, h) -> h < DateTime(2026, 10, 12, 3))
    stub(primary; public=full, calls=String[]) = u -> begin
        push!(calls, u)
        b = startswith(u, PUB) ? public : primary
        b isa Exception ? throw(b) : b
    end
    run(get_fn; u=url) = _fetch_batch_with_fallback("res", u, PRI, PUB, cells, hours; get_fn,
                                                    parse_fn=parse, prevruns=true, can_fallback=true)

    @testset "driver + cache: a re-dispatch never re-fetches" begin
        dir = mktempdir()
        withenv("EUPHEMIA_OPENMETEO_CACHE_DIR" => dir, "EUPHEMIA_OPENMETEO_GAPFILL" => "1") do
            # all-null primary → public; both answers looked up, only the complete public one stored
            reset_weather_fetch_log!()
            calls = String[]
            r = run(stub(allnull; calls))
            @test _batch_missing_cell_hours(r, cells, hours) == 0 && length(calls) == 2
            @test count(f -> endswith(f, ".json"), readdir(dir)) == 1
            s = weather_fetch_summary()[1]
            @test occursin("public API 1 request(s) ≈2 weighted call(s), cache hits 0", s)
            # the re-dispatch: primary asked again (not cached: it was all-null), public from disk
            reset_weather_fetch_log!()
            calls2 = String[]
            r2 = run(stub(allnull; calls=calls2, public=ErrorException("429 exhausted")))
            @test r2 == r && length(calls2) == 1 && startswith(calls2[1], PRI)
            @test occursin("public API 0 request(s) ≈0 weighted call(s), cache hits 1", weather_fetch_summary()[1])
            # partial primary: the public gap answer is cached, the partial primary is not
            rm(dir; recursive=true); mkpath(dir)
            calls3 = String[]
            run(stub(partial; calls=calls3))
            @test length(calls3) == 2 && count(f -> endswith(f, ".json"), readdir(dir)) == 1
            calls4 = String[]
            r4 = run(stub(partial; calls=calls4, public=ErrorException("429 exhausted")))
            @test _batch_missing_cell_hours(r4, cells, hours) == 0 && length(calls4) == 1
            # a complete self-hosted answer is cached too (no request at all next time)
            rm(dir; recursive=true); mkpath(dir)
            run(stub(full)); calls5 = String[]
            @test _batch_missing_cell_hours(run(stub(ErrorException("down"); calls=calls5)), cells, hours) == 0
            @test isempty(calls5)
        end
        # cache off (the default): every run goes to the network, as before
        withenv("EUPHEMIA_OPENMETEO_CACHE_DIR" => nothing) do
            calls = String[]
            run(stub(allnull; calls)); run(stub(allnull; calls))
            @test length(calls) == 4
        end
    end

    @testset "breaker: one exhausted public request per chunk, retro only" begin
        withenv("EUPHEMIA_OPENMETEO_CACHE_DIR" => nothing) do
            try
                openmeteo_breaker_arm!(true)
                reset_weather_fetch_log!()
                calls = String[]
                g = stub(allnull; calls, public=ErrorException("open-meteo request failed after 6 attempts: 429"))
                @test_throws ErrorException run(g)
                @test length(calls) == 2                     # primary + the exhausted public
                @test_throws ErrorException run(g)
                @test length(calls) == 3                     # primary only: public skipped
                # a partial batch keeps its primary hours (gap-fill skipped, not fatal)
                r = run(stub(partial; calls))
                @test _batch_missing_cell_hours(r, cells, hours) == 54
                s = weather_fetch_summary()[1]
                @test occursin("FAILED 2", s) && occursin("1 failed, 2 skipped (breaker)", s)
                # next chunk: breaker closed again
                reset_weather_fetch_log!()
                calls2 = String[]
                @test _batch_missing_cell_hours(run(stub(allnull; calls=calls2)), cells, hours) == 0
                @test length(calls2) == 2
            finally
                openmeteo_breaker_arm!(false)
            end
            # not armed (the live run): every request still goes out
            reset_weather_fetch_log!()
            calls = String[]
            g = stub(allnull; calls, public=ErrorException("429"))
            @test_throws ErrorException run(g)
            @test_throws ErrorException run(g)
            @test length(calls) == 4
        end
    end

    @testset "budget lines: worst case, rate and request size" begin
        log = NamedTuple[]
        rec(nloc, nvars, ndays; pub=false) = (kind="x", cellhours=0, primary_missing=0, action=:none,
            final_missing=0, primary_first=nothing, public_ok=false,
            weight=openmeteo_call_weight(nloc, nvars, ndays), nvars=nvars, ndays=ndays,
            pub_req=pub ? 1 : 0, pub_weight=pub ? openmeteo_call_weight(nloc, nvars, ndays) : 0.0,
            pub_fail=0, pub_skip=0, cache_hits=pub ? 0 : 1)
        # production shape of one 14-day chunk (UTC span 15 days): pack RES 1425 cells (2 vars),
        # load 175 cities ×2 (2 vars, span+2 days), ML RES 1425 cells (4 vars)
        for _ in 1:28; push!(log, rec(50, 2, 15; pub=true)); end
        push!(log, rec(25, 2, 15))
        for _ in 1:7; push!(log, rec(50, 2, 17)); end
        for _ in 1:28; push!(log, rec(50, 4, 15)); end
        push!(log, rec(25, 4, 15))
        ls = openmeteo_budget_lines(log; span_days=15, chunk_days=14, n_zone_calls=156, throttle_s=0.6)
        @test length(ls) == 4
        @test occursin("28 request(s), ≈1400 weighted call(s) spent, 37 cache hit(s)", ls[1])
        @test occursin("≈3200 weighted calls", ls[2])
        @test occursin("at most 1 such chunk(s) per hour and 2 per day", ls[2])
        @test occursin("≥ 6 min of fetching", ls[3]) && occursin("now 0.6 s", ls[3])
        @test occursin("a chunk of up to 34 day(s)", ls[4]) && occursin("≈229 calls/day at 14-day chunks, ≈94 at 34", ls[4])
        @test isempty(openmeteo_budget_lines(NamedTuple[]; span_days=15, chunk_days=14, n_zone_calls=1, throttle_s=0))
    end

    @testset "grid-aligned retro chunks" begin
        a = Date(2026, 9, 14)
        days = collect(Date(2026, 9, 14):Day(1):Date(2026, 10, 3))
        ch = retro_aligned_chunks(days, 14; anchor=a, last_day=Date(2026, 11, 15))
        @test [c.days for c in ch] == [days[1:14], days[15:end]]
        @test ch[2].first_utc == Date(2026, 9, 27) && ch[2].last_utc == Date(2026, 10, 11)   # whole cell
        # a re-dispatch resuming mid-cell fetches the SAME span (same requests → cache hits)
        ch2 = retro_aligned_chunks(days[18:end], 14; anchor=a, last_day=Date(2026, 11, 15))
        @test length(ch2) == 1 && (ch2[1].first_utc, ch2[1].last_utc) == (ch[2].first_utc, ch[2].last_utc)
        # a written day in the middle splits the run (clear cache) but not the fetch span
        ch3 = retro_aligned_chunks(setdiff(days, [Date(2026, 9, 20)]), 14; anchor=a, last_day=Date(2026, 11, 15))
        @test length(ch3) == 3 && ch3[1].first_utc == ch3[2].first_utc == Date(2026, 9, 13)
        # days before the anchor and the end clip
        ch4 = retro_aligned_chunks([Date(2026, 9, 10), Date(2026, 11, 14)], 14; anchor=a, last_day=Date(2026, 11, 15))
        @test ch4[1].first_utc == Date(2026, 8, 30) && ch4[1].last_utc == Date(2026, 9, 13)
        @test ch4[2].last_utc == Date(2026, 11, 15)
        @test_throws ErrorException retro_aligned_chunks(days, 0; anchor=a, last_day=a)
    end
end
