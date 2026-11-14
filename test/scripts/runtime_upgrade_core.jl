# Self-contained regression selection for runtime/solver upgrades. The ordinary
# runtests.jl also contains historical database tests outside a small extract's
# coverage. Run this with an explicitly selected read-only DuckDB source.
using Euphemia, Test, Dates, JuMP

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const EXTRACT = ENV["EUPHEMIA_DUCKDB_PATH"]
const FILES = [
    "test_data_store_selection.jl", "test_duckdb_perf_paths.jl",
    "test_multi_zone_mpcc.jl", "test_mpcc.jl", "test_forecast_tracking.jl",
    "test_registry_unit_bound.jl", "test_registry_feed_anchor.jl",
    "test_weather_res.jl", "test_weather_load.jl", "test_ml_inputs.jl",
    "test_extract_refresh_logic.jl", "test_15min_resolution.jl",
    "test_zone_strategy_export.jl", "test_book_methodology_export.jl",
    "test_boundaries_export.jl", "test_price_reconstruction.jl",
    "test_review_2026_07.jl", "test_jao_scaling_order.jl",
]

@testset "Offline runtime upgrade" begin
    for file in FILES
        @testset "$file" begin
            try
                include(joinpath(ROOT, "test", file))
            finally
                # Several fixtures leave the synthetic connection active. Reset
                # it before the next file, preserving shared-source protection.
                Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true)
                Euphemia.clear_generator_caches!()
            end
        end
    end
end
