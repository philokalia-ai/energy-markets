# results_store.jl — simulations.* schema DDL (ensure_*), the Postgres market-result writers (save_*), and ensure_indexes.
# Included by ../dbutils.jl inside `module Euphemia` (definition order preserved).

"""
    ensure_energy_prices_table()

Creates the simulations schema and energy_prices table if they don't exist.
Assumes connection is already to the 'energy' database.
"""

function ensure_energy_prices_table()
    _duckdb_readonly_guard("ensure_energy_prices_table") && return nothing
    withdb() do cnx
        # Create schema if not exists (energy is the database, simulations is the schema)
        LibPQ.execute(cnx, "CREATE SCHEMA IF NOT EXISTS simulations")

        # Create table if not exists
        create_table_sql = """
        CREATE TABLE IF NOT EXISTS simulations.energy_prices (
            id SERIAL PRIMARY KEY,
            date_time_utc TIMESTAMP NOT NULL,
            resolution_code VARCHAR(10) NOT NULL,
            bidding_zone VARCHAR(20) NOT NULL,
            contract_type VARCHAR(50) NOT NULL,
            price_eur_mwh NUMERIC(10,2) NOT NULL,
            currency VARCHAR(3) NOT NULL,
            order_method VARCHAR(20) NOT NULL,
            clearing_mode VARCHAR(20) NOT NULL DEFAULT 'single_zone',
            optimization_run_id INTEGER,
            code_version INTEGER NOT NULL,
            update_time_utc TIMESTAMP NOT NULL,
            UNIQUE(date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version)
        )
        """

        LibPQ.execute(cnx, create_table_sql)

        # Add clearing_mode column if it doesn't exist (for existing tables)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND column_name = 'clearing_mode'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD COLUMN clearing_mode VARCHAR(20) NOT NULL DEFAULT 'single_zone';
                END IF;
            END \$\$;
        """)

        # Add optimization_run_id column if it doesn't exist (for existing tables)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND column_name = 'optimization_run_id'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD COLUMN optimization_run_id INTEGER;
                END IF;
            END \$\$;
        """)

        # Migrate unique constraint to include clearing_mode (for databases created before clearing_mode was added)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Check if the old constraint (without clearing_mode) exists
                IF EXISTS (
                    SELECT 1 FROM pg_indexes
                    WHERE schemaname = 'simulations'
                    AND tablename = 'energy_prices'
                    AND indexdef LIKE '%date_time_utc, bidding_zone, contract_type, order_method, code_version)%'
                    AND indexdef NOT LIKE '%clearing_mode%'
                ) THEN
                    -- Drop the old constraint
                    ALTER TABLE simulations.energy_prices
                    DROP CONSTRAINT energy_prices_date_time_utc_bidding_zone_contract_type_orde_key;
                    -- Add the new constraint with clearing_mode
                    ALTER TABLE simulations.energy_prices
                    ADD CONSTRAINT energy_prices_unique_record
                    UNIQUE (date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version);
                END IF;
            END \$\$;
        """)

        # Create useful indexes
        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_datetime_zone 
ON simulations.energy_prices (date_time_utc, bidding_zone)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_zone_contract
ON simulations.energy_prices (bidding_zone, contract_type, date_time_utc)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_clearing_mode
ON simulations.energy_prices (clearing_mode, date_time_utc)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_optimization_run_id
ON simulations.energy_prices (optimization_run_id)
"""
        )

        # Create optimization runs table for tracking all optimization attempts
        create_optimization_runs_sql = """
        CREATE TABLE IF NOT EXISTS simulations.optimization_runs (
            id SERIAL PRIMARY KEY,
            bidding_zone VARCHAR(20) NOT NULL,
            optimization_date DATE NOT NULL,
            order_method VARCHAR(20) NOT NULL,
            model_type VARCHAR(20) NOT NULL,
            optimizer VARCHAR(20) NOT NULL,
            status VARCHAR(20) NOT NULL,
            objective_value NUMERIC(15,2),
            solve_time_seconds NUMERIC(10,3),
            num_orders INTEGER,
            num_price_periods INTEGER,
            error_message TEXT,
            code_version INTEGER NOT NULL,
            created_at TIMESTAMP NOT NULL,
            -- Iterative optimization metadata (added for UC-MPCC iterative runs)
            is_iterative BOOLEAN DEFAULT FALSE,
            total_time_seconds NUMERIC(12,3),
            iterations INTEGER,
            converged BOOLEAN,
            final_price_change NUMERIC(10,3),
            final_flow_change_pct NUMERIC(10,3),
            UNIQUE(bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)
        )
        """

        LibPQ.execute(cnx, create_optimization_runs_sql)

        # Add iterative columns to existing tables (migration for existing installations)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Add is_iterative column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'is_iterative') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN is_iterative BOOLEAN DEFAULT FALSE;
                END IF;
                -- Add total_time_seconds column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'total_time_seconds') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN total_time_seconds NUMERIC(12,3);
                END IF;
                -- Add iterations column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'iterations') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN iterations INTEGER;
                END IF;
                -- Add converged column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'converged') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN converged BOOLEAN;
                END IF;
                -- Add final_price_change column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'final_price_change') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN final_price_change NUMERIC(10,3);
                END IF;
                -- Add final_flow_change_pct column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'final_flow_change_pct') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN final_flow_change_pct NUMERIC(10,3);
                END IF;
            END \$\$;
        """)

        # Create useful indexes for optimization runs
        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_optimization_runs_zone_date 
ON simulations.optimization_runs (bidding_zone, optimization_date)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_optimization_runs_status
ON simulations.optimization_runs (status, optimization_date)
"""
        )

        # Add foreign key constraint if it doesn't exist
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.table_constraints
                    WHERE constraint_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND constraint_name = 'fk_energy_prices_optimization_run'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD CONSTRAINT fk_energy_prices_optimization_run
                    FOREIGN KEY (optimization_run_id)
                    REFERENCES simulations.optimization_runs(id)
                    ON DELETE SET NULL;
                END IF;
            END \$\$;
        """)
    end

    @info "Energy prices and optimization runs tables schema verified/created"
end

"""
    ensure_forecast_tables()

