#!/usr/bin/env julia
# forecast_presence.jl — what a daily-forecast run left in Postgres, read from its run-local results DuckDB only
# (no Postgres access): ceres' retry loop dispatches daily-forecast.yml once per attempt and decides from this
# artifact whether the lead-1 slice exists, instead of querying Postgres.
#
# A slice counts as present when its rows are in the results DB and either came from the fill's seed (they were
# in Postgres at fill time) or were written by an op of this run that the transfer applied (transfer_ops.done_at
# set: marked only after the Postgres commit). A write whose transfer did not commit is reported, not counted.
#
# usage: julia --project=. bin/forecast_presence.jl --results-db PATH --input-mode MODE --lead1-date YYYY-MM-DD
#                                                   --out presence.json [--profile P] [--dispatch-id ID]
# Prints one summary line (also for $GITHUB_STEP_SUMMARY) and writes the JSON:
#   {dispatch_id, run_profile, input_mode, lead1_date, lead1: {present, rows, zones},
#    slices: [{market_date, lead_days, input_mode, rows, zones, source: seeded|transferred|not_transferred}]}
using DuckDB, DataFrames, Dates, JSON

function parse_cli(argv)
    o = Dict{String,String}("profile" => "", "dispatch-id" => "")
    i = 1
    while i <= length(argv)
        startswith(argv[i], "--") || error("unexpected argument $(argv[i])")
        o[argv[i][3:end]] = argv[i+1]; i += 2
    end
    for k in ("results-db", "input-mode", "lead1-date", "out")
        haskey(o, k) || error("--$k is required")
    end
    return o
end

q(con, sql, args=Any[]) = DataFrame(isempty(args) ? DBInterface.execute(con, sql) :
                                    DBInterface.execute(DBInterface.prepare(con, sql), args))

"""Per (market_date, lead_days, input_mode) slice from `lead1_date` on: rows/zones and where they come from."""
function presence(path::AbstractString, input_mode::AbstractString, lead1_date::Date)
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    try
        DBInterface.execute(con, "ATTACH '$(replace(path, "'" => "''"))' AS r (READ_ONLY)")
        has_ops = !isempty(q(con, "SELECT 1 FROM information_schema.tables WHERE table_catalog = 'r' " *
                                  "AND table_schema = 'simulations' AND table_name = 'transfer_ops'"))
        done = has_ops ? "LEFT JOIN r.simulations.transfer_ops o ON o.op_id = f.transfer_op_id" :
                         "LEFT JOIN (SELECT NULL::BIGINT AS op_id, NULL::TIMESTAMP AS done_at) o ON false"
        df = q(con, """
            SELECT f.market_date, f.lead_days, f.input_mode,
                   CASE WHEN f.transfer_op_id IS NULL THEN 'seeded'
                        WHEN o.done_at IS NOT NULL THEN 'transferred' ELSE 'not_transferred' END AS source,
                   COUNT(*) AS rows, COUNT(DISTINCT f.bidding_zone) AS zones
            FROM r.simulations.forecast_prices f $done
            WHERE f.market_date >= \$1 AND f.is_retro = false AND f.input_mode LIKE \$2 || '%'
            GROUP BY ALL ORDER BY ALL""", Any[lead1_date, input_mode])
        return df
    finally
        DBInterface.close!(con)
    end
end

function main()
    o = parse_cli(ARGS)
    d1 = Date(o["lead1-date"]); mode = o["input-mode"]
    df = presence(o["results-db"], mode, d1)
    l1 = df[(df.market_date .== d1) .& (df.lead_days .== 1) .& (df.input_mode .== mode) .& (df.source .!= "not_transferred"), :]
    lead1 = Dict("present" => nrow(l1) > 0 && sum(l1.rows) > 0,
                 "rows" => isempty(l1) ? 0 : Int(sum(l1.rows)), "zones" => isempty(l1) ? 0 : Int(maximum(l1.zones)))
    out = Dict("dispatch_id" => o["dispatch-id"], "run_profile" => o["profile"], "input_mode" => mode,
               "lead1_date" => string(d1), "lead1" => lead1,
               "slices" => [Dict("market_date" => string(r.market_date), "lead_days" => Int(r.lead_days),
                                 "input_mode" => String(r.input_mode), "rows" => Int(r.rows), "zones" => Int(r.zones),
                                 "source" => String(r.source)) for r in eachrow(df)])
    open(o["out"], "w") do io; JSON.print(io, out, 2); end
    nt = count(==("not_transferred"), df.source)
    println("lead-1 $(d1) $(mode): ", lead1["present"] ? "PRESENT ($(lead1["rows"]) rows, $(lead1["zones"]) zones)" : "MISSING",
            " | slices this run transferred: ", count(==("transferred"), df.source),
            nt > 0 ? " | NOT transferred: $nt" : "")
end

abspath(PROGRAM_FILE) == @__FILE__() && main()
