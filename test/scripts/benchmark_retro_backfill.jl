# Offline timing/identity harness for run_retro's weather inputs and two UTC clears.
# See docs/experiments/retro-backfill-perf-2026-11/README.md. No forecast DB writes.
using Dates, Serialization, Printf, Statistics
const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const OUT = abspath(ENV["RETRO_PERF_OUT"])
mkpath(OUT)
const LABEL = get(ENV,"PERF_LABEL","replay")
const PHASE = Dict{String,Float64}()
function measured(f, name)
    t = time()
    try return f() finally PHASE[name] = get(PHASE,name,0.0) + time()-t end
end
get(ENV, "EUPHEMIA_DATA_STORE", "") == "duckdb" || error("benchmark requires DuckDB")
get(ENV, "EUPHEMIA_DUCKDB_READONLY", "") == "true" || error("benchmark requires a read-only extract")
ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"
t=time(); include(joinpath(ROOT,"bin/daily_forecast.jl")); PHASE["include"] = time()-t
@eval Euphemia begin
    const PERF_QUERIES = Dict{String,Tuple{Int,Float64}}()
    const PERF_QUERY_LOCK = ReentrantLock()
    function sql2df(sql, args=[])
        DATA_STORE[] == :duckdb || error("offline profiler forbids Postgres")
        lock(_DUCKDB_LOCK) do
            t=time()
            try return _duckdb_sql2df(sql,args) finally
                lock(PERF_QUERY_LOCK) do
                    n,s=get(PERF_QUERIES,sql,(0,0.0)); PERF_QUERIES[sql]=(n+1,s+time()-t)
                end
            end
        end
    end
end
# Instrument existing production expression bodies without changing arguments/results.
function instrument(ex)
    ex isa Expr || return ex
    if ex.head == :call && string(ex.args[1]) in ("_create_multi_zone_order_book_merit","mz_rebuild_anchored","MPCC.solve_mpcc_market_clearing","mz_solve_pass")
        label=string(ex.args[1]); return :(Main.measured(() -> $ex, $label))
    end
    return Expr(ex.head,map(instrument,ex.args)...)
end
Core.eval(Euphemia,instrument(Meta.parseall(read(joinpath(ROOT,"src/clearing/multi_zone_run.jl"),String))))
# Split native optimize time from JuMP construction, in this process only.
for file in ("solver.jl","complex_orders.jl")
    path=joinpath(ROOT,"src/mpcc",file)
    source=read(path,String)
    source=replace(source,"const LAST_COMPLEX_INFO = Ref{Any}(nothing)"=>"")
    source=replace(source,"optimize!(model)"=>"Main.measured(() -> optimize!(model), \"optimize\")")
    needle=file=="solver.jl" ? "# Solve the model\n" : "@objective(model, Max, obj - 10000.0 * sum(shed))\n"
    start=file=="solver.jl" ? "start_time" : "t0"
    source=replace(source,needle=>needle*"        Main.PHASE[\"model_build\"] = get(Main.PHASE, \"model_build\", 0.0) + time() - $start\n";count=1)
    Base.include_string(Euphemia.MPCC,source,path)
end
# Time public HTTP+retry work, preserving original routines. Cache is solely a local profiling artifact.
for (file, fun) in (("weather_load.jl",:_load_openmeteo_get),("weather_res.jl",:_openmeteo_get))
    ast=Meta.parseall(read(joinpath(ROOT,"bin",file),String))
    function finddef(ex)
        ex isa Expr || return nothing
        if ex.head == :function && ex.args[1] isa Expr && ex.args[1].head == :call && ex.args[1].args[1] == fun
            return ex
        end
        for arg in ex.args
            r=finddef(arg); r === nothing || return r
        end
        nothing
    end
    ex=deepcopy(finddef(ast)); orig=Symbol(fun,"_perf_original"); ex.args[1].args[1]=orig; Core.eval(Main,ex)
    Core.eval(Main,quote
        function $fun(url::String)
            measured(() -> $orig(url), "http_retry")
        end
    end)
end
const days = get(ENV,"PERF_DAYS_FROM_ENV","") == "1" ? collect(Date(ENV["EUPHEMIA_FORECAST_RETRO_START"]):Day(1):Date(ENV["EUPHEMIA_FORECAST_RETRO_ASOF"])) : isempty(ARGS) ? [Date("2026-09-14"),Date("2026-09-15")] : Date.(ARGS)
const first_utc, last_utc=minimum(days)-Day(1), maximum(days)
fixture=get(ENV,"PERF_FIXTURE",joinpath(OUT,"inputs-$(first_utc)-$(last_utc).jls"))
println("PERF_READY threads=", Threads.nthreads(), " label=", LABEL); flush(stdout)
if isfile(fixture)
    fill_pred,preds,solar_preds=deserialize(fixture)
