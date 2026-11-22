# research_dump.jl — RESEARCH-ONLY model dump hook for the complex-order clear.
# Included by ../MPCC.jl inside `module MPCC`, before solver.jl.
#
#   EUPHEMIA_DUMP_MODELS=<dir>   write, per clear of a book that carries block
#                                orders, under <dir>/<day>/<pass tag>/:
#     master_r<k>.mps / .sol.json      every master MILP (per PAB round), written
#                                      BEFORE optimize; solution after
#     master_base.mps / .sol.json      the master with blocks released (storage LP)
#     mpcc_blk_r<k>_t<ii>.mps/.sol.json per-period MPCC with the round-k blocks fixed
#     mpcc_base_t<ii>.mps / .sol.json   per-period MPCC of the no-blocks book
#     master_index.json                 master x/y column index → order
#     day.json                          block structure, rounds, prices, statuses
#   EUPHEMIA_DUMP_LEVEL=all|master|json   (default all) — `master` skips the
#                                per-period MPCC files, `json` writes day.json only.
#
# <ii> is the 0-based index of the period in `order_book.periods` (two digits;
# hourly books: ii = hour). The pass tag is `p1`/`p2` in the two-pass pipeline
# (p2 = the final clear), empty otherwise.
#
# With EUPHEMIA_DUMP_MODELS unset nothing here runs: every hook is behind
# `dump_enabled()` and the default path is unchanged.

import JSON

"""Pass tag (`p1`/`p2`) set by the two-pass drivers; only used to name dump dirs."""
const DUMP_TAG = Ref{String}("")
# (dir, name) for the NEXT monolithic solve_mpcc_market_clearing model; consumed
# (reset to nothing) by that solve, so retries are never dumped over it.
const _DUMP_NEXT = Ref{Any}(nothing)
# (dir, prefix) for the per-period driver: each period gets "<prefix>_t<ii>".
const _DUMP_PERIODS = Ref{Any}(nothing)
# per-period log filled by the driver while _DUMP_PERIODS is set
const _DUMP_PERIOD_LOG = Ref{Any}(nothing)
# last master solve facts (objective, time) for day.json
const _DUMP_MASTER_LAST = Ref{Any}(nothing)

dump_root() = strip(get(ENV, "EUPHEMIA_DUMP_MODELS", ""))
dump_enabled() = !isempty(dump_root())
dump_level() = lowercase(strip(get(ENV, "EUPHEMIA_DUMP_LEVEL", "all")))
dump_masters() = dump_enabled() && dump_level() in ("all", "master")
dump_periods() = dump_enabled() && dump_level() == "all"

# Every complex-order call of a day gets its own dir <root>/<day>/call<NN>_<tag>
# (NN = 01, 02, ... in call order; atomic mkdir, so concurrent solver processes
# never share one); <root>/<day>/<tag> is a symlink to the latest call with that tag.
function _dump_day_dir(order_book)
    dts = DateTime[o.date_time for o in order_book.orders]
    day = isempty(dts) ? "unknown-day" : string(Date(minimum(dts)))
    tag = isempty(DUMP_TAG[]) ? "solo" : DUMP_TAG[]
    root = joinpath(dump_root(), day)
    mkpath(root)
    for k in 1:999
        d = joinpath(root, "call$(lpad(k, 2, '0'))_$tag")
        try
            mkdir(d)
        catch
            continue
        end
        try
            link = joinpath(root, tag)
            islink(link) && rm(link)
            ispath(link) || symlink(basename(d), link)
        catch
        end
        return d
    end
    error("dump: no free call dir under $root")
end

_pidx(i::Integer) = lpad(i - 1, 2, '0')

function _dump_write_model(model, dir::AbstractString, name::AbstractString)
    try
        t = time()
        write_to_file(model, joinpath(dir, name * ".mps"))
        return time() - t
    catch e
        @warn "dump: writing $name.mps failed: $(sprint(showerror, e))"
        return NaN
    end
end

_jnum(x) = (x isa Real && !isfinite(x)) ? string(x) : x

