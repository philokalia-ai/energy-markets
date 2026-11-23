#!/usr/bin/env julia
# measure_duckdb_path.jl — timing (and a price cross-check) of the current Postgres read path vs the fill → DuckDB
# path, for .github/workflows/measure-duckdb-path.yml (perf-96; owner rule 2026-11-23). READ-ONLY: it clears with
# save_to_db=false and never writes Postgres or the results DuckDB.
#
#   clear:   julia --project=. bin/measure_duckdb_path.jl clear --days 2026-11-18,2026-11-19 --label pg --out DIR
#                [--entry forecast|record]   forecast (default) = the daily forecast's call (run_multi_zone_market_clearing,
#                passes=2): the timing production runs every day; record = the pipelined record's stage functions
#                (bit-identical to the record, so also comparable with it). Both backends must use the same entry.
#            The backend is whatever the environment selects: ENERGY_CONN_STR + EUPHEMIA_DATA_STORE=postgres for the
#            current path; EUPHEMIA_DATA_STORE=duckdb + EUPHEMIA_DUCKDB_PATH=<filled inputs> for the DuckDB path.
#            Each day: the chosen entry's clear (gate context, two passes), with per-day wall time. Writes DIR/prices_<label>.csv and
#            DIR/times_<label>.csv.
#            --trace: every source read (Euphemia.sql2df, both backends; the caller's pre-rewrite SQL) is recorded in
#            DIR/trace_<label>.tsv (day, caller, SQL hash, args, rows, fingerprint of the canonical sorted rows), and
#            the canonical rows of every read of ≤ TRACE_ROWS_MAX rows in DIR/trace_rows_<label>.tsv.
#   compare: julia --project=. bin/measure_duckdb_path.jl compare DIR/prices_pg.csv DIR/prices_duckdb.csv --out DIR
#            Cell-by-cell comparison; every differing cell listed with its |Δ| and class (bit-identical / ≤2e-12
#            tie class / beyond), plus DIR/summary.md (also appended to $GITHUB_STEP_SUMMARY when set).
#   trace-diff:  ... trace-diff DIR/trace_pg.tsv DIR/trace_duckdb.tsv --out DIR  → DIR/trace_diff.tsv (every read
#            whose results differ, keyed by day + SQL + args) and DIR/trace_rows_diff.tsv (the differing rows).
#   fill-sums:   ... fill-sums RUN_DIR/inputs.duckdb OUT.tsv  → per table: rows, order-free content checksum,
#            max(update_time_utc) when the table has it (the ingest stamp).
#   fill-diff:   ... fill-diff A/inputs.duckdb B/inputs.duckdb --out DIR  → DIR/fill_diff.tsv (per table: rows
#            only in A / only in B) and DIR/fill_rows_diff.tsv (up to 200 such rows per table and side).
# trace-diff, fill-sums and fill-diff need no data store (fill-* open the files read-only with DuckDB.jl).
const _T_PROCESS0 = time()   # process wall: measured here (the runner image has no /usr/bin/time)
using Dates, Printf
# Euphemia (and its data-store init) only for `clear`: `compare` is a pure CSV comparison and needs no store.
const _CMD = isempty(ARGS) ? "" : ARGS[1]
_CMD == "clear" && @eval using Euphemia
_CMD in ("fill-sums", "fill-diff") && @eval using DuckDB
"Peak resident memory of this process (kB), from the kernel."
peak_rss_kb() = try parse(Int, match(r"VmHWM:\s*(\d+)", read("/proc/self/status", String))[1]) catch; -1 end

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
const TIE = 2e-12

function opt(args, k, default=nothing)
    i = findfirst(==(k), args)
    i === nothing ? default : args[i+1]
end

usable(r) = r.status == :optimal || (r.status == :time_limit && !isempty(r.market_prices))

