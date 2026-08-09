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
# v21 -> v22: the UA firm-slice boundary book + a batch of four confirmed
# price-affecting bug-fixes (docs/experiments/cv22.md). All five are gated behind
# EUPHEMIA_DISABLE_CV22 (the byte-identity kill-switch) and ON by default.
#  (A) ua2 — roadmap item 1 ported to src as a first-class, profile-gated
#      BoundaryBook (like cv21 Viking): UA is a war-constrained scarcity buyer on
#      the HU/SK/RO/PL-UA borders. Import supply anchored 0.55x zone gas SRMC (no
#      UA fundamentals feed — the documented generic-anchor compromise); export
#      demand = a FIRM cap-priced base slice (its demonstrated persistent import
#      need, which does not curtail on price — the mechanism that killed the
#      wave-2 HU March breach) plus an elastic tail. UA_BOOK_DEFAULT (HU/SK/RO),
#      UA_BOOK_PL (PL, +UA_DobTPP radial); capability = trailing-366d p95 gross
#      flow per 4h block (:p95_block, UA ATC is stale/absent); firm = trailing-28d
#      p10 of the daily block-mean export flow. Both computed at RUNTIME (no
#      committed JSON) — they reproduce the experiment's firm_ua.json /
#      capability_w2.json EXACTLY on the confirm days (firm@18UTC March HU 139/
#      SK 283/PL 137/RO 9, July HU 8.5/RO,PL 0/SK 74 — matching the reference),
#      so the book generalizes to every backfill day. Reference confirm
#      (2026-07-24, 24-day A/B): HU July MAE 72.3->57.1 / corr 0.69->0.79; March
#      MAE 28.24->28.29 (breach dead); SK July eve bias -82->-73, SI July MAE
#      80.7->70.1. Accepted residuals: HU March evening MAE 29.2->33.0, RO/BG
#      March ~+1. SRC confirm A/B (HiGHS decomposed, 39-zone coupled, offline
#      extract, 18/24 days — July 16-21 fail the extract ATC gap for both arms):
#      HU July MAE 80.3->61.5 / corr 0.70->0.80 (PASS, gate -10.5); SI July
#      82.5->71.4, SK 46.3->44.8, RO 30.2->28.6; July footprint mean 31.7->30.6
#      (28/10 better); March guard flat 24.63->24.68. Accepted residuals
#      reproduce: RO March +1.2, BG +0.9, HU March eve +3.0. docs/experiments/cv22.md.
#  (B) flows_imports :v2 border map — a Nordic-side border MISSING its D-7
#      observation was DELETED from the border map (silently zeroing its ex-ante
#      flow) instead of falling back to climatology. Fixed to fall back, never
#      delete. EU-footprint :v2/:v3 only.
#  (C) Network.jl legacy (non-enriched) ATC build — took whichever duplicate
#      capacity row sorted LAST by date_time_utc for a border-hour
#      (order-dependent). Fixed to hourly AVG per (source, sink, hour), matching
#      the enriched path. *** This ENDS the SEE 5-zone byte-identity chain
#      (unbroken since cv10). *** Measured SEE delta (single-zone unaffected —
#      never touches the Network build; 5-zone tiny/zero on days without
#      duplicate rows): see docs/experiments/cv22.md; gate held (no material
#      worsening).
#  (D) fleet_data get_reservoir_drawdown — the lower-bound disjunct year>$2-2
#      widened the "preceding 52 weeks" window to 52-104 weeks (and made the
#      second disjunct dead). Fixed to $2-1. Nordic :reservoir_opportunity only.
#  (E) fleet_data get_reservoir_dryness — the +-2-ISO-week neighbourhood
#      (week BETWEEN $3-2 AND $3+2) did not wrap the year boundary. Fixed with a
#      mod-52 wrapped week set. Only differs at ISO weeks 1/2/52/53 (Dec/Jan) —
#      invisible to the mid-year confirm/guard windows and to the SEE guard days.
#  NOT shipped in cv22 (measured NO-SHIP, deferred to cv23): the GB pair (FR
#  nuclear root cause; the FR-GB double-count stays known-compensated so it does
#  NOT ship alone) and iter9/43-zones (AL/MK/ME/HR endogenization). Byte-identity
#  guards (GR single-zone, SEE 5-zone, 39-zone EU with EUPHEMIA_DISABLE_CV22=1):
#  bit-identical vs cv21 main (Viking stays ON — its kill-switch is CV21).
#  cv22 matters for the EU footprint (multi_zone_eu). July 2026.
# v22 -> v23: three mechanism components, each measured (July 2026):
# (1) FR nuclear opportunity-cost bidding — availability-scaled :nuclear
# anchor share (trailing-30d fleet p95/installed; ex-ante, no-fit;
# docs/experiments/cv23-fr-nuclear.md) — March confirm FR MAE 38.2->16.2,
# evening bias -77%; (2) the re-paired FR<->GB border (double-count fix +
# elastic GB CCGT boundary book with UKA carbon) shipping WITH the FR fix
# per the cv22 no-ship prescription — neighbour guards pass on top of (1);
# (3) interior-Norway import backstop NO1/NO3 (docs/experiments/
# norwegian-hydro/) — kills the dry-spring phantom-scarcity cap (NO1 MAE
# 340->73, NO3 corr 0.16->0.48, all other zones byte-identical); the NO1
# corr headline stays an open problem (anchor levers measured and
# rejected; needs inflow data / corridor congestion). Kill-switch
# EUPHEMIA_DISABLE_CV23 covers all three.
# v23 -> v24: record-consistency bump for the registry sanity bound (#205,
# MAX_PLAUSIBLE_UNIT_MW = 25 GW): drops corrupt ENTSO-E capacity rows (the
# IT-CSOUTH unit 26WUUUUUUBUSSI19 carried 13,068,005 MW, which polluted the
# fleet-truthing denominators and produced NaN correlation there). No other
# mechanism content — the IT must-run floor experiments (cv24/cv24.1 in
# docs/experiments/cv24-it-book.md) were measured NO-SHIP. Prices change
# only where a corrupt unit was in the fleet (IT-CSOUTH); every other zone
# is byte-identical to cv23 code. Bumped so the post-#205 daily forecasts
# and the refilled record never mix with cv23 rows. July 2026.
# v27 -> v31: solar-regime price-taker floor ACTIVATED (#251 -> cv31 ship;
# docs/experiments/solar-regime). Ex-ante regime gate = day-ahead solar share
# of forecast load >= θ=0.4 on the CONTINENTAL_SOLAR group DE_LU/FR/PL/BE/CZ/CH;
# in regime hours the RES block + run-of-river + the deepest must-run block
# price at DEEP_SURPLUS_FLOOR_EUR (-20) so the clear can go negative
# (BLOCKS=full). Measured within-regime: Set A dMAE -1.50 (base 43.83 ->
# 42.33), Set B dMAE -0.27 (base 34.14 -> 33.87); phantom rate 0.0, outside-
# regime |ΔMAE| <= 0.017, ZERO new caps, no zone harmed — clears every gate on
# both sets. Default-ON; kill-switch EUPHEMIA_DISABLE_CV31 set ⇒ fully inert
# (byte-identical to cv27 main; guarded GR single-zone + 39-zone EU). Explicit
# EUPHEMIA_SOLAR_REGIME* env still wins (THETA/BLOCKS/ZONES A/Bs). None of the
# six floor zones is in the SEE single-zone/5-zone products, so those stay
# byte-identical; cv31 matters for the EU footprint (multi_zone_eu). Effect is
# safe and directionally correct but modest (the coupled marginal block often
# stays thermal, and the floor bottoms at -20 while settled reaches -100..-300)
# — versions 28/29/30 are consumed by documented NO-SHIP labels (cv28/cv29
# floor family, cv30 — docs/experiments/cv{28,29,30}-results.md). August 2026.
# v31 -> v32: winner-input corrections, Sicily+Sardinia scope (#318 ship;
# docs/experiments/recal/cv32-results-2026-08.md). The record path's RES input
# for IT-Sicily / IT-Sardinia comes from simulations.input_corrections
# (actuals-target LightGBM solar, D-1-legal, emitted daily by
# bin/emit_input_corrections.jl since #319), profile-scoped to the EU path
# (ZoneProfile.input_corrections), kill-switch EUPHEMIA_DISABLE_CV32.
# Owner-ratified adoption; the full 5-zone winner set was measured and
# REJECTED at year scale (GR +2.03 / DK1 +2.68 — co-adaptation; those series
# stay in the table awaiting joint mechanism packages, PL joined the queue in
# #321). Validation cv32b_fy: Sicily −0.20 / corr +0.009, footprint −0.06,
# zero new caps; SEE byte-identity untouched (neither island is in the SEE
# products). Prices change ONLY on the two islands; every other zone is
# byte-identical to cv31 code. Bumped so daily forecasts and the next record
# never mix cv32 books with cv31 rows. August 2026.
const ENERGY_PRICES_CODE_VERSION = 32

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

# The pool permit MUST be released on every exit path. ConcurrentUtilities'
# contract is "each acquire is matched by exactly one release, or acquire
# blocks forever once the pool is at its limit" — and `acquire` only
# self-heals when the CONSTRUCTOR throws, not the body. Without the finally,
# any server-side error (statement timeout, killed backend, a UniqueViolation
# in save_inferred_parameters, the ALTER wedge in results_store.jl) leaked one
# permit; after `poolsize` such errors EVERY query in the process blocked in
# `wait(pool.lock)` with no error and no log. Worse, `sql2df_with_retry`'s
# connection-error path calls `preinit_pool`, which acquires all permits at
# once — so a single leak could hang the run inside its own retry handler.
function withdb(f)
    connection = Base.acquire(newconnection, cnxpool; isvalid=cnxisok)
    try
        return f(connection)
    finally
        !cnxisok(connection) && LibPQ.reset!(connection)
        Base.release(cnxpool, connection)
    end
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