function _dump_write_solution(model, dir::AbstractString, name::AbstractString;
                              extra=Dict{String,Any}())
    try
        d = Dict{String,Any}("termination_status" => string(termination_status(model)),
            "primal_status" => string(primal_status(model)))
        merge!(d, extra)
        if has_values(model)
            d["objective_value"] = _jnum(objective_value(model))
            try
                d["objective_bound"] = _jnum(objective_bound(model))
            catch
            end
            vals = Dict{String,Float64}()
            for v in all_variables(model)
                vals[name_or_index(v)] = value(v)
            end
            d["values"] = vals
        end
        open(joinpath(dir, name * ".sol.json"), "w") do io
            JSON.json(io, d; allownan=true)
        end
    catch e
        @warn "dump: writing $name.sol.json failed: $(sprint(showerror, e))"
    end
    return nothing
end

name_or_index(v) = (n = name(v); isempty(n) ? "_col$(index(v).value)" : n)

function _dump_write_json(path::AbstractString, d)
    try
        tmp = path * ".tmp"
        open(tmp, "w") do io
            JSON.json(io, d; allownan=true)
        end
        mv(tmp, path; force=true)
    catch e
        @warn "dump: writing $path failed: $(sprint(showerror, e))"
    end
end

"""Block / fallback / storage structure of a book, for day.json."""
function _dump_book_structure(order_book)
    periods = order_book.periods
    blocks = Dict{String,Any}()
    fallback = Dict{String,Any}()
    storage = Dict{String,Any}()
    for o in order_book.orders
        o isa LinkedHourlyOrder || continue
        t = extract_time_period(o.date_time, periods)
        sl = Dict("period" => t, "datetime" => string(o.date_time), "mw" => o.quantity,
                  "res" => o.resolution_code, "price" => o.price)
        if is_block_family(o.family)
            b = get!(blocks, o.family, Dict{String,Any}("zone" => string(o.zone),
                "limit_price" => o.price, "slices" => Any[]))
            push!(b["slices"], sl)
        elseif is_block_fallback(o.family)
            b = get!(fallback, o.family, Dict{String,Any}("zone" => string(o.zone),
                "offers" => Any[]))
            push!(b["offers"], sl)
        else
            b = get!(storage, o.family, Dict{String,Any}("zone" => string(o.zone),
                "budget_mwh" => o.family_budget_mwh, "members" => Any[]))
            push!(b["members"], sl)
        end
    end
    return blocks, fallback, storage
end

_dump_prices(res) = Dict(z => Dict(t => _jnum(p) for (t, p) in pd) for (z, pd) in res.market_prices)

"""Run `solve(book)` with per-period dumps under `prefix` (if enabled); returns (res, period_log, secs)."""
function _dump_solve(solve::Function, book, dir, prefix; write_models::Bool=dump_periods())
    _DUMP_PERIODS[] = write_models ? (dir, prefix) : nothing
    _DUMP_PERIOD_LOG[] = Any[]
    t = time()
    res = try
        solve(book)
    finally
        _DUMP_PERIODS[] = nothing
    end
    log = _DUMP_PERIOD_LOG[]
    _DUMP_PERIOD_LOG[] = nothing
    return res, log, time() - t
end

_safe_solve_time(model) = try
    JuMP.solve_time(model)
catch e
    @debug "solve_time unavailable" e
    NaN
end

function _dump_master_pre(model, dump, simple, linked, periods)
    dir, nm = dump
    dump_masters() || return nothing
    _dump_write_model(model, dir, nm)
    idx = joinpath(dir, startswith(nm, "master_r") ? "master_index.json" : "$(nm)_index.json")
    isfile(idx) && return nothing
    xs = [Dict("col" => "x[$i]", "zone" => string(o.zone), "type" => string(o.type),
               "period" => extract_time_period(o.date_time, periods), "price" => o.price,
               "mw" => o.quantity, "res" => o.resolution_code) for (i, o) in enumerate(simple)]
    ys = [Dict("col" => "y[$j]", "family" => o.family, "zone" => string(o.zone),
               "period" => extract_time_period(o.date_time, periods), "price" => o.price,
               "mw" => o.quantity, "res" => o.resolution_code) for (j, o) in enumerate(linked)]
    _dump_write_json(idx, Dict("x" => xs, "y" => ys,
        "note" => "x = simple-order acceptance, y = linked-member acceptance (block members: y == z[family]); " *
                  "rows bal[<node>|<period>] = nodal balance (supply −, demand +, + shed == 0); " *
                  "objective is Max welfare − 10000·Σshed (written to MPS as Min of the negation)"))
    return nothing