"""The record's clear of one day: the stage functions PipelinedBackfill's workers call (as_of=:gate), in one
process — mz_build_books → mz_solve_pass → mz_extract_anchor_inputs → mz_rebuild_anchored → mz_solve_pass, pass 2
accepted when usable (else pass 1). Bit-identical to the pipelined record (perf-96 profile driver vs arm A)."""
function record_clear(d::Date)
    gate(f) = Euphemia.with_context(f, Euphemia.gate_context(d))
    kw = (optimizer="highs", silent=true, mpcc_time_limit=900.0, mpcc_mip_gap=1e-6, mpcc_heuristic_effort=nothing,
          decompose_periods=true)
    ob1 = gate(() -> mz_build_books(FOOTPRINT, d; enrich_network=true, apply_zone_profiles=true, scenario=nothing))
    r1 = mz_solve_pass(ob1; kw...)
    usable(r1) || return r1
    ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
    isempty(ai.anchored) && return r1
    ob2 = gate(() -> mz_rebuild_anchored(FOOTPRINT, d, ai.refs, ai.cached; enrich_network=true,
                                         apply_zone_profiles=true, scenario=nothing))
    r2 = mz_solve_pass(ob2; kw...)
    return usable(r2) ? r2 : r1
end

"""The daily forecast's clear of one UTC day (bin/daily_forecast.jl clear_utc_day!: run_multi_zone_market_clearing,
passes=2, enrich_network), here under the day's gate context and without the weather-track scenario."""
forecast_clear(d::Date) = Euphemia.with_context(Euphemia.gate_context(d)) do
    run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order, optimizer="highs",
        silent=true, save_to_db=false, enrich_network=true, passes=2)
end

# ---------------------------------------------------------------------------------------------------------------
# read trace (--trace): diagnostics only; installed through Euphemia.SQL_TRACE, which is a no-op when unset
# ---------------------------------------------------------------------------------------------------------------
const TRACE_ROWS_MAX = 20_000
const TRACE_DAY = Ref("init")
const TRACE_LOCK = ReentrantLock()
const TRACE = Vector{Any}()
_canon(v) = v === missing || v === nothing ? "∅" :
            v isa Bool ? string(v) :
            v isa Number ? string(round(Float64(v); sigdigits=12)) :
            v isa DateTime ? Dates.format(v, "yyyy-mm-ddTHH:MM:SS.sss") :
            v isa Date ? string(v) :
            occursin("ZonedDateTime", string(typeof(v))) ? Dates.format(DateTime(v, Dates.UTC), "yyyy-mm-ddTHH:MM:SS.sss") :
            v isa AbstractVector ? "[" * join((_canon(x) for x in v), ",") * "]" :
            replace(string(v), r"[\t\n]" => " ")
_argstr(a) = a isa AbstractVector ? "[" * join(string.(a), ",") * "]" : _canon(a)
function _caller()
    for fr in stacktrace()
        f = String(fr.file)
        (occursin("/src/db/", f) || occursin("measure_duckdb_path", f) || !occursin("/src/", f) ||
         (occursin("Network.jl", f) && fr.func === :safe_sql2df)) && continue
        return string(basename(f), ":", fr.line, " ", fr.func)
    end
    return "?"
end
function _trace_record(sql, args, df)
    rows = sort!([join((_canon(x) for x in r), "|") for r in eachrow(df)])
    sqlh = string(hash(replace(String(sql), r"\s+" => " ")) % 0xffffffff, base=16)
    afull = join((_argstr(x) for x in args), " | ")
    a = first(afull, 400)                                   # display only
    # key: the full args with list arguments sorted (they are `= ANY(...)` sets, often built from a Set whose
    # iteration order differs between processes)
    akey = join((x isa AbstractVector ? "[" * join(sort(string.(x)), ",") * "]" : _argstr(x) for x in args), " | ")
    rec = (day=TRACE_DAY[], caller=_caller(), sqlhash=sqlh, args=a, argh=string(hash(akey), base=16), rows=length(rows),
           fp=string(hash(join(rows, "\n")), base=16), body=length(rows) <= TRACE_ROWS_MAX ? rows : String[],
           cols=join(names(df), "|"))
    lock(() -> push!(TRACE, rec), TRACE_LOCK)
