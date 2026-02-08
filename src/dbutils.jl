using LibPQ
using ConcurrentUtilities: ConcurrentUtilities, Pools
using Dates

# Unified code version — bump when cost model or schema changes
const CURRENT_CODE_VERSION = 6

const poolsize = 5
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

sql2df(sql, args=[]) =
    withdb() do cnx
        result = LibPQ.async_execute(cnx, sql, args)
        return DataFrame(fetch(result))
    end

"""
    sql2df_with_retry(sql, args=[]; max_retries=3, retry_delay=2.0)

Execute SQL query with automatic retry on connection failures.
"""
function sql2df_with_retry(sql, args=[]; max_retries=3, retry_delay=2.0)
    last_error = nothing

    for attempt in 1:max_retries
        try
            return sql2df(sql, args)
        catch e
            last_error = e

            # Check if it's a connection-related error
            if isa(e, LibPQ.Errors.JLConnectionError) ||
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

"""
    ensure_energy_prices_table()

Creates the simulations schema and energy_prices table if they don't exist.
Assumes connection is already to the 'energy' database.
"""
function ensure_energy_prices_table()
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

        # Add optimizer column to energy_prices if it doesn't exist
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND column_name = 'optimizer'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD COLUMN optimizer VARCHAR(20);
                END IF;
            END \$\$;
        """)

        # Migrate unique constraint to include optimizer (so HiGHS vs Gurobi results coexist)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Check if the current constraint does NOT include optimizer
                IF EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'energy_prices_unique_record'
                    AND conrelid = 'simulations.energy_prices'::regclass
                ) AND NOT EXISTS (
                    SELECT 1 FROM pg_indexes
                    WHERE schemaname = 'simulations'
                    AND tablename = 'energy_prices'
                    AND indexname = 'energy_prices_unique_record'
                    AND indexdef LIKE '%optimizer%'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    DROP CONSTRAINT energy_prices_unique_record;
                    ALTER TABLE simulations.energy_prices
                    ADD CONSTRAINT energy_prices_unique_record
                    UNIQUE (date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version, optimizer);
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

        # Add clearing_mode and Tier 2/3 parameter columns to optimization_runs
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- clearing_mode (Tier 1, currently missing from this table)
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'clearing_mode') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN clearing_mode VARCHAR(20);
                END IF;
                -- Tier 2: methodology parameters
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'markup_factor') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN markup_factor NUMERIC(5,3) DEFAULT 1.1;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'bidding_strategy') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN bidding_strategy VARCHAR(30) DEFAULT 'merit_order';
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'demand_price') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN demand_price NUMERIC(10,2) DEFAULT 500.0;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'mip_gap') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN mip_gap NUMERIC(6,4) DEFAULT 0.01;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'time_limit_seconds') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN time_limit_seconds NUMERIC(10,1) DEFAULT 600.0;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'curtailment_penalty') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN curtailment_penalty NUMERIC(10,2) DEFAULT 1.0;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'excess_penalty') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN excess_penalty NUMERIC(10,2) DEFAULT 10000.0;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'shortage_penalty') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN shortage_penalty NUMERIC(10,2) DEFAULT 10000.0;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'use_inferred_params') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN use_inferred_params BOOLEAN DEFAULT TRUE;
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'cost_model_version') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN cost_model_version VARCHAR(10) DEFAULT 'v2';
                END IF;
                -- Tier 3: iterative input settings
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'price_tolerance') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN price_tolerance NUMERIC(6,2);
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'damping_factor') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN damping_factor NUMERIC(4,2);
                END IF;
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'max_iterations_setting') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN max_iterations_setting INTEGER;
                END IF;
            END \$\$;
        """)

        # Migrate optimization_runs unique constraint to include clearing_mode
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Check if the current unique constraint does NOT include clearing_mode
                IF EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = 'optimization_runs_bidding_zone_optimization_date_order_method_key'
                    AND conrelid = 'simulations.optimization_runs'::regclass
                ) THEN
                    ALTER TABLE simulations.optimization_runs
                    DROP CONSTRAINT optimization_runs_bidding_zone_optimization_date_order_method_key;
                    ALTER TABLE simulations.optimization_runs
                    ADD CONSTRAINT optimization_runs_unique_record
                    UNIQUE (bidding_zone, optimization_date, order_method, model_type, clearing_mode, code_version, optimizer);
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
    save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol;
                       clearing_mode::String="single_zone", optimizer::Union{String,Nothing}=nothing,
                       optimization_run_id::Union{Integer,Nothing}=nothing,
                       batch_size::Int=100, create_schema::Bool=true)