Creates the daily-forecast product tables if they don't exist (idempotent DDL):

- `simulations.forecast_prices`: true ex-ante hourly price predictions. Unlike
  `simulations.energy_prices` (backfills over realized days), every row carries
  `prediction_made_utc` (when the prediction was produced) and `lead_days`
  (market_date − prediction date, in days), so accuracy can be tracked HONESTLY
  per region and per lead time — a prediction is only ever written for days that
  had not yet realized at write time.
- `simulations.forecast_scores`: per (market_date, zone, lead_days, code_version,
  input_mode) accuracy scores (MAE, bias = sim − actual, Pearson corr) computed
  once the day's actual day-ahead prices realize.

Both tables carry `input_mode` ('entsoe' = reference track built on ENTSO-E D-1
load + wind/solar forecasts; 'weather' = ex-ante track whose wind/solar come
from raw open-meteo weather via bin/weather_res.jl, freezable before the 12:00
CET auction gate). The slice identity is (market_date, lead_days, code_version,
input_mode) — the two tracks NEVER overwrite each other, so `input_mode` is part
of the unique/primary keys (pre-existing constraints are migrated in place via
pg_constraint-checked DO blocks; legacy rows default to 'entsoe').

Postgres-only (no-op with a warning under the read-only DuckDB backend).
Called by `bin/daily_forecast.jl` / `bin/score_forecasts.jl`.
"""
function ensure_forecast_tables()
    _duckdb_readonly_guard("ensure_forecast_tables") && return nothing
    withdb() do cnx
        # Any DDL below fails fast (loud run failure) instead of queueing for
        # hours behind a long reader — see the WEDGE GUARD note further down.
        LibPQ.execute(cnx, "SET lock_timeout = '30s'")
        LibPQ.execute(cnx, "CREATE SCHEMA IF NOT EXISTS simulations")

        LibPQ.execute(cnx, """
        CREATE TABLE IF NOT EXISTS simulations.forecast_prices (
            id BIGSERIAL PRIMARY KEY,
            market_date DATE NOT NULL,
            date_time_utc TIMESTAMPTZ NOT NULL,
            bidding_zone TEXT NOT NULL,
            price_eur_mwh DOUBLE PRECISION NOT NULL,
            prediction_made_utc TIMESTAMPTZ NOT NULL,
            lead_days INT NOT NULL,
            clearing_mode TEXT NOT NULL DEFAULT 'multi_zone_eu',
            code_version INT NOT NULL,
            input_mode TEXT NOT NULL DEFAULT 'entsoe',
            optimization_run_id BIGINT,
            created_at TIMESTAMPTZ DEFAULT now(),
            -- RETRO reconstruction (data-reset backfill). ADDITIVE: existing
            -- readers ignore these; genuine live vintages carry is_retro=false.
            -- A retro row is a reconstruction of "what we would have said at
            -- this lead" computed from the historical previous_dayN vintages,
            -- stamped with reset_tag (the campaign label) and retro_of_utc
            -- (the natural D-lead compute instant it stands in for). See
            -- docs/experiments/pregate-7lead.md.
            is_retro BOOLEAN NOT NULL DEFAULT false,
            reset_tag TEXT,
            retro_of_utc TIMESTAMPTZ,
            CONSTRAINT forecast_prices_slice_hour_key
                UNIQUE (date_time_utc, bidding_zone, lead_days, code_version, input_mode)
        )
        """)

        LibPQ.execute(cnx, """
        CREATE TABLE IF NOT EXISTS simulations.forecast_scores (
            market_date DATE NOT NULL,
            bidding_zone TEXT NOT NULL,
            lead_days INT NOT NULL,
            code_version INT NOT NULL,
            input_mode TEXT NOT NULL DEFAULT 'entsoe',
            n_hours INT,
            mae DOUBLE PRECISION,
            bias DOUBLE PRECISION,  -- sim − actual
            corr DOUBLE PRECISION,
            -- Collapse classification (SCIENTIST.md §4, threshold ≤ €5).
            -- ADDITIVE; NULL on legacy rows scored before the per-lead board.
            n_collapse_actual INT,
            n_collapse_pred INT,
            collapse_hits INT,
            collapse_false_alarms INT,
            collapse_hit_rate DOUBLE PRECISION,
            collapse_false_alarm_rate DOUBLE PRECISION,
            -- Retro provenance mirror of forecast_prices (ADDITIVE).
            is_retro BOOLEAN NOT NULL DEFAULT false,
            reset_tag TEXT,
            scored_at TIMESTAMPTZ DEFAULT now(),
            PRIMARY KEY (market_date, bidding_zone, lead_days, code_version, input_mode)
        )
        """)

        # Data-reset backup table (EUPHEMIA_RETRO_SUPERSEDE): when a retro
        # reconstruction REPLACES an existing genuine LIVE vintage, the live rows
        # are copied here first — verbatim, with superseded_at_utc — so "what we
        # said then" is preserved for audit even though the live series now shows
        # the reset. The backup IS the honesty mechanism in supersede mode. Same
        # data columns as forecast_prices (a surrogate backup_id, no unique key —
        # it accumulates every superseded generation).
        LibPQ.execute(cnx, """
        CREATE TABLE IF NOT EXISTS simulations.forecast_prices_pre_reset (
            backup_id BIGSERIAL PRIMARY KEY,
            market_date DATE NOT NULL,
            date_time_utc TIMESTAMPTZ NOT NULL,
            bidding_zone TEXT NOT NULL,
            price_eur_mwh DOUBLE PRECISION NOT NULL,
            prediction_made_utc TIMESTAMPTZ NOT NULL,
            lead_days INT NOT NULL,
            clearing_mode TEXT,
            code_version INT NOT NULL,
            input_mode TEXT NOT NULL,
            is_retro BOOLEAN,
            reset_tag TEXT,
            retro_of_utc TIMESTAMPTZ,
            superseded_at_utc TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """)

        # Migrate pre-existing tables: add input_mode (backfills 'entsoe' on
        # legacy rows) and rebuild the unique/primary keys to include it, so
        # the reference and weather tracks never collide. The DO blocks check
        # pg_constraint and only touch constraints that lack input_mode —
        # idempotent, no-op on fresh tables.
        #
        # WEDGE GUARD (2026-07-23): `ALTER ... ADD COLUMN IF NOT EXISTS` takes
        # ACCESS EXCLUSIVE even when the column exists, so any long reader on
        # forecast_prices (a slow scoring query, Metabase, an orphan of a
        # cancelled run) blocked it — and behind it every other query — for
        # hours. The daily-forecast run then died at its 2 h timeout, leaving
        # its own orphan reader for the NEXT day's ALTER to wedge on: the
        # cycle cancelled 4 consecutive daily runs (07-20..07-23). Fix: check
        # the catalog first and skip the DDL entirely in the steady state;
        # when the migration IS needed, run it under a 30 s lock_timeout so a
        # busy table fails the run fast and loudly instead of wedging it.
        needs_migration = LibPQ.execute(cnx, """
            SELECT COUNT(*) = 0 AS missing FROM information_schema.columns
            WHERE table_schema = 'simulations' AND table_name = 'forecast_prices'
              AND column_name = 'input_mode'
            """) |> DataFrame |> df -> df.missing[1]
        if needs_migration
            LibPQ.execute(cnx, """
            ALTER TABLE simulations.forecast_prices
                ADD COLUMN IF NOT EXISTS input_mode TEXT NOT NULL DEFAULT 'entsoe'
            """)
            LibPQ.execute(cnx, """
            ALTER TABLE simulations.forecast_scores
                ADD COLUMN IF NOT EXISTS input_mode TEXT NOT NULL DEFAULT 'entsoe'
            """)
        end

        # ADDITIVE migration: retro-reconstruction provenance + per-lead
        # collapse metrics (docs/experiments/pregate-7lead.md). Same catalog-
        # first WEDGE GUARD as input_mode above — probe for one new column and
        # skip the ALTERs entirely in the steady state, so the daily run never
        # takes ACCESS EXCLUSIVE on a busy table once the migration has run.
        needs_retro_migration = LibPQ.execute(cnx, """
            SELECT COUNT(*) = 0 AS missing FROM information_schema.columns
            WHERE table_schema = 'simulations' AND table_name = 'forecast_prices'
              AND column_name = 'is_retro'
            """) |> DataFrame |> df -> df.missing[1]
        if needs_retro_migration
            LibPQ.execute(cnx, """
            ALTER TABLE simulations.forecast_prices
                ADD COLUMN IF NOT EXISTS is_retro BOOLEAN NOT NULL DEFAULT false,
                ADD COLUMN IF NOT EXISTS reset_tag TEXT,
                ADD COLUMN IF NOT EXISTS retro_of_utc TIMESTAMPTZ
            """)
            LibPQ.execute(cnx, """
            ALTER TABLE simulations.forecast_scores
                ADD COLUMN IF NOT EXISTS n_collapse_actual INT,
                ADD COLUMN IF NOT EXISTS n_collapse_pred INT,
                ADD COLUMN IF NOT EXISTS collapse_hits INT,
                ADD COLUMN IF NOT EXISTS collapse_false_alarms INT,
                ADD COLUMN IF NOT EXISTS collapse_hit_rate DOUBLE PRECISION,
                ADD COLUMN IF NOT EXISTS collapse_false_alarm_rate DOUBLE PRECISION,
                ADD COLUMN IF NOT EXISTS is_retro BOOLEAN NOT NULL DEFAULT false,
                ADD COLUMN IF NOT EXISTS reset_tag TEXT
            """)
        end

        LibPQ.execute(cnx, """
        DO \$\$
        DECLARE c record;
        BEGIN
            FOR c IN
                SELECT con.conname FROM pg_constraint con
                WHERE con.conrelid = 'simulations.forecast_prices'::regclass
                  AND con.contype = 'u'
                  AND NOT EXISTS (
                      SELECT 1 FROM unnest(con.conkey) k
                      JOIN pg_attribute a
                        ON a.attrelid = con.conrelid AND a.attnum = k
                      WHERE a.attname = 'input_mode')
            LOOP
                EXECUTE format('ALTER TABLE simulations.forecast_prices DROP CONSTRAINT %I',
                               c.conname);
            END LOOP;
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conrelid = 'simulations.forecast_prices'::regclass
                  AND contype = 'u'
            ) THEN
                ALTER TABLE simulations.forecast_prices
                ADD CONSTRAINT forecast_prices_slice_hour_key
                UNIQUE (date_time_utc, bidding_zone, lead_days, code_version, input_mode);
            END IF;
        END \$\$;
        """)

        LibPQ.execute(cnx, """
        DO \$\$
        DECLARE c record;
        BEGIN
            FOR c IN
                SELECT con.conname FROM pg_constraint con
                WHERE con.conrelid = 'simulations.forecast_scores'::regclass
                  AND con.contype = 'p'
                  AND NOT EXISTS (
                      SELECT 1 FROM unnest(con.conkey) k
                      JOIN pg_attribute a
                        ON a.attrelid = con.conrelid AND a.attnum = k
                      WHERE a.attname = 'input_mode')
            LOOP
                EXECUTE format('ALTER TABLE simulations.forecast_scores DROP CONSTRAINT %I',
                               c.conname);
                ALTER TABLE simulations.forecast_scores
                ADD PRIMARY KEY (market_date, bidding_zone, lead_days, code_version, input_mode);
            END LOOP;
        END \$\$;
        """)

        LibPQ.execute(cnx, """
        CREATE INDEX IF NOT EXISTS idx_forecast_prices_market_date
        ON simulations.forecast_prices (market_date, lead_days, code_version)
        """)

        LibPQ.execute(cnx, """
        CREATE INDEX IF NOT EXISTS idx_forecast_prices_zone_time
        ON simulations.forecast_prices (bidding_zone, date_time_utc)
        """)

        LibPQ.execute(cnx, "SET lock_timeout = DEFAULT")
    end
    @info "Forecast tables schema verified/created"
    return nothing
end

"""
    save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol;
                       clearing_mode::String="single_zone", optimization_run_id::Union{Integer,Nothing}=nothing,
                       batch_size::Int=100, create_schema::Bool=true)

