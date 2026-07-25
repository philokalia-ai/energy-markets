# postgres_core.jl — ENERGY_PRICES_CODE_VERSION ledger, LibPQ connection pool, and sql2df / sql2df_with_retry (backend dispatch lives here).
# Included by ../dbutils.jl inside `module Euphemia` (definition order preserved).


# Version of the pricing/cost model that produced stored energy_prices rows.
# Bump when the model changes incompatibly (e.g. v2 -> v3: stylized
# 2.2x-markup marginal costs replaced by SRMC/TTF-based costs, July 2026;
# v3 -> v7: multi-zone artifact fixes — tight MIP gap, component-wise price
# reconstruction, border-aware net-import exclusion, July 2026; 4-6 were
# already taken by legacy uc_based experiment rows; v7 -> v8: daily EUA
# carbon prices from yfinance.eua_co2 instead of yearly averages, July 2026;
# v8 -> v9: multi-zone nodal-balance flow signs fixed — flows were
# physically mirrored, capping every border by the opposite direction's
# ATC, July 2026; v9 -> v10: crisis-year honesty — fleet-truthing derate
# of baseload types to trailing p95 (phantom 2022 lignite) and absolute
# instead of proportional must-run below-cost discount, July 2026;
# v10 -> v14: the calibrated 39-zone EU-footprint model / v0.2.0, July 2026;
# v14 -> v15: installed-capacity fleet truth (:installed fleet_truth_mode on
# the continental core DE_LU/NL/PL/CZ and the Baltics), SK Core-border drop +
# :hydro anchor, seasonal reservoir-drawdown water value, import-ATC scarcity
# credit, and MPCC robustness — exact indicator-form complementarity retry +
# per-day :p95-books fallback, July 2026;
# v15 -> v16: fully ex-ante :v2 flow rule (flow climatology + D-7 Norwegian
# recency) as the EU-footprint default instead of same-day observed flows,
# July 2026;
# v16 -> v17: weak-zone import fixes (docs/experiments/weak-zone-diagnosis) —
# AT–CZ/AT–DE_LU/AT–SI Core-FBMC border drops + SI on the Slovakia treatment
# (continental temperament + :hydro anchor), the profile-gated ex-ante
# elastic import backstop (AT/BE/CH/DK1/DK2/SE3/IT-CNORTH/SI/RO/RS/HU; the
# SEE-east zones RO/RS/HU also credit the demonstrated headroom in the
# scarcity margin), and ref-priced retained-border exports (SI–HR, BE–GB);
# an anchor-refs-over-dropped-borders mechanism (SE3) was built, measured
# against its gate and switched OFF — July 2026) so new results are never mixed
# with — or skipped because of — old rows. Each version is one selectable
# "Run" in the Metabase counterfactual dashboard.
# v18 = RESERVED (shape levers, built default-inert, activation held back).
# v18 -> v19: the EU-footprint scoped flow default moves :v2 -> :v3 (anad2:
# per-border mean of the load-analogue median and the D-2 observed flow —
# docs/experiments/analogue-flows). Measured vs :v2 on the 39-day coupled
# A/B: MAE better or flat in all four windows (July-26 flip 33.6->33.2,
# June-26 held-out 37.5->32.4), GR July evening bias +57->+43, corr
# 0.85->0.87; footprint net-import MAE -15%. SEE legacy paths (single-zone,
# 5-zone multi_zone) keep :d0 and their byte-identity — July 2026.
# v19 -> v20: per-period-DECOMPOSED clear becomes the canonical mode on the
# EU-footprint path for every solver, and the auto solver default flips to
# HiGHS (open-source; the Gurobi license here is academic — Gurobi stays the
# development option). Decomposed is bit-identical across Gurobi/HiGHS, so
# the record is solver-invariant; it differs from the legacy monolithic
# clear only on degenerate pass-2 anchor ties (10/29,679 hourly cells over
# the 39-day mode A/B, scores identical to 2 decimals in all four windows).
# SEE legacy paths (single-zone, 5-zone multi_zone) stay monolithic and keep
# their byte-identity — July 2026.
# v20 -> v21: DK1/Viking virtual boundary book (docs/experiments/cv21-dk1-viking.md,
# item 2 of the boundary-zone program). The out-of-footprint GB counterparty on
# the DK1-GB Viking Link is modeled as an ELASTIC neighbor — import-supply +
# export-demand ladders anchored on GB's OWN CCGT SRMC (TTF/0.52 + EUA-proxied
# UK carbon/0.52 + O&M) over the border's demonstrated capability — replacing
# GB's fixed flow injection and its import-backstop headroom. Profile-gated
# (only DK1 carries VIKING_GB_BOOK; DK2 unchanged), default-inert everywhere
# else, EUPHEMIA_DISABLE_CV21 kill-switch. Confirm A/B (src impl, HiGHS, offline
# extract, 24-day window; 6 late-July days unavailable on the extract's ATC
# gap): March (stable guard, 8/8 days) DK1 MAE 27.9->24.6, corr 0.55->0.81
# (reference 27.6->25.2 / 0.55->0.80 — matched); July (10/16 days) DK1 MAE
# 29.5->26.6, corr 0.88->0.90; no FR/NL/NO2 leakage. GB itself stays PARKED (no
# broader GB book until an Elexon/BMRS + UKA feed); UA is a separate decision.
# SEE single-zone / 5-zone products stay byte-identical (guarded); cv21 matters
# for the EU footprint (multi_zone_eu). No backfill in this change — July 2026.
const ENERGY_PRICES_CODE_VERSION = 21