end
function write_trace(out, label)
    open(joinpath(out, "trace_$label.tsv"), "w") do io
        println(io, "day\tcaller\tsqlhash\targh\targs\trows\tfp\tcols")
        for r in TRACE
            println(io, join((r.day, r.caller, r.sqlhash, r.argh, replace(r.args, "\t" => " "), r.rows, r.fp, r.cols), "\t"))
        end
    end
    open(joinpath(out, "trace_rows_$label.tsv"), "w") do io
        println(io, "day\tsqlhash\targh\trow")
        for r in TRACE, row in r.body
            println(io, join((r.day, r.sqlhash, r.argh, row), "\t"))
        end
    end
    println("trace: $(length(TRACE)) reads → trace_$label.tsv (+ rows of reads ≤ $TRACE_ROWS_MAX rows)")
end

function clear(args)
    days = Date.(split(opt(args, "--days"), ","))
    label = opt(args, "--label"); out = opt(args, "--out"); mkpath(out)
    entry = opt(args, "--entry", "forecast")
    entry in ("forecast", "record") || error("--entry must be forecast or record")
    clear1 = entry == "forecast" ? forecast_clear : record_clear
    trace = "--trace" in args
    trace && (Euphemia.SQL_TRACE[] = _trace_record)
    println("measure clear: backend=$(Euphemia.DATA_STORE[]) entry=$entry label=$label days=$(join(days, ","))")
    open(joinpath(out, "prices_$label.csv"), "w") do pio
        open(joinpath(out, "times_$label.csv"), "w") do tio
            println(pio, "day,zone,period,price"); println(tio, "day,wall_s,status")
            for d in days
                stop = get(ENV, "STOP_FILE", "")
                if !isempty(stop) && isfile(stop)   # the workflow watchdog saw a forecast/publish job start
                    println("STOP: $(strip(read(stop, String))) — measurement stopped before $d"); exit(3)
                end
                TRACE_DAY[] = string(d)
                t0 = time()
                r = clear1(d)
                wall = time() - t0
                prices = r === nothing ? Dict() : r.market_prices
                for z in sort(collect(keys(prices))), (p, v) in sort(collect(prices[z]))
                    println(pio, d, ",", z, ",", p, ",", repr(v))
                end
                status = r === nothing ? "failed" : string(r.status)
                println(tio, d, ",", round(wall, digits=2), ",", status); flush(tio); flush(pio)
                @printf("  %s  %7.1f s  %s  %d zones\n", d, wall, status, length(prices))
            end
        end
    end
    open(joinpath(out, "process_$label.csv"), "w") do io
        println(io, "label,process_wall_s,peak_rss_kb")
        println(io, label, ",", round(time() - _T_PROCESS0, digits=2), ",", peak_rss_kb())
    end
    trace && (Euphemia.SQL_TRACE[] = nothing; write_trace(out, label))
end

function readp(f)
    d = Dict{Tuple{String,String,String},Float64}()
    for (i, l) in enumerate(eachline(f))
        i == 1 && continue
        a = split(l, ","); d[(a[1], a[2], a[3])] = parse(Float64, a[4])
    end
    return d
end

function compare(args)
    fa, fb = args[2], args[3]; out = opt(args, "--out", dirname(fa))
    a, b = readp(fa), readp(fb)
    keys_all = sort(collect(union(keys(a), keys(b))))
    same = 0; tie = 0; beyond = 0; missing_ = 0
    open(joinpath(out, "diff_cells.csv"), "w") do io
        println(io, "day,zone,period,a,b,abs_diff,class")
        for k in keys_all
            if !haskey(a, k) || !haskey(b, k)
                missing_ += 1; println(io, join(k, ","), ",", get(a, k, ""), ",", get(b, k, ""), ",,missing"); continue
            end
            va, vb = a[k], b[k]
            if reinterpret(UInt64, va) == reinterpret(UInt64, vb)
                same += 1
            else
                dlt = abs(va - vb); cls = dlt <= TIE ? "tie" : "beyond"
                cls == "tie" ? (tie += 1) : (beyond += 1)
                println(io, join(k, ","), ",", repr(va), ",", repr(vb), ",", repr(dlt), ",", cls)
            end
        end
    end
    ta = joinpath(dirname(fa), replace(basename(fa), "prices_" => "times_"))
    tb = joinpath(dirname(fb), replace(basename(fb), "prices_" => "times_"))
    wall(f) = isfile(f) ? sum(parse(Float64, split(l, ",")[2]) for (i, l) in enumerate(eachline(f)) if i > 1) : NaN
    pa = joinpath(dirname(fa), replace(basename(fa), "prices_" => "process_"))
    pb = joinpath(dirname(fb), replace(basename(fb), "prices_" => "process_"))
    proc(f) = isfile(f) ? split(collect(eachline(f))[2], ",") : ["-", "-", "-"]
    s = """
    ### DuckDB path measurement
    | | $(basename(fa)) | $(basename(fb)) |
    |---|---|---|
    | cells | $(length(a)) | $(length(b)) |
    | Σ day wall (s) | $(round(wall(ta), digits=1)) | $(round(wall(tb), digits=1)) |
    | process wall (s) | $(proc(pa)[2]) | $(proc(pb)[2]) |
    | peak RSS (kB) | $(proc(pa)[3]) | $(proc(pb)[3]) |

    Cells: bit-identical $same, tie class (≤$TIE) $tie, beyond $beyond, missing on one side $missing_
    (every differing cell is in diff_cells.csv).
    """
    write(joinpath(out, "summary.md"), s)
    haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> write(io, s), ENV["GITHUB_STEP_SUMMARY"], "a")
    print(s)
    return beyond == 0 && missing_ == 0