Save energy prices to the database in the simulations.energy_prices table.
Creates the schema and table if they don't exist (when create_schema=true).
Assumes connection is already to the 'energy' database.

# Arguments
- `prices`: Dictionary with timeslot keys ("YYYYMMDD-HHMM") and price values in EUR/MWh
- `bidding_zone`: Bidding zone code (e.g., "GR", "AL")
- `day`: Date of the prices
- `order_method`: always `:merit_order` since cv25
- `clearing_mode`: Market clearing mode ("single_zone" or "multi_zone", default: "single_zone")
- `optimization_run_id`: Foreign key to simulations.optimization_runs (default: nothing)
- `batch_size`: Number of records to insert per batch (default: 100)
- `create_schema`: Whether to create schema/table if missing (default: true)

# Table Schema
- `date_time_utc`: Timestamp in UTC
- `resolution_code`: Temporal resolution (15M, 30M, 1H)
- `bidding_zone`: Bidding zone code
- `contract_type`: Always "Day-Ahead" for now
- `price_eur_mwh`: Energy price in EUR/MWh
- `currency`: Always "EUR" for now
- `update_time_utc`: Timestamp when record was inserted
- `order_method`: Method used to generate prices
- `clearing_mode`: Market clearing mode (single_zone or multi_zone)
- `optimization_run_id`: Foreign key to the optimization run that generated these prices
- `code_version`: Version code (current: 3 — bumped when the cost/pricing model changes incompatibly)
"""
function save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol;
                            clearing_mode::String="single_zone", optimization_run_id::Union{Integer,Nothing}=nothing,
                            batch_size::Int=100, create_schema::Bool=true)
    if DATA_STORE[] == :duckdb
        return _duckdb_save_energy_prices(prices, bidding_zone, day, order_method;
            clearing_mode=clearing_mode, optimization_run_id=optimization_run_id)
    end
    if isempty(prices)
        @warn "No prices to save for $bidding_zone on $day"
        return 0
    end

    # Create schema and table if requested
    if create_schema
        ensure_energy_prices_table()
    end

    # Detect resolution from number of periods
    num_periods = length(prices)
    resolution_code = if num_periods == 96
        "15M"
    elseif num_periods == 48
        "30M"
    elseif num_periods == 24
        "1H"
    else
        @warn "Unexpected number of periods: $num_periods, defaulting to 1H"
        "1H"
    end

    # Prepare data for batch insertion
    # Tuple: (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc)
    records = Vector{Tuple{DateTime,String,String,String,Float64,String,String,String,Union{Int,Missing},Int,DateTime}}()
    sizehint!(records, length(prices))  # Pre-allocate for efficiency
    update_time = now(UTC)
    order_method_str = string(order_method)  # Convert once
    opt_run_id = optimization_run_id === nothing ? missing : optimization_run_id

    for (timeslot, price) in prices
        # Parse timeslot "YYYYMMDD-HHMM" to DateTime using DateFormat for efficiency
        try
            # More efficient: use DateFormat instead of manual parsing
            date_time_utc = DateTime(timeslot, dateformat"yyyymmdd-HHMM")

            push!(records, (
                date_time_utc,
                resolution_code,
                bidding_zone,
                "Day-Ahead",
                price,
                "EUR",
                order_method_str,
                clearing_mode,
                opt_run_id,
                ENERGY_PRICES_CODE_VERSION,
                update_time
            ))
        catch e
            @error "Failed to parse timeslot '$timeslot': $e"
            continue
        end
    end

    if isempty(records)
        @error "No valid records to insert"
        return 0
    end

    # Delete existing records for this bidding_zone/date/order_method/clearing_mode/code_version before inserting
    # This ensures we replace incomplete data from previous failed runs
    try
        withdb() do cnx
            delete_sql = """
            DELETE FROM simulations.energy_prices
            WHERE bidding_zone = \$1
              AND DATE(date_time_utc) = \$2
              AND order_method = \$3
              AND clearing_mode = \$4
              AND code_version = \$5
            """
            LibPQ.execute(cnx, delete_sql, [bidding_zone, day, order_method_str, clearing_mode, ENERGY_PRICES_CODE_VERSION])
            @info "Deleted existing price records for $bidding_zone on $day (order_method: $order_method, clearing_mode: $clearing_mode) if any existed"
        end
    catch delete_error
        @error "Failed to delete existing records: $delete_error"
        rethrow(delete_error)
    end

    # Insert in batches
    total_inserted = 0

    sql = """
    INSERT INTO simulations.energy_prices
    (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11)
    """

    for batch_start in 1:batch_size:length(records)
        batch_end = min(batch_start + batch_size - 1, length(records))
        batch = records[batch_start:batch_end]

        try
            withdb() do cnx
                # Use transaction for batch
                LibPQ.execute(cnx, "BEGIN")

                try
                    for record in batch
                        LibPQ.execute(cnx, sql, collect(record))
                    end
                    LibPQ.execute(cnx, "COMMIT")
                    total_inserted += length(batch)
                    @info "Inserted batch $(div(batch_start-1, batch_size)+1): $(length(batch)) records"
                catch batch_error
                    LibPQ.execute(cnx, "ROLLBACK")
                    @error "Batch insertion failed: $batch_error"
                    rethrow(batch_error)
                end
            end
        catch e
            @error "Database error in batch $(div(batch_start-1, batch_size)+1): $e"
            # Continue with next batch or rethrow based on requirements
            rethrow(e)
        end
    end

    @info "Successfully saved $total_inserted energy price records for $bidding_zone on $day (order_method: $order_method, clearing_mode: $clearing_mode)"
    return total_inserted
end

"""
    save_optimization_run(bidding_zone::String, date::Date, order_method::Symbol, model_type::Symbol,
                          optimizer::String, status::Symbol; kwargs...) -> Union{Int, Nothing}