Save energy prices to the database in the simulations.energy_prices table.
Creates the schema and table if they don't exist (when create_schema=true).

# Arguments
- `prices`: Dictionary with timeslot keys ("YYYYMMDD-HHMM") and price values in EUR/MWh
- `bidding_zone`: Bidding zone code (e.g., "GR", "AL")
- `day`: Date of the prices
- `order_method`: Method used (:uc_based or :alternative)
- `clearing_mode`: Market clearing mode ("single_zone", "multi_zone", or "multi_zone_iterative")
- `optimizer`: Solver used ("highs", "gurobi", etc.) — part of unique constraint
- `optimization_run_id`: Foreign key to simulations.optimization_runs (default: nothing)
- `batch_size`: Number of records to insert per batch (default: 100)
- `create_schema`: Whether to create schema/table if missing (default: true)
"""
function save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol;
                            clearing_mode::String="single_zone", optimizer::Union{String,Nothing}=nothing,
                            optimization_run_id::Union{Integer,Nothing}=nothing,
                            batch_size::Int=100, create_schema::Bool=true)
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
    update_time = now(UTC)
    order_method_str = string(order_method)
    opt_run_id = optimization_run_id === nothing ? missing : optimization_run_id
    opt_str = optimizer === nothing ? missing : optimizer

    records = Vector{Any}()
    sizehint!(records, length(prices))

    for (timeslot, price) in prices
        try
            date_time_utc = DateTime(timeslot, dateformat"yyyymmdd-HHMM")

            push!(records, [
                date_time_utc,
                resolution_code,
                bidding_zone,
                "Day-Ahead",
                price,
                "EUR",
                order_method_str,
                clearing_mode,
                opt_run_id,
                CURRENT_CODE_VERSION,
                update_time,
                opt_str
            ])
        catch e
            @error "Failed to parse timeslot '$timeslot': $e"
            continue
        end
    end

    if isempty(records)
        @error "No valid records to insert"
        return 0
    end

    # Delete existing records for this bidding_zone/date/order_method/clearing_mode/code_version/optimizer before inserting
    try
        withdb() do cnx
            delete_sql = """
            DELETE FROM simulations.energy_prices
            WHERE bidding_zone = \$1
              AND DATE(date_time_utc) = \$2
              AND order_method = \$3
              AND clearing_mode = \$4
              AND code_version = \$5
              AND (optimizer = \$6 OR (\$6 IS NULL AND optimizer IS NULL))
            """
            LibPQ.execute(cnx, delete_sql, [bidding_zone, day, order_method_str, clearing_mode, CURRENT_CODE_VERSION, opt_str])
            @info "Deleted existing price records for $bidding_zone on $day (order_method=$order_method, clearing_mode=$clearing_mode, optimizer=$optimizer)"
        end
    catch delete_error
        @error "Failed to delete existing records: $delete_error"
        rethrow(delete_error)
    end

    # Insert in batches
    total_inserted = 0

    sql = """
    INSERT INTO simulations.energy_prices
    (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc, optimizer)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12)
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
- `order_method`: Method used (:uc_based or :alternative)
- `model_type`: Model used (:mpcc, :mpcc_multi_zone, :mpcc_iterative, etc.)
- `optimizer`: Solver used ("highs", "gurobi", "cplex")
- `status`: Optimization status (:optimal, :infeasible, :time_limit, etc.)
- `objective_value`: Final objective value (nothing for failed runs)
- `solve_time_seconds`: Solution time in seconds (for iterative runs, this is the final MPCC solve time)
- `num_orders`: Number of orders in the order book
- `num_price_periods`: Number of price periods generated (nothing for failed runs)
- `error_message`: Error details for failed runs (nothing for successful runs)
- `code_version`: Version code (default: 3)
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
    code_version::Int=CURRENT_CODE_VERSION,
    create_schema::Bool=true,
    # Iterative optimization metadata
    is_iterative::Bool=false,
    total_time_seconds=nothing,
    iterations=nothing,
    converged=nothing,
    final_price_change=nothing,
    final_flow_change_pct=nothing,
    # Tier 1: clearing mode
    clearing_mode::Union{String,Nothing}=nothing,
    # Tier 2: methodology parameters
    markup_factor::Union{Float64,Nothing}=nothing,
    bidding_strategy::Union{String,Nothing}=nothing,
    demand_price::Union{Float64,Nothing}=nothing,
    mip_gap::Union{Float64,Nothing}=nothing,
    time_limit_seconds_param::Union{Float64,Nothing}=nothing,
    curtailment_penalty::Union{Float64,Nothing}=nothing,
    excess_penalty::Union{Float64,Nothing}=nothing,
    shortage_penalty::Union{Float64,Nothing}=nothing,
    use_inferred_params::Union{Bool,Nothing}=nothing,
    cost_model_version::Union{String,Nothing}=nothing,
    # Tier 3: iterative input settings
    price_tolerance::Union{Float64,Nothing}=nothing,
    damping_factor::Union{Float64,Nothing}=nothing,
    max_iterations_setting::Union{Int,Nothing}=nothing)

    # Create schema and table if requested
    if create_schema
        ensure_energy_prices_table()  # This now creates both tables
    end

    _or_missing(x) = x === nothing ? missing : x

    try
        run_id = withdb() do cnx
            sql = """
            INSERT INTO simulations.optimization_runs
            (bidding_zone, optimization_date, order_method, model_type, optimizer, status,
             objective_value, solve_time_seconds, num_orders, num_price_periods, error_message,
             code_version, created_at,
             is_iterative, total_time_seconds, iterations, converged, final_price_change, final_flow_change_pct,
             clearing_mode,
             markup_factor, bidding_strategy, demand_price, mip_gap, time_limit_seconds,
             curtailment_penalty, excess_penalty, shortage_penalty,
             use_inferred_params, cost_model_version,
             price_tolerance, damping_factor, max_iterations_setting)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13,
                    \$14, \$15, \$16, \$17, \$18, \$19,
                    \$20,
                    \$21, \$22, \$23, \$24, \$25,
                    \$26, \$27, \$28,
                    \$29, \$30,
                    \$31, \$32, \$33)
            RETURNING id
            """

            result = LibPQ.execute(cnx, sql, [
                bidding_zone,
                date,
                string(order_method),
                string(model_type),
                optimizer,
                string(status),
                _or_missing(objective_value),
                _or_missing(solve_time_seconds),
                _or_missing(num_orders),
                _or_missing(num_price_periods),
                _or_missing(error_message),
                code_version,
                now(UTC),
                is_iterative,
                _or_missing(total_time_seconds),
                _or_missing(iterations),
                _or_missing(converged),
                _or_missing(final_price_change),
                _or_missing(final_flow_change_pct),
                _or_missing(clearing_mode),
                _or_missing(markup_factor),
                _or_missing(bidding_strategy),
                _or_missing(demand_price),
                _or_missing(mip_gap),
                _or_missing(time_limit_seconds_param),
                _or_missing(curtailment_penalty),
                _or_missing(excess_penalty),
                _or_missing(shortage_penalty),
                _or_missing(use_inferred_params),
                _or_missing(cost_model_version),
                _or_missing(price_tolerance),
                _or_missing(damping_factor),
                _or_missing(max_iterations_setting),
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
                           code_version::Int=3, create_schema::Bool=true)

Save transmission flow results to the database in the simulations.transmission_flows table.

# Arguments
- `flows`: Dictionary with flow_id keys ("SOURCE_to_SINK") and inner Dict of period → MW values
- `date`: Date of the optimization
- `code_version`: Version code (default: 1)
- `create_schema`: Whether to create table if missing (default: true)

# Returns
- Number of records inserted
"""
function save_transmission_flows(flows::Dict{String,Dict{String,Float64}}, date::Date;
                                 code_version::Int=3, create_schema::Bool=true)
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
    ensure_uc_results_tables()

Creates the simulations.uc_results, simulations.uc_generation, and simulations.uc_net_demand tables
if they don't exist. Used to cache Unit Commitment optimization results.
"""
function ensure_uc_results_tables()
    withdb() do cnx
        # Create schema if not exists
        LibPQ.execute(cnx, "CREATE SCHEMA IF NOT EXISTS simulations")

        # Create uc_results summary table
        create_uc_results_sql = """
        CREATE TABLE IF NOT EXISTS simulations.uc_results (
            id SERIAL PRIMARY KEY,
            bidding_zone VARCHAR(20) NOT NULL,
            market_date DATE NOT NULL,
            status VARCHAR(30) NOT NULL,
            solver VARCHAR(20) NOT NULL,
            resolution_minutes INTEGER NOT NULL,
            num_generators INTEGER NOT NULL,
            num_periods INTEGER NOT NULL,
            total_cost NUMERIC(15,2),
            production_cost NUMERIC(15,2),
            startup_cost NUMERIC(15,2),
            noload_cost NUMERIC(15,2),
            hot_startups INTEGER DEFAULT 0,
            warm_startups INTEGER DEFAULT 0,
            cold_startups INTEGER DEFAULT 0,
            mip_gap NUMERIC(6,4) DEFAULT 0.01,
            time_limit_seconds NUMERIC(10,2) DEFAULT 600.0,
            code_version INTEGER NOT NULL DEFAULT 3,
            created_at TIMESTAMP NOT NULL DEFAULT NOW(),
            UNIQUE(bidding_zone, market_date, code_version)
        )
        """
        LibPQ.execute(cnx, create_uc_results_sql)

        # Create uc_generation detail table
        create_uc_generation_sql = """
        CREATE TABLE IF NOT EXISTS simulations.uc_generation (
            id SERIAL PRIMARY KEY,
            uc_result_id INTEGER NOT NULL REFERENCES simulations.uc_results(id) ON DELETE CASCADE,
            generator_code VARCHAR(50) NOT NULL,
            generator_idx INTEGER NOT NULL,
            period_idx INTEGER NOT NULL,
            time_slot_utc TIMESTAMP NOT NULL,
            generation_mw NUMERIC(10,2) NOT NULL,
            commitment INTEGER NOT NULL,
            startup INTEGER NOT NULL,
            UNIQUE(uc_result_id, generator_code, period_idx)
        )
        """
        LibPQ.execute(cnx, create_uc_generation_sql)

        # Create uc_net_demand table
        create_uc_net_demand_sql = """
        CREATE TABLE IF NOT EXISTS simulations.uc_net_demand (
            id SERIAL PRIMARY KEY,
            uc_result_id INTEGER NOT NULL REFERENCES simulations.uc_results(id) ON DELETE CASCADE,
            period_idx INTEGER NOT NULL,
            time_slot_utc TIMESTAMP NOT NULL,
            net_demand_mw NUMERIC(10,2) NOT NULL,
            renewable_generation_mw NUMERIC(10,2),
            UNIQUE(uc_result_id, period_idx)
        )
        """
        LibPQ.execute(cnx, create_uc_net_demand_sql)

        # Create indexes for efficient queries
        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_results_zone_date
            ON simulations.uc_results (bidding_zone, market_date)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_results_status
            ON simulations.uc_results (status)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_generation_result_id
            ON simulations.uc_generation (uc_result_id)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_generation_generator
            ON simulations.uc_generation (generator_code)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_net_demand_result_id
            ON simulations.uc_net_demand (uc_result_id)
        """)

        # Add curtailment and excess columns (schema migration for existing tables)
        # Using DO block to conditionally add columns if they don't exist
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Add curtailment columns to uc_results summary table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'total_curtailment_mwh') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN total_curtailment_mwh NUMERIC(12,2) DEFAULT 0;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'curtailment_cost') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN curtailment_cost NUMERIC(12,2) DEFAULT 0;
                END IF;

                -- Add excess generation columns to uc_results summary table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'total_excess_mwh') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN total_excess_mwh NUMERIC(12,2) DEFAULT 0;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'excess_cost') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN excess_cost NUMERIC(15,2) DEFAULT 0;
                END IF;

                -- Add curtailment column to uc_net_demand table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_net_demand'
                               AND column_name = 'curtailment_mw') THEN
                    ALTER TABLE simulations.uc_net_demand ADD COLUMN curtailment_mw NUMERIC(10,2) DEFAULT 0;
                END IF;

                -- Add excess column to uc_net_demand table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_net_demand'
                               AND column_name = 'excess_mw') THEN
                    ALTER TABLE simulations.uc_net_demand ADD COLUMN excess_mw NUMERIC(10,2) DEFAULT 0;
                END IF;

                -- Add shortage (load shedding) columns to uc_results summary table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'total_shortage_mwh') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN total_shortage_mwh NUMERIC(12,2) DEFAULT 0;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'shortage_cost') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN shortage_cost NUMERIC(15,2) DEFAULT 0;
                END IF;

                -- Add shortage column to uc_net_demand table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_net_demand'
                               AND column_name = 'shortage_mw') THEN
                    ALTER TABLE simulations.uc_net_demand ADD COLUMN shortage_mw NUMERIC(10,2) DEFAULT 0;
                END IF;
            END \$\$;
        """)
    end

    @info "UC results tables schema verified/created"
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

        # Add more indexes here as needed:
        # - generation_forecasts_for_wind_and_solar (zone, date)
        # - day_ahead_total_load_forecast (zone, date)
        # - offered_transfer_capacities_implicit (zone pairs, date)
    end

    @info "Indexes ensured successfully"
end

"""
    get_actual_day_ahead_prices(bidding_zone::String, day::Date) -> Dict{String, Float64}

Fetch actual ENTSO-E day-ahead prices from `entsoe.energy_prices` and return them
in the same `Dict{String, Float64}` format as simulated prices (timeslot "YYYYMMDD-HHMM" => price).

Returns an empty Dict if no data is found.
"""
function get_actual_day_ahead_prices(bidding_zone::String, day::Dates.Date)::Dict{String, Float64}
    query = """
    SELECT date_time_utc, resolution_code, price_currency_mwh
    FROM entsoe.energy_prices
    WHERE map_code = \$1
      AND DATE(date_time_utc) = \$2
    ORDER BY date_time_utc
    """

    df = sql2df_with_retry(query, [bidding_zone, day])

    if nrow(df) == 0
        @warn "No actual day-ahead prices found for $bidding_zone on $day"
        return Dict{String, Float64}()
    end

    prices = Dict{String, Float64}()
    for row in eachrow(df)
        dt = row.date_time_utc
        timeslot = Dates.format(DateTime(dt), dateformat"yyyymmdd-HHMM")
        prices[timeslot] = Float64(row.price_currency_mwh)
    end

    return prices
end