end

# ---------------------------------------------------------------------------------------------------------------
# trace-diff: which reads returned different rows on the two backends (keyed by day + SQL + args; a key read
# several times is compared as a multiset of fingerprints, so thread interleaving does not matter)
# ---------------------------------------------------------------------------------------------------------------
function readtsv(f)
    L = collect(eachline(f)); h = split(L[1], "\t")
    [Dict(zip(h, split(l, "\t"; limit=length(h)))) for l in L[2:end]]
end
function trace_diff(args)
    fa, fb = args[2], args[3]; out = opt(args, "--out", dirname(fa))
    la, lb = splitext(basename(fa))[1][7:end], splitext(basename(fb))[1][7:end]   # trace_<label>
    A, B = readtsv(fa), readtsv(fb)
    key(r) = (r["day"], r["sqlhash"], r["argh"])
    ga = Dict{Any,Vector{Any}}(); gb = Dict{Any,Vector{Any}}()
    for r in A; push!(get!(ga, key(r), Any[]), r); end
    for r in B; push!(get!(gb, key(r), Any[]), r); end
    bad = Any[]
    for k in sort(collect(union(keys(ga), keys(gb))))
        fa_ = sort([r["fp"] for r in get(ga, k, Any[])]); fb_ = sort([r["fp"] for r in get(gb, k, Any[])])
        fa_ == fb_ && continue
        ra = get(ga, k, Any[]); rb = get(gb, k, Any[])
        r0 = isempty(ra) ? rb[1] : ra[1]
        push!(bad, (k, r0["caller"], join((r["rows"] for r in ra), ","), join((r["rows"] for r in rb), ","),
                    r0["cols"], r0["args"]))
    end
    open(joinpath(out, "trace_diff.tsv"), "w") do io
        println(io, "day\tcaller\tsqlhash\targh\targs\trows_$la\trows_$lb\tcols")
        for (k, c, na, nb, cols, ar) in bad
            println(io, join((k[1], c, k[2], k[3], ar, na, nb, cols), "\t"))
        end
    end
    # differing rows (reads whose rows were kept on both sides)
    ra_f = joinpath(dirname(fa), "trace_rows_$la.tsv"); rb_f = joinpath(dirname(fb), "trace_rows_$lb.tsv")
    badkeys = Set(first.(bad)); nrowsdiff = 0
    if isfile(ra_f) && isfile(rb_f)
        rows(f) = (d = Dict{Any,Vector{String}}();
                   for (i, l) in enumerate(eachline(f))
                       i == 1 && continue
                       p = split(l, "\t"; limit=4); k = (p[1], p[2], p[3])
                       k in badkeys && push!(get!(d, k, String[]), p[4])
                   end; d)
        RA, RB = rows(ra_f), rows(rb_f)
        open(joinpath(out, "trace_rows_diff.tsv"), "w") do io
            println(io, "day\tsqlhash\targh\tside\trow")
            for k in sort(collect(badkeys))
                a = get(RA, k, String[]); b = get(RB, k, String[])
                ca = Dict{String,Int}(); for x in a; ca[x] = get(ca, x, 0) + 1; end
                cb = Dict{String,Int}(); for x in b; cb[x] = get(cb, x, 0) + 1; end
                n = 0
                for (x, c) in sort(collect(ca)), _ in 1:max(0, c - get(cb, x, 0))
                    (n += 1) <= 500 && println(io, join((k..., "only_$la", x), "\t")); nrowsdiff += 1
                end
                n = 0
                for (x, c) in sort(collect(cb)), _ in 1:max(0, c - get(ca, x, 0))
                    (n += 1) <= 500 && println(io, join((k..., "only_$lb", x), "\t")); nrowsdiff += 1
                end
            end
        end
    end
    s = "\n### Read trace: $la vs $lb\n$(length(A)) / $(length(B)) reads; $(length(bad)) read key(s) with different " *
        "results (trace_diff.tsv), $nrowsdiff differing row(s) in trace_rows_diff.tsv. A read listed on one side only " *
        "raised (no rows) or was not made (different args) on the other.\n" *
        join(("- $(k[1]) `$c` ($(first(ar, 60))) rows $(isempty(na) ? "—" : na) vs $(isempty(nb) ? "—" : nb)"
              for (k, c, na, nb, _, ar) in first(bad, 20)), "\n") * "\n"
    open(io -> write(io, s), joinpath(out, "summary.md"), "a")
    haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> write(io, s), ENV["GITHUB_STEP_SUMMARY"], "a")
    print(s)