Save optimization run metadata to track all optimization attempts (successful and failed).

# Arguments
- `bidding_zone`: Bidding zone code (e.g., "GR", "AL", or "MULTI_ZONE" for multi-zone runs)
- `date`: Date of the optimization
- `order_method`: always `:merit_order` since cv25
- `model_type`: Model used (:mpcc, :mpcc_multi_zone, :mpcc_iterative, etc.)
- `optimizer`: Solver used ("highs", "gurobi", "cplex")
- `status`: Optimization status (:optimal, :infeasible, :time_limit, etc.)
- `objective_value`: Final objective value (nothing for failed runs)
- `solve_time_seconds`: Solution time in seconds (for iterative runs, this is the final MPCC solve time)
- `num_orders`: Number of orders in the order book
- `num_price_periods`: Number of price periods generated (nothing for failed runs)
- `error_message`: Error details for failed runs (nothing for successful runs)
- `code_version`: Version code (default: 4)
- `create_schema`: Whether to create schema/table if missing (default: true)

## Iterative optimization metadata (for UC-MPCC iterative runs)
- `is_iterative`: Whether this was an iterative optimization run (default: false)
- `total_time_seconds`: Total time for all iterations including UC solves (nothing for non-iterative)
- `iterations`: Number of iterations performed (nothing for non-iterative)
- `converged`: Whether the iterative algorithm converged (nothing for non-iterative)
- `final_price_change`: Final max price change in €/MWh at convergence/termination
- `final_flow_change_pct`: Final flow change percentage at convergence/termination

