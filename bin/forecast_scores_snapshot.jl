# Snapshot / compare / restore the HOURLY score columns of simulations.forecast_scores
# (#431 PR C2: the rollback for the SDAC target flip; used by rescore-hourly.yml).
#
#   julia --project=. bin/forecast_scores_snapshot.jl snapshot OUT.csv
#       every row's key + hourly columns (q15 columns are not touched by the
#       rescore and not saved). Reads only.
#   julia --project=. bin/forecast_scores_snapshot.jl compare SNAP.csv [summary.md]
#       per zone: rows, rows whose hourly MAE changed, mean MAE before/after, on the
#       rows present in both. Reads only. Appends a markdown table to summary.md.
#   CONFIRM_RESTORE=yes julia --project=. bin/forecast_scores_snapshot.jl restore SNAP.csv
#       writes the snapshot's hourly columns back onto the matching rows (rows scored
#       after the snapshot are left alone), one transaction per market date under
#       SET LOCAL lock_timeout '5s' (the #424 pattern). Postgres only.
using Euphemia, Dates, DataFrames, CSV, Statistics, Printf, LibPQ

const KEY = [:market_date, :bidding_zone, :lead_days, :code_version, :input_mode, :is_retro]
const HOURLY = [:n_hours, :mae, :bias, :corr, :n_collapse_actual, :n_collapse_pred,
                :collapse_hits, :collapse_false_alarms, :collapse_hit_rate,
                :collapse_false_alarm_rate, :reset_tag]

current() = Euphemia.sql2df_with_retry("""
    SELECT $(join(string.(vcat(KEY, HOURLY, [:scored_at])), ", "))
    FROM simulations.forecast_scores ORDER BY market_date, bidding_zone, lead_days,
         code_version, input_mode, is_retro""")

function snapshot(out)
    df = current()
    CSV.write(out, df)
    println("SNAPSHOT rows=$(nrow(df)) zones=$(length(unique(df.bidding_zone))) " *
            "dates=$(isempty(df) ? "-" : string(extrema(Date.(df.market_date)))) -> $out")
end

function load_snapshot(path)
    s = CSV.read(path, DataFrame; types=Dict(:bidding_zone => String, :input_mode => String,
                                             :reset_tag => String))
    s.market_date = Date.(s.market_date)
    s.is_retro = Bool.(s.is_retro)
    return s
end

function compare(path, summary=nothing)
    s = load_snapshot(path)
    c = current()
    c.market_date = Date.(c.market_date)
    m = innerjoin(select(s, KEY, :mae => :mae_before), select(c, KEY, :mae => :mae_after), on=KEY)
    io = IOBuffer()
    println(io, "| zone | rows | MAE changed | mean MAE before | mean MAE after |")
    println(io, "|---|---|---|---|---|")
    mu(x) = (v = collect(skipmissing(x)); isempty(v) ? NaN : mean(v))
    for g in groupby(sort(m, :bidding_zone), :bidding_zone)
        b, a = g.mae_before, g.mae_after
        ch = count(i -> !isequal(b[i], a[i]) &&
                        !(b[i] !== missing && a[i] !== missing && abs(b[i] - a[i]) <= 1e-9), eachindex(b))
        @printf(io, "| %s | %d | %d | %.3f | %.3f |\n", g.bidding_zone[1], nrow(g), ch,
                mu(b), mu(a))
    end
    @printf(io, "\nrows in snapshot %d, now %d, matched %d\n", nrow(s), nrow(c), nrow(m))
    txt = String(take!(io))
    print(txt)
    summary === nothing || open(f -> write(f, "\n### forecast_scores hourly MAE, snapshot vs now\n\n" * txt), summary, "a")
end

function restore(path)
    get(ENV, "CONFIRM_RESTORE", "") == "yes" || error("restore writes to forecast_scores: set CONFIRM_RESTORE=yes")
    s = load_snapshot(path)
    nn(x) = x === missing ? missing : x
    sets = join(("$c = \$$(i)" for (i, c) in enumerate(HOURLY)), ", ")
    k0 = length(HOURLY)
    wh = join(("$c = \$$(k0 + i)" for (i, c) in enumerate(KEY)), " AND ")
    sql = "UPDATE simulations.forecast_scores SET $sets, scored_at = now() WHERE $wh"
    n = 0
    for g in groupby(sort(s, :market_date), :market_date)
        Euphemia.withdb() do cnx
            LibPQ.execute(cnx, "BEGIN")
            try
                LibPQ.execute(cnx, "SET LOCAL lock_timeout = '5s'")
                LibPQ.execute(cnx, "SET LOCAL statement_timeout = '120s'")
                for r in eachrow(g)
                    LibPQ.execute(cnx, sql, Any[(nn(r[c]) for c in HOURLY)..., (r[c] for c in KEY)...])
                end
                LibPQ.execute(cnx, "COMMIT")
            catch
                try LibPQ.execute(cnx, "ROLLBACK") catch end
                rethrow()
            end
        end
        n += nrow(g)
    end
    println("RESTORED hourly columns of $n snapshot rows from $path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    cmd = get(ARGS, 1, "")
    cmd == "snapshot" ? snapshot(ARGS[2]) :
    cmd == "compare" ? compare(ARGS[2], get(ARGS, 3, nothing)) :
    cmd == "restore" ? restore(ARGS[2]) :
    error("usage: forecast_scores_snapshot.jl snapshot|compare|restore FILE [summary.md]")
end