end

# ---------------------------------------------------------------------------------------------------------------
# fill-sums / fill-diff: did Postgres change between two fills of the same days? (DuckDB.jl only, read-only)
# ---------------------------------------------------------------------------------------------------------------
_q(con, sql) = collect(DBInterface.execute(con, sql))
function _tables(con, cat)
    [(String(r.table_schema), String(r.table_name)) for r in _q(con,
        "SELECT table_schema, table_name FROM information_schema.tables WHERE table_catalog = '$cat' " *
        "AND table_schema NOT IN ('_fill', 'information_schema', 'pg_catalog') AND table_type = 'BASE TABLE' ORDER BY 1, 2")]
end
_hascol(con, cat, s, t, c) = !isempty(_q(con, "SELECT 1 FROM information_schema.columns WHERE table_catalog = '$cat' " *
    "AND table_schema = '$s' AND table_name = '$t' AND column_name = '$c'"))
"Per-table rows + order-free content checksum (count and bit_xor of the row hashes) of attached catalog `cat`."
_cheap(con, cat, s, t) = (r = _q(con, "SELECT count(*) AS n, CAST(bit_xor(hash(x)) AS VARCHAR) AS h FROM $cat.$s.$t AS x")[1];
                          (r.n, coalesce(r.h, "-")))