# Pool size: env-tunable (EUPHEMIA_PG_POOL) because the threaded book build
# runs up to nzones concurrent queries — 5 connections cap the parallelism
# and lock convoys made 8 threads SLOWER than 1 in the 2026-07-24 benchmark.
# Default stays 5 (the long-standing footprint-friendly value).
const poolsize = max(1, parse(Int, get(ENV, "EUPHEMIA_PG_POOL", "5")))
cnxpool = Pools.Pool{LibPQ.Connection}(poolsize)

function cnxisok(cnx::LibPQ.Connection)
    return LibPQ.status(cnx) == LibPQ.libpq_c.CONNECTION_OK
end

function newconnection()
    conn_str = get(ENV, "ENERGY_CONN_STR", "")

    # Add PostgreSQL connection parameters to improve connection reliability
    # These parameters work with both URL and key=value connection string formats
    if !contains(conn_str, "connect_timeout")
        # Detect connection string format and append parameters appropriately
        if contains(conn_str, "postgresql://") || contains(conn_str, "postgres://")
            # URL format: add query parameters
            separator = contains(conn_str, "?") ? "&" : "?"
            conn_str = conn_str * separator * "connect_timeout=30&keepalives_idle=300&keepalives_interval=30&keepalives_count=3"
        else
            # Key=value format: add space-separated parameters
            conn_str = conn_str * " connect_timeout=30 keepalives_idle=300 keepalives_interval=30 keepalives_count=3"
        end
    end

    cnx = LibPQ.Connection(conn_str)
    !isdefined(LibPQ, :setnonblocking) && return cnx
    LibPQ.setnonblocking(cnx) && return cnx
    error("Could not set connection to nonblocking")
end

function preinit_pool(poolsize=poolsize)
    cnxs = [Base.acquire(newconnection, cnxpool; isvalid=cnxisok) for i in 1:poolsize]
    # They all need to exist at the same time;
    map(cnxs) do connection
        Base.release(cnxpool, connection)
    end
    @info "preinit $poolsize done"
end

function withdb(f)
    connection = Base.acquire(newconnection, cnxpool; isvalid=cnxisok)
    result = f(connection)

    !cnxisok(connection) && LibPQ.reset!(connection)
    Base.release(cnxpool, connection)

    return result
end

function sql2df(sql, args=[])
    if DATA_STORE[] == :duckdb
        return _duckdb_sql2df(sql, args)
    end
    return withdb() do cnx
        result = LibPQ.async_execute(cnx, sql, args)
        return DataFrame(fetch(result))
    end
end

"""
    sql2df_with_retry(sql, args=[]; max_retries=3, retry_delay=2.0)

Execute SQL query with automatic retry on connection failures.
"""
function sql2df_with_retry(sql, args=[]; max_retries=3, retry_delay=2.0)
    last_error = nothing
    # Under the DuckDB backend there is NO Postgres pool to reset, and offline
    # workers run with ENERGY_CONN_STR emptied — so the LibPQ connection-error
    # classification (and preinit_pool, which opens 5 LibPQ connections with a
    # 30 s connect_timeout each) must never run here. A transient DuckDB error
    # is simply retried a couple of times without touching LibPQ.
    is_duckdb = DATA_STORE[] == :duckdb

    for attempt in 1:max_retries
        try
            return sql2df(sql, args)
        catch e
            last_error = e

            if is_duckdb
                if attempt < max_retries
                    @warn "DuckDB query failed (attempt $attempt/$max_retries): $e"
                    sleep(retry_delay)
                    continue
                else
                    @error "DuckDB query failed after $max_retries attempts: $e"
                end
            # Postgres: check if it's a connection-related error
            elseif isa(e, LibPQ.Errors.JLConnectionError) ||
                   (isa(e, Exception) && occursin("connection", string(e)))

                if attempt < max_retries
                    @warn "Database connection failed (attempt $attempt/$max_retries): $e"
                    @info "Retrying in $retry_delay seconds..."
                    sleep(retry_delay)

                    # Try to reset the connection pool
                    try
                        preinit_pool(poolsize)
                    catch pool_error
                        @warn "Failed to reinitialize connection pool: $pool_error"
                    end

                    continue
                else
                    @error "Database connection failed after $max_retries attempts: $e"
                end
            else
                # Non-connection error, don't retry
                break
            end
        end
    end

    # If we get here, all retries failed
    throw(last_error)
end
