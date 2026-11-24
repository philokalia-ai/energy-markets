# Snapshot / compare / restore the HOURLY score columns of simulations.forecast_scores
# (#431 PR C2: the rollback for the SDAC target flip; used by rescore-hourly.yml).
#
#   julia --project=. bin/forecast_scores_snapshot.jl snapshot OUT.csv
#       every row's key + hourly columns (q15 columns are not touched by the
#       rescore and not saved). Reads only.
#   julia --project=. bin/forecast_scores_snapshot.jl compare SNAP.csv [summary.md]
#       per zone: rows, rows whose hourly MAE changed, mean MAE before/after, on the
#       rows present in both. Reads only. Appends a markdown table to summary.md.
#   CONFIRM_RESTORE=yes julia --project=. bin/forecast_scores_snapshot.jl restore SNAP.csv KEYS.csv
#       CAMPAIGN-SCOPED rollback of one rescore run. KEYS.csv is that run's campaign record
#       (score_forecasts.jl RESCORE_KEYS_OUT: every key it wrote + the scored_at it wrote).
#       Only those keys are restored, and only while their scored_at is still the
#       campaign's: a row rescored later (daily window, another run) is skipped and
#       counted. Restored rows get the snapshot's hourly columns AND its scored_at back,
#       i.e. exactly their pre-campaign state; a key the campaign created (absent from the
#       snapshot) is reported, not deleted. One transaction per market date under
#       SET LOCAL lock_timeout '5s' (the #424 pattern). Postgres only.
using Euphemia, Dates, DataFrames, CSV, Statistics, Printf, LibPQ

const KEY = [:market_date, :bidding_zone, :lead_days, :code_version, :input_mode, :is_retro]
const HOURLY = [:n_hours, :mae, :bias, :corr, :n_collapse_actual, :n_collapse_pred,
                :collapse_hits, :collapse_false_alarms, :collapse_hit_rate,
                :collapse_false_alarm_rate, :reset_tag]

# scored_at as text: exact (microseconds, offset), so a restore can put it back verbatim. On the DuckDB backend
# (fill → run → transfer: the fill seeds the whole table) the column is naive UTC, rendered with the same offset.
_scored_at_text() = Euphemia.results_to_duckdb() ?
    "strftime(scored_at, '%Y-%m-%d %H:%M:%S.%f') || '+00'" : "scored_at::text"