end

function _dump_master_post(model, dump, t0, n_bin, n_forced)
    dir, nm = dump
    hv = has_values(model)
    d = Dict{String,Any}("name" => nm, "status" => string(termination_status(model)),
        "objective" => hv ? _jnum(objective_value(model)) : nothing,
        "solve_time" => _safe_solve_time(model), "build_and_solve_wall" => time() - t0,
        "n_block_binaries" => n_bin, "n_forced" => n_forced)
    try
        d["bound"] = _jnum(objective_bound(model))
    catch
    end
    _DUMP_MASTER_LAST[] = d
    dump_masters() && _dump_write_solution(model, dir, nm; extra=d)
    return nothing
end

function _dump_begin(order_book, max_pab_rounds)
    ddir = _dump_day_dir(order_book)
    blocks_s, fb_s, st_s = _dump_book_structure(order_book)
    periods = order_book.periods
    D = Dict{String,Any}(
        "day" => basename(dirname(ddir)), "call_dir" => basename(ddir),
        "pass_tag" => DUMP_TAG[], "pid" => getpid(), "host_myid" => myid(),
        "nodes" => order_book.nodes, "periods" => periods,
        "period_file_index" => Dict(t => _pidx(i) for (i, t) in enumerate(periods)),
        "price_limits" => collect(order_book.price_limits),
        "fixed_injections_in" => [Dict("node" => k[1], "period" => k[2], "mw" => v)
                                  for (k, v) in order_book.fixed_injections],
        "max_pab_rounds" => max_pab_rounds, "dump_level" => dump_level(),
        "names" => Dict(
            "master_balance_row" => "bal[<node>|<period>]",
            "master_block_binary" => "z[<family>] (MPS writer maps ' ' to '_')",
            "master_family_budget_row" => "fam[<family>]",
            "mpcc_balance_row" => "nodal_power_balance[<node>,<period>]",
            "mpcc_price_col" => "market_price[<node>,<period>]",
            "mpcc_files" => "<prefix>_t<ii>, ii = 0-based index into periods (period_file_index)"),
        "blocks" => blocks_s, "block_fallback" => fb_s, "storage" => st_s,
        "base" => nothing, "rounds" => Any[], "outcome" => nothing, "t_start" => string(now()))
    _dump_write_json(joinpath(ddir, "day.json"), D)
    return ddir, D
end

_cap_cells(res, cap) = sort([Dict("zone" => z, "period" => t, "price" => p)
                             for (z, pd) in res.market_prices for (t, p) in pd if p >= cap - 1e-6];
                            by=x -> (x["zone"], x["period"]))

function _dump_base!(D, ddir, order_book, solve, preferred_solver)
    has_blk = any(o -> o isa LinkedHourlyOrder && is_block_family(o.family), order_book.orders)
    (has_blk && get(ENV, "EUPHEMIA_DUMP_BASE", "1") != "0") || return nothing
    _DUMP_MASTER_LAST[] = nothing
    t = time()
    obB = resolve_complex_orders(order_book; preferred_solver=preferred_solver, verbose=false,
        release_blocks=true, dump=(ddir, "master_base"))
    master_wall = time() - t
    resB, plog, secs = _dump_solve(solve, obB, ddir, "mpcc_base")
    D["base"] = Dict{String,Any}("master" => _DUMP_MASTER_LAST[], "master_wall" => master_wall,
        "status" => string(resB.status), "objective" => _jnum(resB.objective_value),
        "mpcc_wall" => secs, "periods" => plog, "prices" => _dump_prices(resB),
        "cap_cells" => _cap_cells(resB, order_book.price_limits[2]),
        "note" => "blocks released (BLKFB fallback offers restored), storage via master LP")
    _dump_write_json(joinpath(ddir, "day.json"), D)
    println("   🗄  dump: base (no blocks) $(resB.status), master $(round(master_wall, digits=1)) s, " *
            "MPCC $(round(secs, digits=1)) s → $ddir")
    return nothing
end