# Returns
- `Int`: The ID of the inserted optimization run record, or `nothing` if insertion failed
"""
function save_optimization_run(bidding_zone::String, date::Date, order_method::Symbol, model_type::Symbol,
    optimizer::String, status::Symbol;
    objective_value=nothing,
    solve_time_seconds=nothing,
    num_orders=nothing,
    num_price_periods=nothing,
    error_message=nothing,
    code_version::Int=4,
    create_schema::Bool=true,
    # Iterative optimization metadata
    is_iterative::Bool=false,
    total_time_seconds=nothing,
    iterations=nothing,
    converged=nothing,
    final_price_change=nothing,
    final_flow_change_pct=nothing)

    if DATA_STORE[] == :duckdb
        return _duckdb_save_optimization_run(bidding_zone, date, order_method, model_type,
            optimizer, status; objective_value=objective_value, solve_time_seconds=solve_time_seconds,
            num_orders=num_orders, num_price_periods=num_price_periods, error_message=error_message,
            code_version=code_version, is_iterative=is_iterative, total_time_seconds=total_time_seconds,
            iterations=iterations, converged=converged, final_price_change=final_price_change,
            final_flow_change_pct=final_flow_change_pct)
    end

    # Create schema and table if requested
    if create_schema
        ensure_energy_prices_table()  # This now creates both tables
    end

    try
        run_id = withdb() do cnx
            # Upsert: re-running the same configuration (e.g. a backfill after
            # a model fix) replaces the run record instead of raising a
            # UniqueViolation. The thrown violation used to abort the whole
            # save mid-transaction and could poison the pooled connection.
            sql = """
            INSERT INTO simulations.optimization_runs
            (bidding_zone, optimization_date, order_method, model_type, optimizer, status,
             objective_value, solve_time_seconds, num_orders, num_price_periods, error_message,
             code_version, created_at,
             is_iterative, total_time_seconds, iterations, converged, final_price_change, final_flow_change_pct)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13,
                    \$14, \$15, \$16, \$17, \$18, \$19)
            ON CONFLICT (bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)
            DO UPDATE SET
                status = EXCLUDED.status,
                objective_value = EXCLUDED.objective_value,
                solve_time_seconds = EXCLUDED.solve_time_seconds,
                num_orders = EXCLUDED.num_orders,
                num_price_periods = EXCLUDED.num_price_periods,
                error_message = EXCLUDED.error_message,
                created_at = EXCLUDED.created_at,
                is_iterative = EXCLUDED.is_iterative,
                total_time_seconds = EXCLUDED.total_time_seconds,
                iterations = EXCLUDED.iterations,
                converged = EXCLUDED.converged,
                final_price_change = EXCLUDED.final_price_change,
                final_flow_change_pct = EXCLUDED.final_flow_change_pct
            RETURNING id
            """

            result = LibPQ.execute(cnx, sql, [
                bidding_zone,
                date,
                string(order_method),
                string(model_type),
                optimizer,
                string(status),
                objective_value === nothing ? missing : objective_value,
                solve_time_seconds === nothing ? missing : solve_time_seconds,
                num_orders === nothing ? missing : num_orders,
                num_price_periods === nothing ? missing : num_price_periods,
                error_message === nothing ? missing : error_message,
                code_version,
                now(UTC),
                is_iterative,
                total_time_seconds === nothing ? missing : total_time_seconds,
                iterations === nothing ? missing : iterations,
                converged === nothing ? missing : converged,
                final_price_change === nothing ? missing : final_price_change,
                final_flow_change_pct === nothing ? missing : final_flow_change_pct
            ])

            # Get the returned ID
            df = DataFrame(result)
            return df.id[1]
        end

        @info "Saved optimization run: $bidding_zone on $date ($status) with id=$run_id"
        return run_id

    catch e
        @error "Failed to save optimization run for $bidding_zone on $date: $e"
        return nothing
    end
end

"""
    ensure_transmission_flows_table()

