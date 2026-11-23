# DuckDB's postgres extension: the ONE way Julia reaches Postgres (owner rule, 2026-11-23:
# "DuckDB between Postgres and Julia, always"). Two callers only: the fill step, which copies
# a run's input rows from Postgres into a run-local DuckDB (READ_ONLY attach), and the bulk
# transfer of results back (read-write attach). Rows move between the two engines inside
# DuckDB; they never pass through Julia row by row. Nothing else may attach Postgres.

"""
    duckdb_ext_dir() -> String

Where DuckDB extensions live: `EUPHEMIA_DUCKDB_EXT_DIR`, else `<first depot>/duckdb-ext`
(persistent on the runner, never `~/.duckdb`). The postgres extension is downloaded once
(extensions.duckdb.org, matching the linked libduckdb) and loaded offline afterwards.
"""
function duckdb_ext_dir()
    d = strip(get(ENV, "EUPHEMIA_DUCKDB_EXT_DIR", ""))
    return isempty(d) ? joinpath(first(DEPOT_PATH), "duckdb-ext") : String(d)
end

_sql_quote(s::AbstractString) = replace(String(s), "'" => "''")

"""
    load_postgres_extension!(con)

INSTALL (first use only) and LOAD DuckDB's postgres extension on connection `con`.
"""
function load_postgres_extension!(con)
    dir = duckdb_ext_dir()
    mkpath(dir)
    DBInterface.execute(con, "SET extension_directory = '$(_sql_quote(dir))'")
    DBInterface.execute(con, "INSTALL postgres")
    DBInterface.execute(con, "LOAD postgres")
    return nothing
end

"""
    attach_postgres!(con, conn_str; alias="pg", read_only=true)

Attach a Postgres database to DuckDB connection `con` under `alias` (libpq key=value string
or postgresql:// URI). `read_only=true` for the fill, `false` only for the results transfer.
The connection string is never logged.
"""
function attach_postgres!(con, conn_str::AbstractString; alias::AbstractString="pg",
                          read_only::Bool=true)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", alias) || error("attach_postgres!: bad alias $(repr(alias))")
    load_postgres_extension!(con)
    opts = read_only ? "TYPE postgres, READ_ONLY" : "TYPE postgres"
    DBInterface.execute(con, "ATTACH '$(_sql_quote(conn_str))' AS $alias ($opts)")
    return alias
end

"""
    detach_postgres!(con; alias="pg")
"""
detach_postgres!(con; alias::AbstractString="pg") =
    (DBInterface.execute(con, "DETACH DATABASE IF EXISTS $alias"); nothing)