# outage tables: also a checksum over the message keys (mRID = instance_code, version, outage interval) and the
# latest publication stamp, so a changed or re-versioned message shows even when only its text columns moved
const OUTAGE_KEY = ["instance_code", "version", "start_outage_utc", "end_outage_utc"]
function fill_sums(args)
    f, outf = args[2], args[3]
    db = DuckDB.DB(":memory:"); con = DBInterface.connect(db)
    DBInterface.execute(con, "ATTACH '$(replace(f, "'" => "''"))' AS a (READ_ONLY)")
    open(outf, "w") do io
        println(io, "table\trows\tchecksum\tmax_update_time_utc\tkey_checksum\tmax_version_publication_utc")
        for (s, t) in _tables(con, "a")
            n, h = _cheap(con, "a", s, t)
            u = _hascol(con, "a", s, t, "update_time_utc") ?
                coalesce(_q(con, "SELECT CAST(max(update_time_utc) AS VARCHAR) AS u FROM a.$s.$t")[1].u, "-") : "-"
            kh = all(c -> _hascol(con, "a", s, t, c), OUTAGE_KEY) ?
                coalesce(_q(con, "SELECT CAST(bit_xor(hash($(join(OUTAGE_KEY, ", ")))) AS VARCHAR) AS h FROM a.$s.$t")[1].h, "-") : "-"
            vp = _hascol(con, "a", s, t, "version_publication_timestamp_utc") ?
                coalesce(_q(con, "SELECT CAST(max(version_publication_timestamp_utc) AS VARCHAR) AS v FROM a.$s.$t")[1].v, "-") : "-"
            println(io, "$s.$t\t$n\t$h\t$u\t$kh\t$vp")
        end
    end
    DBInterface.close!(con); DuckDB.close(db)
    println("fill-sums: $(countlines(outf) - 1) tables → $outf")
end
function fill_diff(args)
    fa, fb = args[2], args[3]; out = opt(args, "--out", ".")
    db = DuckDB.DB(":memory:"); con = DBInterface.connect(db)
    DBInterface.execute(con, "ATTACH '$(replace(fa, "'" => "''"))' AS a (READ_ONLY)")
    DBInterface.execute(con, "ATTACH '$(replace(fb, "'" => "''"))' AS b (READ_ONLY)")
    ta, tb = Set(_tables(con, "a")), Set(_tables(con, "b"))
    nd = 0; lines = String[]
    open(joinpath(out, "fill_diff.tsv"), "w") do io
        open(joinpath(out, "fill_rows_diff.tsv"), "w") do rio
            println(io, "table\trows_a\trows_b\tonly_a\tonly_b"); println(rio, "table\tside\trow")
            for (s, t) in sort(collect(union(ta, tb)))
                if !((s, t) in ta && (s, t) in tb)
                    println(io, "$s.$t\t$((s, t) in ta ? "present" : "absent")\t$((s, t) in tb ? "present" : "absent")\t-\t-")
                    nd += 1; push!(lines, "- $s.$t present in one fill only"); continue
                end
                (na, ha), (nb, hb) = _cheap(con, "a", s, t), _cheap(con, "b", s, t)
                if na == nb && ha == hb          # same rows and content checksum: no EXCEPT pass needed
                    println(io, "$s.$t\t$na\t$nb\t0\t0"); continue
                end
                oa = _q(con, "SELECT count(*) AS n FROM (SELECT * FROM a.$s.$t EXCEPT ALL SELECT * FROM b.$s.$t)")[1].n
                ob = _q(con, "SELECT count(*) AS n FROM (SELECT * FROM b.$s.$t EXCEPT ALL SELECT * FROM a.$s.$t)")[1].n
                println(io, "$s.$t\t$na\t$nb\t$oa\t$ob")
                (oa == 0 && ob == 0) && continue
                nd += 1; push!(lines, "- $s.$t: rows $na vs $nb, only in fill 1: $oa, only in fill 2: $ob")
                for (side, x, y) in (("only_fill1", "a", "b"), ("only_fill2", "b", "a"))
                    for r in _q(con, "SELECT * FROM (SELECT * FROM $x.$s.$t EXCEPT ALL SELECT * FROM $y.$s.$t) LIMIT 200")
                        println(rio, "$s.$t\t$side\t", join((_canon(v) for v in r), "|"))
                    end
                end
            end
        end
    end
    DBInterface.close!(con); DuckDB.close(db)
    s = "\n### Fill 1 vs fill 2 (Postgres between the two fills)\n" *
        (nd == 0 ? "All $(length(union(ta, tb))) tables identical (row multisets).\n" :
                   "$nd table(s) differ (fill_diff.tsv, rows in fill_rows_diff.tsv):\n" * join(lines, "\n") * "\n")
    open(io -> write(io, s), joinpath(out, "summary.md"), "a")
    haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> write(io, s), ENV["GITHUB_STEP_SUMMARY"], "a")
    print(s)
end

if _CMD == "clear"
    clear(ARGS)
elseif _CMD == "trace-diff"
    trace_diff(ARGS)
elseif _CMD == "fill-sums"
    fill_sums(ARGS)
elseif _CMD == "fill-diff"
    fill_diff(ARGS)
elseif _CMD == "compare"
    compare(ARGS) || (println("cells beyond the tie class or missing — see diff_cells.csv"); exit(1))
else
    error("usage: measure_duckdb_path.jl clear --days D1,D2 --label L --out DIR [--entry E] [--trace] | " *
          "compare A.csv B.csv [--out DIR] | trace-diff A.tsv B.tsv [--out DIR] | fill-sums INPUTS OUT.tsv | " *
          "fill-diff INPUTS_A INPUTS_B [--out DIR]")
end