Creates the simulations.transmission_flows table if it doesn't exist.
Used to store cross-border transmission flow results from multi-zone market clearing.
"""
function ensure_transmission_flows_table()
    _duckdb_readonly_guard("ensure_transmission_flows_table") && return nothing
    withdb() do cnx
        create_table_sql = """
        CREATE TABLE IF NOT EXISTS simulations.transmission_flows (
            id SERIAL PRIMARY KEY,
            date_time_utc TIMESTAMP NOT NULL,
            source_zone VARCHAR(20) NOT NULL,
            sink_zone VARCHAR(20) NOT NULL,
            flow_mw NUMERIC(10,2) NOT NULL,
            code_version INTEGER NOT NULL,
            update_time_utc TIMESTAMP NOT NULL,
            UNIQUE(date_time_utc, source_zone, sink_zone, code_version)
        )
        """

        LibPQ.execute(cnx, create_table_sql)

        # Create useful indexes
        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_transmission_flows_datetime
ON simulations.transmission_flows (date_time_utc)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_transmission_flows_zones
ON simulations.transmission_flows (source_zone, sink_zone, date_time_utc)
"""
        )
    end

    @info "Transmission flows table schema verified/created"
end

"""
    save_transmission_flows(flows::Dict{String,Dict{String,Float64}}, date::Date;
                           code_version::Int=4, create_schema::Bool=true)

Save transmission flow results to the database in the simulations.transmission_flows table.

# Arguments
- `flows`: Dictionary with flow_id keys ("SOURCE_to_SINK") and inner Dict of period → MW values
- `date`: Date of the optimization
- `code_version`: Version code (default: 4)
- `create_schema`: Whether to create table if missing (default: true)

# Returns
- Number of records inserted
"""
function save_transmission_flows(flows::Dict{String,Dict{String,Float64}}, date::Date;
                                 code_version::Int=4, create_schema::Bool=true)
    if DATA_STORE[] == :duckdb
        return _duckdb_save_transmission_flows(flows, date; code_version=code_version)
    end
    if isempty(flows)
        @warn "No transmission flows to save"
        return 0
    end

    # Create table if requested
    if create_schema
        ensure_transmission_flows_table()
    end

    update_time = now(UTC)
    total_inserted = 0

    sql = """
    INSERT INTO simulations.transmission_flows
    (date_time_utc, source_zone, sink_zone, flow_mw, code_version, update_time_utc)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6)
    ON CONFLICT (date_time_utc, source_zone, sink_zone, code_version)
    DO UPDATE SET flow_mw = EXCLUDED.flow_mw, update_time_utc = EXCLUDED.update_time_utc
    """

    try
        withdb() do cnx
            LibPQ.execute(cnx, "BEGIN")

            try
                for (flow_id, period_flows) in flows
                    # Parse flow_id: "SOURCE_to_SINK"
                    parts = split(flow_id, "_to_")
                    if length(parts) != 2
                        @warn "Invalid flow_id format: $flow_id (expected SOURCE_to_SINK)"
                        continue
                    end
                    source_zone = parts[1]
                    sink_zone = parts[2]

                    for (period, flow_mw) in period_flows
                        # Parse period: "YYYYMMDD-HHMM" or hourly "1"-"24"
                        if length(period) >= 13 && contains(period, "-")
                            # Parse timeslot format "YYYYMMDD-HHMM"
                            date_time_utc = DateTime(period, dateformat"yyyymmdd-HHMM")
                        else
                            # Parse hourly format "1"-"24"
                            hour = parse(Int, period) - 1  # Convert 1-24 to 0-23
                            date_time_utc = DateTime(date) + Hour(hour)
                        end

                        LibPQ.execute(cnx, sql, [
                            date_time_utc,
                            source_zone,
                            sink_zone,
                            flow_mw,
                            code_version,
                            update_time
                        ])
                        total_inserted += 1
                    end
                end

                LibPQ.execute(cnx, "COMMIT")
                @info "Successfully saved $total_inserted transmission flow records"

            catch batch_error
                LibPQ.execute(cnx, "ROLLBACK")
                @error "Transmission flow insertion failed: $batch_error"
                rethrow(batch_error)
            end
        end
    catch e
        @error "Database error saving transmission flows: $e"
        rethrow(e)
    end

    return total_inserted
