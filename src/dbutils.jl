using LibPQ
using ConcurrentUtilities: ConcurrentUtilities, Pools
using Dates
using DuckDB   # also brings DBInterface into scope

# ============================================================================
# Data store configuration (Postgres | DuckDB)
# ============================================================================
#
# The library normally reads from the live Postgres `energy` database. For
# offline / portable work it can instead read from a self-contained DuckDB
# extract (see `bin/build_duckdb_extract.jl`) that mirrors the same
# `schema.table` names, with every timestamp stored as naive UTC. The DuckDB
# backend is READ-ONLY in v1: every write path (`save_*`, `ensure_*`, UC
# caching) warns once and no-ops.
#
# Select the backend either programmatically with `configure_data_store!` or
# via the environment at module init:
#   EUPHEMIA_DATA_STORE=duckdb  EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb
# When DuckDB is selected via ENV the eager LibPQ pool is skipped entirely so
# the library works with no Postgres available at all.


# Split by concern; each file is `include`d in the original definition order,
# so the spliced code is line-for-line the pre-split dbutils.jl.
include("db/duckdb_store.jl")   # DuckDB backend: connection, dialect rewrite, results.duckdb writers
include("db/postgres_core.jl")  # code-version ledger, LibPQ pool, sql2df (+retry) dispatch
include("db/results_store.jl")  # simulations.* DDL, save_* writers, ensure_indexes