function _dump_round!(D, ddir, order_book, rnd, forced_before, info, master_wall, res, plog,
                      mpcc_secs, surplus_all, pab; outcome="")
    blocks = (info !== nothing && hasproperty(info, :blocks)) ? info.blocks : Dict{String,Any}()
    m = _DUMP_MASTER_LAST[]
    cap = order_book.price_limits[2]
    capc = _cap_cells(res, cap)
    r = Dict{String,Any}("round" => rnd,
        "forced_reject_in" => sort(collect(forced_before)),
        "master" => m, "master_wall" => master_wall,
        "master_info_status" => info === nothing ? "none" : string(info.status),
        "accepted" => sort(collect(keys(blocks))),
        "n_accepted" => length(blocks),
        "n_blocks" => (info !== nothing && hasproperty(info, :n_blocks)) ? info.n_blocks : 0,
        "pab" => sort(pab), "n_pab" => length(pab),
        "surplus" => Dict(f => _jnum(v) for (f, v) in surplus_all),
        "mpcc_status" => string(res.status), "mpcc_objective" => _jnum(res.objective_value),
        "mpcc_wall" => mpcc_secs, "periods" => plog, "prices" => _dump_prices(res),
        "cap_cells" => capc, "outcome" => outcome)
    push!(D["rounds"], r)
    D["outcome"] = outcome
    _dump_write_json(joinpath(ddir, "day.json"), D)
    mobj = m === nothing ? "n/a" : string(m["objective"])
    mt = m === nothing ? NaN : m["solve_time"]
    println("   🧱 PAB trace round $rnd: accepted $(length(blocks)), forced-in $(length(forced_before)), " *
            "PAB $(length(pab)), master obj $mobj ($(round(mt, digits=2)) s solve, " *
            "$(round(master_wall, digits=1)) s wall), MPCC $(res.status) $(round(mpcc_secs, digits=1)) s, " *
            "cap cells $(length(capc))" * (isempty(capc) ? "" :
            " [" * join(["$(c["zone"])@$(c["period"])" for c in first(capc, 8)], ",") * "]"))
    return nothing
end

function _dump_fallback!(D, ddir, res, plog, secs, forced)
    D["fallback"] = Dict{String,Any}("status" => string(res.status),
        "objective" => _jnum(res.objective_value), "mpcc_wall" => secs, "periods" => plog,
        "prices" => _dump_prices(res), "forced_total" => sort(collect(forced)))
    D["outcome"] = "PAB FALLBACK after $(length(D["rounds"])) round(s)"
    _dump_write_json(joinpath(ddir, "day.json"), D)
    return nothing
end

"""Per-period MPCC price provenance for the A0/P1 audits: raw solver prices,
reconstructed prices, component brackets, active NP rows, flows vs caps."""
function _dump_write_recon(model, dir, name, raw_prices, recon, diag, np_rows, flow_values, flow_caps)
    try
        nps = Any[]
        for (c, ccr, hub, t, mn, mx) in np_rows
            v = value(c)
            push!(nps, Dict("row" => "np[$ccr|$hub|$t]", "ccr" => ccr, "hub" => hub, "period" => t,
                "min" => mn, "max" => mx, "value" => v,
                "active" => (v <= mn + 1e-3 || v >= mx - 1e-3)))
        end
        fl = Any[]
        for ((pair, t), v) in flow_values
            fw, bw = flow_caps[(pair, t)]
            push!(fl, Dict("from" => pair[1], "to" => pair[2], "period" => t, "flow" => v,
                "fwd_cap" => fw, "bwd_cap" => bw,
                "at_fwd" => v >= fw - 1e-3, "at_bwd" => v <= -bw + 1e-3))
        end
        d = Dict{String,Any}("termination_status" => string(termination_status(model)),
            "raw_prices" => raw_prices, "recon_prices" => recon.prices,
            "fallback_periods" => recon.fallback_periods, "fallback_cells" => recon.fallback_cells,
            "inconsistent_brackets" => recon.inconsistent_brackets,
            "components" => diag, "np_rows" => nps,
            "n_np_active" => count(x -> x["active"], nps), "flows" => fl,
            "note" => "raw = solver market_price values; recon = published (_reconstruct_component_prices); " *
                      "components: bracket [lo,hi] per price-coupled component, point = pre-rent-sign estimate, final = published")
        open(joinpath(dir, name * ".recon.json"), "w") do io
            JSON.json(io, d; allownan=true)
        end
    catch e
        @warn "dump: writing $name.recon.json failed: $(sprint(showerror, e))"
    end
    return nothing
end