current() = Euphemia.sql2df_with_retry("""
    SELECT $(join(string.(vcat(KEY, HOURLY)), ", ")), $(_scored_at_text()) AS scored_at
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
                                             :reset_tag => String, :scored_at => String))
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

function load_keys(path)
    k = CSV.read(path, DataFrame; types=Dict(:bidding_zone => String, :input_mode => String,
                                             :campaign_scored_at => String))
    k.market_date = Date.(k.market_date)
    k.is_retro = Bool.(k.is_retro)
    return unique(k, KEY; keep=:last)   # a key written twice: its last campaign stamp
end

function restore(path, keys_path)
    get(ENV, "CONFIRM_RESTORE", "") == "yes" || error("restore writes to forecast_scores: set CONFIRM_RESTORE=yes")
    s = load_snapshot(path)
    k = load_keys(keys_path)
    todo = innerjoin(k, s, on=KEY)
    created = nrow(antijoin(k, s, on=KEY))
    Euphemia.results_to_duckdb() && return restore_duckdb(todo, k, created)
    nn(x) = x === missing ? missing : x
    cols = vcat(HOURLY, [:scored_at])
    sets = join(("$c = \$$(i)" for (i, c) in enumerate(HOURLY)), ", ") *
           ", scored_at = \$$(length(HOURLY) + 1)::timestamptz"
    k0 = length(cols)
    wh = join(("$c = \$$(k0 + i)" for (i, c) in enumerate(KEY)), " AND ") *
         " AND scored_at = \$$(k0 + length(KEY) + 1)::timestamptz"
    sql = "UPDATE simulations.forecast_scores SET $sets WHERE $wh"
    restored = skipped = 0
    for g in groupby(sort(todo, :market_date), :market_date)
        Euphemia.withdb() do cnx
            LibPQ.execute(cnx, "BEGIN")
            try
                LibPQ.execute(cnx, "SET LOCAL lock_timeout = '5s'")
                LibPQ.execute(cnx, "SET LOCAL statement_timeout = '120s'")
                for r in eachrow(g)
                    res = LibPQ.execute(cnx, sql, Any[(nn(r[c]) for c in cols)..., (r[c] for c in KEY)...,
                                                      r.campaign_scored_at])
                    LibPQ.num_affected_rows(res) == 1 ? (restored += 1) : (skipped += 1)
                end
                LibPQ.execute(cnx, "COMMIT")
            catch
                try LibPQ.execute(cnx, "ROLLBACK") catch end
                rethrow()
            end
        end
    end
    println("RESTORE campaign keys=$(nrow(k)): restored=$restored, skipped (rescored after the " *
            "campaign)=$skipped, created by the campaign (not in snapshot, left as is)=$created")
    return (restored=restored, skipped=skipped, created=created)
end

"Text stamp (Postgres timestamptz text or ours, '+00' offset) → a DuckDB TIMESTAMP expression, cast in DuckDB."
_ts_sql(p) = "CAST(regexp_replace($p, '\\+00(:00)?\$', '') AS TIMESTAMP)"

"""restore under fill → run → transfer: the same conditional UPDATE on the run-local forecast_scores (the fill
seeded the whole table), and one score_restore op whose rows (snapshot values + both stamps) the transfer replays
with the same condition inside Postgres. Counts are against the seeded state, i.e. Postgres at fill time."""
function restore_duckdb(todo, k, created)
    Euphemia.ensure_run_results_tables!()
    R = "results_db.simulations"
    nh = length(HOURLY); nk = length(KEY)
    sets = join(("$c = \$$(i)" for (i, c) in enumerate(HOURLY)), ", ") * ", scored_at = $(_ts_sql("\$$(nh + 1)"))"
    wh = join(("$c = \$$(nh + 1 + i)" for (i, c) in enumerate(KEY)), " AND ") *
         " AND scored_at = $(_ts_sql("\$$(nh + nk + 2)"))"
    ins = "INSERT INTO $R.transfer_score_restore VALUES (" * join(("\$$i" for i in 1:(1 + nk + nh + 2)), ", ") * ")"
    restored = skipped = 0
    Euphemia.results_transaction() do
        op = Euphemia.log_transfer_op!("score_restore", Dict("n" => nrow(todo)))
        for r in eachrow(todo)
            vals = Any[(r[c] === nothing ? missing : r[c] for c in HOURLY)...]
            key = Any[(r[c] for c in KEY)...]
            before = Int(Euphemia._results_exec("SELECT COUNT(*) AS n FROM $R.forecast_scores WHERE " *
                replace(wh, r"\$(\d+)" => m -> "\$" * string(parse(Int, m[2:end]) - nh - 1)),
                vcat(key, Any[String(r.campaign_scored_at)])).n[1])
            if before == 1
                Euphemia._results_exec("UPDATE $R.forecast_scores SET $sets WHERE $wh",
                    vcat(vals, Any[String(r.scored_at)], key, Any[String(r.campaign_scored_at)]))
                restored += 1
            else
                skipped += 1
            end
            Euphemia._results_exec(ins, vcat(Any[op], key, vals,
                                             Any[String(r.scored_at), String(r.campaign_scored_at)]))
        end
    end
    println("RESTORE (run-local; replayed by the transfer) campaign keys=$(nrow(k)): restored=$restored, " *
            "skipped (rescored after the campaign)=$skipped, created by the campaign (left as is)=$created")
    return (restored=restored, skipped=skipped, created=created)
end

if abspath(PROGRAM_FILE) == @__FILE__
    cmd = get(ARGS, 1, "")
    cmd == "snapshot" ? snapshot(ARGS[2]) :
    cmd == "compare" ? compare(ARGS[2], get(ARGS, 3, nothing)) :
    cmd == "restore" ? restore(ARGS[2], ARGS[3]) :
    error("usage: forecast_scores_snapshot.jl snapshot FILE | compare SNAP [summary.md] | restore SNAP KEYS")
end
