# Full re-clear checks of st-impact strategic optima. env JOBS = comma list of job files
# runs/st-impact/rc/<job>.csv with columns day,zone,hour,kind,price,mw  (kind = offer | carve).
# The company's offer enters as SimpleOrder supply; `carve` rows remove baseline supply priced exactly at `price`
# (the company's own book orders) via the harness Carve. Writes <job>.out.csv: hour,zone_price,accepted_mw,status.
using Euphemia, Dates, Printf
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
using Euphemia.MarketOrders: MarketOrder, SimpleOrder
const RC = joinpath(homedir(), "armada", "em-team", "strategy", "runs", "st-impact", "rc")
bases = Dict{Date,Any}()
for job in split(ENV["JOBS"], ",")
    f = joinpath(RC, "$job.csv"); out = joinpath(RC, "$job.out.csv")
    isfile(out) && (println("RC $job CACHED"); continue)
    rows = [split(l, ',') for l in Iterators.drop(eachline(f), 1)]
    day = Date(rows[1][1]); zone = String(rows[1][2])
    base = get!(() -> load_baseline(day), bases, day)
    ts(h) = DateTime(day) + Hour(h)
    per(h) = Dates.format(ts(h), "yyyymmdd-HHMM")
    company = MarketOrder[]
    carves = Carve[]
    for r in rows
        h = parse(Int, r[3]); p = parse(Float64, r[5]); mw = parse(Float64, r[6])
        mw <= 1e-6 && continue
        if r[4] == "offer"
            push!(company, SimpleOrder(:supply, p, mw, Symbol(zone), ts(h), 60))
        else
            # the book merges orders at round(price, 2) (book_build.jl:2253)
            pr2 = round(p, digits=2)
            push!(carves, Carve(zone, Dict(per(h) => mw), pr2 - 1e-6, pr2 + 1e-6; ref=pr2))
        end
    end
    t = time()
    r = reclear(base, company; carve=carves)
    acc = Dict{Int,Float64}()
    for (i, o) in enumerate(company)
        h = Dates.hour(o.date_time); acc[h] = get(acc, h, 0.0) + r.accepted[i]
    end
    short = sum(values(r.carve_shortfall); init=0.0)
    open(out * ".tmp", "w") do io
        println(io, "hour,zone_price,accepted_mw,status,carve_short_mw")
        for h in 0:23
            @printf(io, "%d,%.6f,%.4f,%s,%.3f\n", h, get(get(r.prices, zone, Dict{String,Float64}()), per(h), NaN),
                get(acc, h, 0.0), r.status, short)
        end
    end
    mv(out * ".tmp", out; force=true)
    println("RC $job DONE status=$(r.status) short=$(round(short; digits=2)) wall=$(round(time()-t; digits=1))s"); flush(stdout)
end
