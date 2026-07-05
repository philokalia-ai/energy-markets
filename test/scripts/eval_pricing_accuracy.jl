# Pricing accuracy evaluation harness.
#
# Generates day-ahead prices for a fixed set of benchmark days and compares
# them against actual DAM prices from entsoe.energy_prices. Used to measure
# whether pricing changes move simulated prices closer to reality.
#
# Usage:
#   julia --project=. test/scripts/eval_pricing_accuracy.jl [order_method]
#
# order_method: alternative (default) or uc_based

using Euphemia
using Dates
using Statistics
using Printf

# Fixed benchmark days (seeded random picks, seasonally diverse, all with
# complete GR DAM/load/renewables/TTF data). Do not tune on other days and
# then eval here — these are the held-out benchmark.
const EVAL_DAYS = [Date(2023, 12, 1), Date(2025, 4, 26), Date(2025, 7, 2), Date(2026, 1, 26)]
const ZONE = "GR"
const RANDOM_SEED = 42

function fetch_actual_prices(zone::String, day::Date)
    df = Euphemia.sql2df_with_retry(
        """
        SELECT to_char(date_time_utc AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MI') AS slot,
               price_currency_mwh
        FROM entsoe.energy_prices
        WHERE map_code = \$1 AND contract_type = 'Day-ahead'
          AND date_time_utc >= \$2::date AND date_time_utc < \$2::date + 1
        ORDER BY date_time_utc
        """,
        [zone, day]
    )
    return Dict{String,Float64}(row.slot => row.price_currency_mwh for row in eachrow(df))
end

function eval_day(zone::String, day::Date, order_method::Symbol)
    t0 = time()
    sim = generate_energy_prices(zone, day;
        order_method=order_method,
        optimizer="highs",
        save_to_db=false,
        random_seed=RANDOM_SEED)
    elapsed = time() - t0

    actual = fetch_actual_prices(zone, day)

    sim_v = Float64[]
    act_v = Float64[]
    for k in sort(collect(keys(sim)))
        haskey(actual, k) || continue
        push!(sim_v, sim[k])
        push!(act_v, actual[k])
    end

    isempty(sim_v) && return nothing

    d = sim_v .- act_v
    mae = mean(abs.(d))
    rmse = sqrt(mean(d .^ 2))
    bias = mean(d)
    # corr is NaN for constant simulated prices; report as 0 (no tracking skill)
    c = std(sim_v) < 1e-9 ? 0.0 : cor(sim_v, act_v)

    return (day=day, n=length(sim_v), mae=mae, rmse=rmse, bias=bias, corr=c,
        act_mean=mean(act_v), sim_mean=mean(sim_v), elapsed=elapsed)
end

function main()
    order_method = length(ARGS) >= 1 ? Symbol(ARGS[1]) : :alternative

    println("Pricing accuracy eval | zone=$ZONE method=$order_method seed=$RANDOM_SEED")
    println("day          n     MAE    RMSE    bias    corr   act_mean  sim_mean   time")

    results = []
    for day in EVAL_DAYS
        r = eval_day(ZONE, day, order_method)
        if r === nothing
            println(day, "  -- no overlapping data --")
            continue
        end
        push!(results, r)
        @printf("%s  %3d  %6.2f  %6.2f  %+6.2f  %6.3f  %8.2f  %8.2f  %5.1fs\n",
            r.day, r.n, r.mae, r.rmse, r.bias, r.corr, r.act_mean, r.sim_mean, r.elapsed)
    end

    if !isempty(results)
        println("-"^78)
        @printf("AGGREGATE    mean MAE %6.2f | mean RMSE %6.2f | mean bias %+6.2f | mean corr %6.3f\n",
            mean(r.mae for r in results), mean(r.rmse for r in results),
            mean(r.bias for r in results), mean(r.corr for r in results))
    end
end

main()