end


"""
    ensure_indexes()

Create indexes on ENTSOE tables to speed up common queries.
This function is idempotent (safe to run multiple times).

Indexes are created with CONCURRENTLY to avoid locking tables during creation.
First run may take 30-60 minutes for large tables. Subsequent runs are instant.

# Example
```julia
using Euphemia
Euphemia.ensure_indexes()  # Run once after DB setup, or when queries are slow
```
"""
function ensure_indexes()
    _duckdb_readonly_guard("ensure_indexes") && return nothing
    @info "Ensuring indexes on ENTSOE tables..."

    withdb() do cnx
        # Index for parameter inference and initial conditions queries
        # Table: 54 GB, 260M rows - queries by generator_code + date range
        @info "Creating index on actual_generation_output_per_generation_unit (this may take 30-60 min first time)..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_actual_gen_unit_date
            ON entsoe.actual_generation_output_per_generation_unit
            (generation_unit_code, date_time_utc);
        """)

        # Index for outage/unavailability filtering in get_generators()
        # Table: 4.4 GB, 9.5M rows - queries by asset_code + date range
        @info "Creating index on unavailability_of_production_and_generation_units..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unavail_asset_date
            ON entsoe.unavailability_of_production_and_generation_units
            (asset_code, start_outage_utc);
        """)

        # Indexes for get_generators()'s per-zone unit lookup. The table has NO
        # indexes, so both the main query's `area_map_code = $1` filter and the
        # recent-generation CTE's unit-code subquery seq-scanned it (~280 ms each,
        # 2-3x per zone). area_map_code drives the zone filter; generation_unit_code
        # serves the DISTINCT-ON dedup / code lookups.
        @info "Creating indexes on production_and_generation_units..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_prod_gen_units_area
            ON entsoe.production_and_generation_units (area_map_code);
        """)
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_prod_gen_units_gen_code
            ON entsoe.production_and_generation_units (generation_unit_code);
        """)

        # Index for hydro availability / per-type generation queries
        # Table: 23 GB - queries by zone + production_type + date range
        @info "Creating index on aggregated_generation_per_type..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_agg_gen_type_zone_date
            ON entsoe.aggregated_generation_per_type
            (area_map_code, production_type, date_time_utc);
        """)

        # Index for actual DAM price lookups (eval harness, Metabase
        # sim-vs-actual dashboard). Table: ~6.5M rows, ETL-populated
        @info "Creating index on energy_prices (actuals)..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_entsoe_energy_prices_zone_contract_time
            ON entsoe.energy_prices
            (map_code, contract_type, date_time_utc);
        """)

        # Indexes for the merit-order book creation queries — these four
        # tables are ETL-populated with no indexes, so every zone-day book
        # build seq-scanned ~29 GB (loads, RES forecast, net imports, ATC)
        @info "Creating index on day_ahead_total_load_forecast..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_load_fcst_zone_time
            ON entsoe.day_ahead_total_load_forecast (area_map_code, date_time_utc);
        """)
        # actual_total_load had NO index: the :v3 analogue-day selection scans
        # a 365-day window per (zone, day) — 2 GB seq scan per call, ~1 s,
        # x39 zones per market day. With the index: 166 ms (measured 6x).
        @info "Creating index on actual_total_load..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_actual_load_zone_time
            ON entsoe.actual_total_load (area_map_code, date_time_utc);
        """)
        # Pure time-range probes on the day-ahead actuals (scoring discovery,
        # realized-day checks) could not use the zone-leading index — a 1.9 GB
        # seq scan per probe. Time-leading index fixes the class.
        @info "Creating index on entsoe.energy_prices (date_time_utc)..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_entsoe_energy_prices_time
            ON entsoe.energy_prices (date_time_utc);
        """)
        @info "Creating index on generation_forecasts_for_wind_and_solar..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_res_fcst_zone_time
            ON entsoe.generation_forecasts_for_wind_and_solar (area_map_code, date_time_utc);
        """)
        @info "Creating indexes on physical_flows..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_physical_flows_in_time
            ON entsoe.physical_flows (in_area_map_code, date_time_utc);
        """)
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_physical_flows_out_time
            ON entsoe.physical_flows (out_area_map_code, date_time_utc);
        """)
        @info "Creating index on offered_transfer_capacities_implicit..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_atc_borders_time
            ON entsoe.offered_transfer_capacities_implicit (out_map_code, in_map_code, date_time_utc);
        """)

        # Add more indexes here as needed:
        # - generation_forecasts_for_wind_and_solar (zone, date)
        # - day_ahead_total_load_forecast (zone, date)
        # - offered_transfer_capacities_implicit (zone pairs, date)
    end

    @info "Indexes ensured successfully"
end
