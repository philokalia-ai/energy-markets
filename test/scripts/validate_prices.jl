"""
Batch price validation script.

Compares simulated energy prices against actual ENTSO-E day-ahead prices
for a date range and set of zones.

Usage:
    julia --project=. test/scripts/validate_prices.jl

Environment variables:
    START_DATE   - Start date (default: 7 days ago)
    END_DATE     - End date (default: yesterday)
    ZONES        - Comma-separated zone list (default: auto-discover)
    ORDER_METHOD - uc_based or alternative (default: uc_based)
    CLEARING_MODE - single_zone, multi_zone, multi_zone_iterative (default: single_zone)
"""

using Euphemia
using Dates
using Statistics

# Parse configuration from environment
start_date = Date(get(ENV, "START_DATE", string(today() - Day(7))))
end_date = Date(get(ENV, "END_DATE", string(today() - Day(1))))
order_method = Symbol(get(ENV, "ORDER_METHOD", "uc_based"))
clearing_mode = get(ENV, "CLEARING_MODE", "single_zone")

zones_str = get(ENV, "ZONES", "")
zones = if isempty(zones_str)
    try
        get_available_zones(start_date)
    catch
        @warn "Could not auto-discover zones, using default set"
        ["GR", "BG", "RO", "HU"]
    end
else
    split(zones_str, ",") .|> strip .|> String
end

println("=" ^ 70)
println("BATCH PRICE VALIDATION")
println("=" ^ 70)
println("Date range: $start_date to $end_date")
println("Zones: $(join(zones, ", "))")
println("Order method: $order_method")
println("Clearing mode: $clearing_mode")
println()

# Collect results per zone
zone_results = Dict{String, Vector{Euphemia.PriceComparisonResult}}()

for zone in zones
    zone_results[zone] = Euphemia.PriceComparisonResult[]

    for day in start_date:Day(1):end_date
        try
            result = validate_energy_prices(zone, day;
                                             order_method=order_method,
                                             clearing_mode=clearing_mode)
            if result.n_periods > 0
                push!(zone_results[zone], result)
            end
        catch e
            @warn "Failed for $zone on $day: $e"
        end
    end
end

# Print summary table
println("\n" * "=" ^ 70)
println("SUMMARY")
println("=" ^ 70)
println()
println(rpad("Zone", 12) *
        rpad("Days", 6) *
        rpad("MAE", 12) *
        rpad("RMSE", 12) *
        rpad("MAPE%", 10) *
        rpad("Corr", 8) *
        rpad("Bias", 10))
println("-" ^ 70)

for zone in zones
    results = zone_results[zone]
    if isempty(results)
        println(rpad(zone, 12) * "No data")
        continue
    end

    n_days = length(results)
    avg_mae = mean([r.mae for r in results])
    avg_rmse = mean([r.rmse for r in results])
    avg_mape = mean(filter(!isnan, [r.mape for r in results]))
    avg_corr = mean(filter(!isnan, [r.correlation for r in results]))
    avg_bias = mean([r.bias for r in results])

    println(rpad(zone, 12) *
            rpad(string(n_days), 6) *
            rpad("$(round(avg_mae, digits=1))", 12) *
            rpad("$(round(avg_rmse, digits=1))", 12) *
            rpad("$(round(avg_mape, digits=1))", 10) *
            rpad("$(round(avg_corr, digits=3))", 8) *
            rpad("$(round(avg_bias, digits=1))", 10))
end

println("=" ^ 70)
