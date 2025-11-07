using LibPQ
using ConcurrentUtilities: ConcurrentUtilities, Pools
using Dates

const poolsize = 5
cnxpool = Pools.Pool{LibPQ.Connection}(poolsize)

function cnxisok(cnx::LibPQ.Connection)
    return LibPQ.status(cnx) == LibPQ.libpq_c.CONNECTION_OK
end

function newconnection()
    cnx = LibPQ.Connection(
        get(ENV, "ENERGY_CONN_STR", "")
    )
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
            bidding_zone VARCHAR(10) NOT NULL,
            contract_type VARCHAR(50) NOT NULL,
            price_eur_mwh NUMERIC(10,2) NOT NULL,
            currency VARCHAR(3) NOT NULL,
            update_time_utc TIMESTAMP NOT NULL,
            code_version INTEGER NOT NULL,
            order_method VARCHAR(20) NOT NULL,
            UNIQUE(date_time_utc, bidding_zone, contract_type, order_method)
        )
        """

        LibPQ.execute(cnx, create_table_sql)

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
    end

    @info "Energy prices table schema verified/created"
end

"""
    save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol; batch_size::Int=100, create_schema::Bool=true)

Save energy prices to the database in the simulations.energy_prices table.
Creates the schema and table if they don't exist (when create_schema=true).
Assumes connection is already to the 'energy' database.

# Arguments
- `prices`: Dictionary with timeslot keys ("YYYYMMDD-HHMM") and price values in EUR/MWh
- `bidding_zone`: Bidding zone code (e.g., "GR", "AL") 
- `day`: Date of the prices
- `order_method`: Method used (:uc_based or :alternative)
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
- `code_version`: Version code, set to 1 for now
- `order_method`: Method used to generate prices
"""
function save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol; batch_size::Int=100, create_schema::Bool=true)
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
    records = Vector{Tuple{DateTime,String,String,String,Float64,String,DateTime,Int,String}}()
    sizehint!(records, length(prices))  # Pre-allocate for efficiency
    update_time = now(UTC)
    order_method_str = string(order_method)  # Convert once

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
                update_time,
                1,  # code_version
                order_method_str
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

    # Insert in batches
    total_inserted = 0

    sql = """
    INSERT INTO simulations.energy_prices 
    (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, update_time_utc, code_version, order_method)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9)
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

    @info "Successfully saved $total_inserted energy price records for $bidding_zone on $day using $order_method method"
    return total_inserted
end
