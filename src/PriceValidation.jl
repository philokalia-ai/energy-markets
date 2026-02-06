"""
    PriceValidation

Functions for comparing simulated energy prices against actual ENTSO-E day-ahead prices.
"""

using Statistics

"""
    PriceComparisonResult

Result of comparing simulated vs actual prices for a set of time periods.
"""
struct PriceComparisonResult
    mae::Float64        # Mean Absolute Error (EUR/MWh)
    rmse::Float64       # Root Mean Squared Error (EUR/MWh)
    mape::Float64       # Mean Absolute Percentage Error (%)
    correlation::Float64 # Pearson correlation coefficient
    bias::Float64       # Mean bias (simulated - actual, EUR/MWh)
    n_periods::Int      # Number of matched time periods
end

"""
    compare_prices(simulated::Dict{String,Float64}, actual::Dict{String,Float64}) -> PriceComparisonResult

Compare simulated and actual price dictionaries (keyed by timeslot "YYYYMMDD-HHMM").
Only periods present in both dictionaries are compared.
"""
function compare_prices(simulated::Dict{String,Float64}, actual::Dict{String,Float64})
    # Find common timeslots
    common_keys = intersect(keys(simulated), keys(actual))

    if isempty(common_keys)
        @warn "No common time periods between simulated and actual prices"
        return PriceComparisonResult(NaN, NaN, NaN, NaN, NaN, 0)
    end

    sim_vals = Float64[simulated[k] for k in common_keys]
    act_vals = Float64[actual[k] for k in common_keys]
    n = length(sim_vals)

    errors = sim_vals .- act_vals
    abs_errors = abs.(errors)

    mae = mean(abs_errors)
    rmse = sqrt(mean(errors .^ 2))
    bias = mean(errors)

    # MAPE: skip periods where actual price is near zero to avoid division issues
    nonzero_mask = abs.(act_vals) .> 0.1
    mape = if any(nonzero_mask)
        mean(abs_errors[nonzero_mask] ./ abs.(act_vals[nonzero_mask])) * 100.0
    else
        NaN
    end

    # Pearson correlation
    corr = if n >= 2 && std(sim_vals) > 0 && std(act_vals) > 0
        cor(sim_vals, act_vals)
    else
        NaN
    end

    return PriceComparisonResult(mae, rmse, mape, corr, bias, n)
end

"""
    validate_energy_prices(zone::String, day::Date;
                           order_method::Symbol=:uc_based,
                           clearing_mode::String="single_zone") -> PriceComparisonResult

Convenience function that fetches both simulated and actual prices for a zone/day,
then compares them. Simulated prices are loaded from `simulations.energy_prices`,
actual prices from `entsoe.energy_prices`.

Prints a summary of the comparison metrics.
"""
function validate_energy_prices(zone::String, day::Dates.Date;
                                 order_method::Symbol=:uc_based,
                                 clearing_mode::String="single_zone")

    # Fetch actual prices
    actual = Euphemia.get_actual_day_ahead_prices(zone, day)
    if isempty(actual)
        println("No actual prices available for $zone on $day")
        return PriceComparisonResult(NaN, NaN, NaN, NaN, NaN, 0)
    end

    # Fetch simulated prices from database
    query = """
    SELECT date_time_utc, price_eur_mwh
    FROM simulations.energy_prices
    WHERE bidding_zone = \$1
      AND DATE(date_time_utc) = \$2
      AND order_method = \$3
      AND clearing_mode = \$4
    ORDER BY date_time_utc
    """
    df = Euphemia.sql2df_with_retry(query, [zone, day, string(order_method), clearing_mode])

    if nrow(df) == 0
        println("No simulated prices found for $zone on $day (order_method=$order_method, clearing_mode=$clearing_mode)")
        return PriceComparisonResult(NaN, NaN, NaN, NaN, NaN, 0)
    end

    simulated = Dict{String, Float64}()
    for row in eachrow(df)
        dt = row.date_time_utc
        timeslot = Dates.format(DateTime(dt), dateformat"yyyymmdd-HHMM")
        simulated[timeslot] = Float64(row.price_eur_mwh)
    end

    result = compare_prices(simulated, actual)

    # Print summary
    println("=" ^ 50)
    println("Price Validation: $zone on $day")
    println("  Order method: $order_method | Clearing mode: $clearing_mode")
    println("-" ^ 50)
    println("  Matched periods: $(result.n_periods)")
    println("  MAE:         $(round(result.mae, digits=2)) EUR/MWh")
    println("  RMSE:        $(round(result.rmse, digits=2)) EUR/MWh")
    println("  MAPE:        $(round(result.mape, digits=1))%")
    println("  Correlation: $(round(result.correlation, digits=3))")
    println("  Bias:        $(round(result.bias, digits=2)) EUR/MWh (sim - actual)")

    # Print price range comparison
    if !isempty(simulated) && !isempty(actual)
        sim_vals = collect(values(simulated))
        act_vals = collect(values(actual))
        println("-" ^ 50)
        println("  Simulated range: $(round(minimum(sim_vals), digits=1)) - $(round(maximum(sim_vals), digits=1)) EUR/MWh (avg $(round(mean(sim_vals), digits=1)))")
        println("  Actual range:    $(round(minimum(act_vals), digits=1)) - $(round(maximum(act_vals), digits=1)) EUR/MWh (avg $(round(mean(act_vals), digits=1)))")
    end
    println("=" ^ 50)

    return result
end
