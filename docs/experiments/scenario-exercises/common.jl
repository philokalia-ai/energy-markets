# Shared runner for the GR scenario exercises (see README.md in this directory).
#
# All runs are OFFLINE against the living DuckDB extract: the source data is
# opened read-only and market results are persisted to the separate writable
# results DB (data/results.duckdb by default, override EUPHEMIA_RESULTS_DB).
#
# The loop is RESUMABLE: before solving, it queries the results DB for days that
# already have a full set of prices under the target clearing_mode label and
# skips them. Failures are logged and skipped (reported at the end).
#
# Usage: `include("common.jl")` from one of the exercise scripts, then call
#   run_labeled(label, start_date, end_date; scenario hooks as kwargs...)

# Select the DuckDB backend BEFORE `using Euphemia` so module init never
# touches Postgres (fully offline).
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT_PATH = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    normpath(joinpath(@__DIR__, "..", "..", "..", "data", "extracts", "euphemia-live.duckdb")))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT_PATH
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates

# Read-only source + writable results DB (data/results.duckdb).
configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT_PATH,
    read_only=true, results_writable=true)

"Days that already have a complete (>= 24 rows) price set under `label`."
function existing_days(label::String; zone::String="GR")
    df = Euphemia.sql2df("""
        SELECT CAST(date_time_utc AS DATE) AS d, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE bidding_zone = \$1 AND clearing_mode = \$2
        GROUP BY 1
        """, Any[zone, label])
    nrow_ok = df.n .>= 24
    return Set(Date.(df.d[nrow_ok]))
end

"""
    run_labeled(label, start_date, end_date; zone="GR", hooks...)

Resumable day loop: `generate_energy_prices(zone, day; order_method=:merit_order,
save_to_db=true, clearing_mode=label, hooks...)` for every day in the window
that is not already saved. Returns (solved, skipped, failed_days).
"""
function run_labeled(label::String, start_date::Date, end_date::Date;
                     zone::String="GR", kwargs...)
    done = existing_days(label; zone=zone)
    days = collect(start_date:Day(1):end_date)
    todo = [d for d in days if !(d in done)]
    @info "[$label] window $start_date..$end_date: $(length(days)) days, " *
          "$(length(done) == 0 ? 0 : length(days) - length(todo)) already saved, $(length(todo)) to solve"
    failed = Date[]
    t0 = time()
    for (i, d) in enumerate(todo)
        try
            prices = generate_energy_prices(zone, d;
                order_method=:merit_order, optimizer="highs",
                save_to_db=true, clearing_mode=label, kwargs...)
            if isempty(prices)
                push!(failed, d)
                @error "[$label] $d returned no prices — skipped"
            end
        catch e
            push!(failed, d)
            @error "[$label] $d failed — skipped" exception = (e, catch_backtrace())
        end
        if i % 25 == 0
            rate = i / (time() - t0)
            @info "[$label] $i/$(length(todo)) days ($(round(rate; digits=2))/s, $(length(failed)) failed)"
        end
    end
    solved = length(todo) - length(failed)
    @info "[$label] DONE: $solved solved, $(length(days) - length(todo)) skipped (already saved), $(length(failed)) failed" failed
    return (solved=solved, skipped=length(days) - length(todo), failed=failed)
end
