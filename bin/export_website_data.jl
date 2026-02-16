#!/usr/bin/env julia
"""
Export datasets from PostgreSQL to Parquet and JSON files for the website.

Generates:
  - Parquet files for each dataset in website/public/data/
  - JSON files for chart components (per-zone price comparison)
  - catalog.json with dataset metadata

Usage:
  julia --project=. bin/export_website_data.jl

Environment variables:
  ZONES          Comma-separated zone codes (default: auto-discover)
  START_DATE     Export start date YYYY-MM-DD (default: 2024-01-01)
  END_DATE       Export end date YYYY-MM-DD (default: 2024-12-31)
"""

using Dates
using DataFrames

# Load Euphemia module (provides DB access)
include(joinpath(@__DIR__, "..", "src", "Euphemia.jl"))
using .Euphemia

# Check for Arrow and JSON3
try
    @eval using Arrow
catch
    @error "Arrow.jl not installed. Run: julia -e \"using Pkg; Pkg.add(\\\"Arrow\\\")\""
    exit(1)
end

try
    @eval using JSON3
catch
    @error "JSON3.jl not installed. Run: julia -e \"using Pkg; Pkg.add(\\\"JSON3\\\")\""
    exit(1)
end

const OUTPUT_DIR = joinpath(@__DIR__, "..", "website", "public", "data")
mkpath(OUTPUT_DIR)

# Parse configuration
start_date = Dates.Date(get(ENV, "START_DATE", "2024-01-01"))
end_date = Dates.Date(get(ENV, "END_DATE", "2024-12-31"))
zone_str = get(ENV, "ZONES", "")

@info "Export configuration" start_date end_date output_dir=OUTPUT_DIR

# --- Helper ---

function export_parquet(df::DataFrame, name::String)
    path = joinpath(OUTPUT_DIR, "$name.parquet")
    Arrow.write(path, df)
    @info "Exported $name" rows=nrow(df) path
    return (name=name, rows=nrow(df), path=path)
end

# --- Energy Prices ---

function export_energy_prices()
    @info "Exporting energy prices..."
    query = """
    SELECT ep.date_time_utc, ep.bidding_zone, ep.price, ep.contract_type,
           ep.order_method, ep.clearing_mode, ep.optimizer, ep.code_version,
           opr.solve_time_seconds, opr.objective_value
    FROM simulations.energy_prices ep
    LEFT JOIN simulations.optimization_runs opr ON ep.optimization_run_id = opr.id
    WHERE ep.date_time_utc >= \$1 AND ep.date_time_utc < \$2
    ORDER BY ep.bidding_zone, ep.date_time_utc
    """
    df = Euphemia.sql2df_with_retry(query, [start_date, end_date + Day(1)])
    if nrow(df) > 0
        export_parquet(df, "energy_prices")
    else
        @warn "No energy prices found for date range"
    end
    return df
end

# --- Optimization Runs ---

function export_optimization_runs()
    @info "Exporting optimization runs..."
    query = """
    SELECT * FROM simulations.optimization_runs
    WHERE optimization_date >= \$1 AND optimization_date <= \$2
    ORDER BY optimization_date, bidding_zone
    """
    df = Euphemia.sql2df_with_retry(query, [start_date, end_date])
    if nrow(df) > 0
        export_parquet(df, "optimization_runs")
    end
    return df
end

# --- Transmission Flows ---

function export_transmission_flows()
    @info "Exporting transmission flows..."
    query = """
    SELECT * FROM simulations.transmission_flows
    WHERE date_time_utc >= \$1 AND date_time_utc < \$2
    ORDER BY date_time_utc
    """
    df = Euphemia.sql2df_with_retry(query, [start_date, end_date + Day(1)])
    if nrow(df) > 0
        export_parquet(df, "transmission_flows")
    end
    return df
end

# --- Inferred Generator Parameters ---

function export_inferred_parameters()
    @info "Exporting inferred generator parameters..."
    query = """
    SELECT * FROM simulations.generator_inferred_parameters
    ORDER BY bidding_zone, generator_code
    """
    df = Euphemia.sql2df_with_retry(query, [])
    if nrow(df) > 0
        export_parquet(df, "inferred_parameters")
    end
    return df
end

# --- Price Comparison JSON (for charts) ---

function export_price_comparison_json(prices_df::DataFrame)
    if nrow(prices_df) == 0
        @warn "No prices to export for charts"
        return
    end

    @info "Exporting price comparison JSON for charts..."

    # Get actual ENTSO-E prices for comparison
    zones = unique(prices_df.bidding_zone)

    for zone in zones
        zone_sim = filter(r -> r.bidding_zone == zone, prices_df)
        if nrow(zone_sim) == 0
            continue
        end

        # Try to get actual prices
        actual_prices = try
            query = """
            SELECT date_time_utc, price
            FROM entsoe.day_ahead_prices
            WHERE map_code = \$1
              AND date_time_utc >= \$2 AND date_time_utc < \$3
            ORDER BY date_time_utc
            """
            Euphemia.sql2df_with_retry(query, [zone, start_date, end_date + Day(1)])
        catch e
            @warn "Could not fetch actual prices for $zone: $e"
            DataFrame()
        end

        timestamps = [Dates.format(dt, "yyyy-mm-dd HH:MM") for dt in zone_sim.date_time_utc]

        chart_data = Dict(
            "zone" => zone,
            "timestamps" => timestamps,
            "simulated" => round.(zone_sim.price, digits=1),
            "actual" => nrow(actual_prices) > 0 ?
                round.(actual_prices.price, digits=1) :
                fill(nothing, length(timestamps))
        )

        path = joinpath(OUTPUT_DIR, "prices-$(lowercase(zone)).json")
        open(path, "w") do io
            JSON3.write(io, chart_data)
        end
        @info "Exported chart data for $zone" periods=length(timestamps) path
    end
end

# --- Catalog ---

function export_catalog(entries::Vector)
    catalog = Dict(
        "generated_at" => Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
        "date_range" => Dict("start" => string(start_date), "end" => string(end_date)),
        "datasets" => [Dict("name" => e.name, "rows" => e.rows) for e in entries if e !== nothing]
    )
    path = joinpath(OUTPUT_DIR, "catalog.json")
    open(path, "w") do io
        JSON3.write(io, catalog)
    end
    @info "Exported catalog" path
end

# --- Main ---

function main()
    @info "Starting website data export..."
    catalog_entries = []

    prices_df = export_energy_prices()
    if nrow(prices_df) > 0
        push!(catalog_entries, (name="energy_prices", rows=nrow(prices_df)))
    end

    for export_fn in [export_optimization_runs, export_transmission_flows, export_inferred_parameters]
        try
            df = export_fn()
            if nrow(df) > 0
                # name derived from function name
                fname = string(Symbol(export_fn))
                push!(catalog_entries, (name=fname, rows=nrow(df)))
            end
        catch e
            @warn "Export failed" fn=export_fn error=e
        end
    end

    # Generate chart JSON
    export_price_comparison_json(prices_df)

    # Write catalog
    export_catalog(catalog_entries)

    @info "Export complete!" total_datasets=length(catalog_entries) output_dir=OUTPUT_DIR
end

main()
