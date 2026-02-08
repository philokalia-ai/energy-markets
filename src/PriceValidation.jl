"""
    PriceValidation

Functions for comparing simulated energy prices against actual ENTSO-E day-ahead prices.
Handles resolution mismatches by resampling simulated prices to match actual resolution.
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
    resample_prices_to_resolution(prices::Dict{String,Float64}, source_minutes::Int, target_minutes::Int) -> Dict{String,Float64}

Resample price timeseries to a different temporal resolution.
- Aggregation (source finer than target): averages sub-period prices into target buckets.
- Disaggregation (source coarser than target): repeats the parent period price for each sub-period.
"""
function resample_prices_to_resolution(prices::Dict{String,Float64}, source_minutes::Int, target_minutes::Int)
    if source_minutes == target_minutes
        return prices
    end

    resampled = Dict{String,Float64}()

    if source_minutes < target_minutes
        # Aggregation: average fine-resolution prices into coarser buckets
        buckets = Dict{String, Vector{Float64}}()
        for (timeslot, price) in prices
            bucket_key = _timeslot_to_bucket(timeslot, target_minutes)
            if !haskey(buckets, bucket_key)
                buckets[bucket_key] = Float64[]
            end
            push!(buckets[bucket_key], price)
        end
        for (bucket_key, bucket_prices) in buckets
            resampled[bucket_key] = mean(bucket_prices)
        end
    else
        # Disaggregation: repeat coarse-resolution price for each fine sub-period
        for (timeslot, price) in prices
            sub_slots = _generate_sub_timeslots(timeslot, source_minutes, target_minutes)
            for sub_slot in sub_slots
                resampled[sub_slot] = price
            end
        end
    end

    return resampled
end

"""Floor a timeslot to the nearest bucket at target resolution."""
function _timeslot_to_bucket(timeslot::String, target_minutes::Int)
    date_part = timeslot[1:8]
    hour = parse(Int, timeslot[10:11])
    minute = parse(Int, timeslot[12:13])
    total_minutes = hour * 60 + minute

    bucket_minutes = (total_minutes ÷ target_minutes) * target_minutes
    bucket_hour = bucket_minutes ÷ 60
    bucket_minute = bucket_minutes % 60

    return "$(date_part)-$(lpad(bucket_hour, 2, '0'))$(lpad(bucket_minute, 2, '0'))"
end

"""Generate sub-timeslots for disaggregation from coarse to fine resolution."""
function _generate_sub_timeslots(timeslot::String, source_minutes::Int, target_minutes::Int)
    date_part = timeslot[1:8]
    hour = parse(Int, timeslot[10:11])
    minute = parse(Int, timeslot[12:13])
    total_minutes = hour * 60 + minute

    n_sub = source_minutes ÷ target_minutes
    slots = String[]
    for i in 0:(n_sub-1)
        sub_minutes = total_minutes + i * target_minutes
        sub_hour = sub_minutes ÷ 60
        sub_minute = sub_minutes % 60
        push!(slots, "$(date_part)-$(lpad(sub_hour, 2, '0'))$(lpad(sub_minute, 2, '0'))")
    end
    return slots
end


"""
    validate_energy_prices(zone::String, day::Date;
                           order_method::Symbol=:uc_based,
                           clearing_mode::String="single_zone") -> PriceComparisonResult

Convenience function that fetches both simulated and actual prices for a zone/day,
then compares them. Simulated prices are loaded from `simulations.energy_prices`,
actual prices from `entsoe.energy_prices`.

Automatically resamples simulated prices to match the actual ENTSO-E resolution
when they differ (e.g., simulated at 15-min, actual at hourly).

Prints a summary of the comparison metrics.
"""
function validate_energy_prices(zone::String, day::Dates.Date;
                                 order_method::Symbol=:uc_based,
                                 clearing_mode::String="single_zone")

    # Fetch actual prices with resolution
    actual_query = """
    SELECT date_time_utc, resolution_code, price_currency_mwh
    FROM entsoe.energy_prices
    WHERE map_code = \$1
      AND DATE(date_time_utc) = \$2
      AND contract_type = 'Day-ahead'
    ORDER BY date_time_utc
    """
    actual_df = Euphemia.sql2df_with_retry(actual_query, [zone, day])

    if nrow(actual_df) == 0
        println("No actual prices available for $zone on $day")
        return PriceComparisonResult(NaN, NaN, NaN, NaN, NaN, 0)
    end

    actual = Dict{String, Float64}()
    for row in eachrow(actual_df)
        timeslot = Dates.format(DateTime(row.date_time_utc), dateformat"yyyymmdd-HHMM")
        actual[timeslot] = Float64(row.price_currency_mwh)
    end

    # Detect actual resolution from resolution_code column
    actual_res_code = actual_df.resolution_code[1]
    actual_minutes = parse_resolution_to_minutes(string(actual_res_code))

    # Fetch simulated prices (filter by current code version to avoid stale data)
    sim_query = """
    SELECT date_time_utc, resolution_code, price_eur_mwh
    FROM simulations.energy_prices
    WHERE bidding_zone = \$1
      AND DATE(date_time_utc) = \$2
      AND order_method = \$3
      AND clearing_mode = \$4
      AND code_version = \$5
    ORDER BY date_time_utc
    """
    sim_df = Euphemia.sql2df_with_retry(sim_query, [zone, day, string(order_method), clearing_mode, Euphemia.CURRENT_CODE_VERSION])

    if nrow(sim_df) == 0
        println("No simulated prices found for $zone on $day (order_method=$order_method, clearing_mode=$clearing_mode)")
        return PriceComparisonResult(NaN, NaN, NaN, NaN, NaN, 0)
    end

    simulated = Dict{String, Float64}()
    for row in eachrow(sim_df)
        timeslot = Dates.format(DateTime(row.date_time_utc), dateformat"yyyymmdd-HHMM")
        simulated[timeslot] = Float64(row.price_eur_mwh)
    end

    # Detect simulated resolution from resolution_code column
    sim_res_code = sim_df.resolution_code[1]
    sim_minutes = parse_resolution_to_minutes(string(sim_res_code))

    # Resample simulated prices to match actual resolution if they differ
    if sim_minutes != actual_minutes
        println("  Resampling simulated prices: $(sim_minutes)min → $(actual_minutes)min")
        simulated = resample_prices_to_resolution(simulated, sim_minutes, actual_minutes)
    end

    result = compare_prices(simulated, actual)

    # Print summary
    println("=" ^ 50)
    println("Price Validation: $zone on $day")
    println("  Order method: $order_method | Clearing mode: $clearing_mode")
    if sim_minutes != actual_minutes
        println("  Resolution: sim=$(sim_minutes)min, actual=$(actual_minutes)min (resampled)")
    end
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