else
    get(ENV, "RETRO_PERF_PREPARE", "") == "1" || error("missing saved inputs; explicitly set RETRO_PERF_PREPARE=1 to fetch public weather")
    candidates=Set(days)
    fill_pred=measured("load_weather_predict") do
        build_load_fills(load_load_models(),sort(copy(ZONES)),first_utc,last_utc,candidates;fixed_lag=1)
    end
    solar_preds=Dict{String,Dict{DateTime,Float64}}()
    preds=measured("res_weather_predict") do
        build_weather_predictions(first_utc,last_utc,candidates;fixed_lag=1,solar_out=solar_preds)
    end
    pilots=[z for z in ml_pilot_zones() if z in ZONES]
    if ML_INPUTS_ON && !isempty(pilots)
        measured("ml_inputs") do
            ms=Dict{String,Dict{DateTime,Float64}}()
            mr,ml=build_ml_inputs(pilots,first_utc,last_utc,candidates;fixed_lag=1,solar_out=ms)
            for (z,p) in mr; preds[z]=p; solar_preds[z]=get(ms,z,Dict{DateTime,Float64}()); end
            for (z,p) in ml; fill_pred[z]=p; end
        end
    end
    serialize(fixture,(fill_pred,preds,solar_preds))
end
println("PERF_PREP ",PHASE); flush(stdout)
scenario=weather_scenario(preds,fill_pred;solar_preds=solar_preds)
install_thermometer!(fill_pred,first_utc,last_utc)
Euphemia.Network.PREGATE_ATC_FALLBACK[]=true
cache=Dict{Date,Union{Nothing,Dict{String,Dict{DateTime,Float64}}}}()
for day in days
    @assert issubset(Set(ZONES),model_covered_for_day(day,fill_pred)) "load coverage $day"
    @assert issubset(Set(ZONES),res_covered_for_day(day,preds)) "RES coverage $day"
    empty!(PHASE); empty!(Euphemia.PERF_QUERIES)
    t=time(); cpu0=ccall(:clock,Clong,())/1e6
    ctx=Euphemia.ForecastContext(day,DateTime(day-Day(1))+Hour(6)+Minute(30),1,:fixed_10utc,"retro:cv44-backfill-2026-11")
    prev,curr=Euphemia.with_context(ctx) do
        p=clear_utc_day!(cache,day-Day(1);scenario=scenario)
        c=clear_utc_day!(cache,day;scenario=scenario)
        (p,c)
    end
    @assert prev !== nothing && curr !== nothing
    open(joinpath(OUT, "$LABEL-$day-utc.csv"), "w") do io
        println(io, "zone,time,price")
        for book in (prev, curr), z in sort(collect(keys(book))), h in sort(collect(keys(book[z])))
            println(io, "$z,$h,$(book[z][h])")
        end
    end
    rows=Tuple{String,String,Float64}[]
    for z in sort(ZONES)
        for h in expected_market_day_hours(day)
            dict=Date(h)==day ? curr[z] : prev[z]
            push!(rows,(z,string(h),dict[h]))
        end
    end
    measured("write_csv") do
        open(joinpath(OUT,"$LABEL-$day.csv"),"w") do io
            println(io,"zone,time,price"); for r in rows; println(io,join(r,",")); end
        end
    end
    sql_s=sum(v[2] for v in values(Euphemia.PERF_QUERIES)); sql_n=sum(v[1] for v in values(Euphemia.PERF_QUERIES))
    println("PERF_DAY $day wall=",time()-t," sql=",sql_s," queries=",sql_n," rss=",Sys.maxrss()," cpu_seconds=",ccall(:clock,Clong,())/1e6-cpu0," threads=",Threads.nthreads()," phases=",PHASE)
    open(joinpath(OUT,"queries-$LABEL-$day.tsv"),"w") do io
        for (s,(n,t)) in sort(collect(Euphemia.PERF_QUERIES);by=x->-last(x)[2]); println(io,n,'\t',t,'\t',replace(s,r"\s+"=>" ")); end
    end
    flush(stdout)
end
