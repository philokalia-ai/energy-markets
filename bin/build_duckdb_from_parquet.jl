# Materialize a runtime .duckdb from the canonical parquet directory produced by
# bin/build_duckdb_extract.jl. Parquet is the engine-version-durable published
# format; this script rebuilds a bit-identical DuckDB database from it on any
# machine, with NO Postgres access.
#
# Usage:
#   PARQUET_DIR=data/public/euphemia-data-v1 \
#     OUT=data/extracts/euphemia-public.duckdb \
#     julia --project=. bin/build_duckdb_from_parquet.jl
#
# Options (env):
#   VERIFY_CHECKSUMS=true   verify SHA256SUMS before materializing (default true)
#   VERIFY_AGAINST=<path>   after building, compare row counts + per-table content
#                           hash against a reference .duckdb (e.g. the one the
#                           builder produced directly from Postgres). Non-zero
#                           exit if any table differs.
#
# This script uses only DuckDB + stdlib — it does NOT load Euphemia/Postgres, so
# a reproducer can run it with nothing but this repo and the parquet dir.

using DuckDB
using SHA
using Printf
import DuckDB.DBInterface as DBInterface

const PARQUET_DIR = get(ENV, "PARQUET_DIR", "data/public/euphemia-data-v1")
const OUT = get(ENV, "OUT", "data/extracts/euphemia-public.duckdb")
const VERIFY_CHECKSUMS = lowercase(get(ENV, "VERIFY_CHECKSUMS", "true")) == "true"
const VERIFY_AGAINST = get(ENV, "VERIFY_AGAINST", "")
# Disk-frugal parity: compare the parquet dir directly against a reference
# .duckdb (read_parquet vs reference table fingerprints) WITHOUT materializing a
# second .duckdb. Proves parquet ≡ the Postgres-built DuckDB with no extra copy.
const PARITY_ONLY = lowercase(get(ENV, "PARITY_ONLY", "false")) == "true"

# Parse "schema.table.parquet" -> ("schema", "table").
function parse_fqtn(fname::String)
    base = replace(fname, r"\.parquet$" => "")
    parts = split(base, ".")
    length(parts) == 2 || error("Unexpected parquet filename (want schema.table.parquet): $fname")
    return String(parts[1]), String(parts[2])
end

# Order-independent per-table content fingerprint: count + per-column sum of
# row-hashes (commutative, so row order is irrelevant). Returned as a String.
function table_fingerprint(con, schema, table)
    df = DataFrame(DBInterface.execute(con,
        "SELECT count(*) AS n, sum(hash(COLUMNS(*)))::VARCHAR AS h FROM \"$schema\".\"$table\""))
    n = df.n[1]
    hashes = [string(df[1, c]) for c in names(df) if c != "n"]
    return n, join(hashes, "|")
end

using DataFrames

# Same fingerprint, computed from a parquet file directly (no table needed).
function parquet_fingerprint(con, path)
    df = DataFrame(DBInterface.execute(con,
        "SELECT count(*) AS n, sum(hash(COLUMNS(*)))::VARCHAR AS h FROM read_parquet('$path')"))
    n = df.n[1]
    hashes = [string(df[1, c]) for c in names(df) if c != "n"]
    return n, join(hashes, "|")
end

# Compare a parquet dir against a reference .duckdb without building a 2nd file.
function parity_only(dir::String, reference::String)
    println("Parity: parquet dir vs reference DuckDB (no second .duckdb materialized)")
    println("  parquet   : ", dir)
    println("  reference : ", reference)
    isfile(reference) || error("Reference DuckDB not found: $reference")
    VERIFY_CHECKSUMS && (println("Verifying checksums..."); verify_checksums(dir) || return 1)
    db = DuckDB.DB(reference); con = DBInterface.connect(db)
    files = sort(filter(f -> endswith(f, ".parquet"), readdir(dir)))
    allok = true
    for f in files
        schema, table = parse_fqtn(f)
        nP, hP = parquet_fingerprint(con, joinpath(dir, f))
        nR, hR = table_fingerprint(con, schema, table)
        same = nP == nR && hP == hR
        allok &= same
        @printf("  %-58s %s  (parquet=%d ref=%d)\n",
                "$schema.$table", same ? "MATCH" : "DIFFER", nP, nR)
    end
    DBInterface.close!(con); close(db)
    if allok
        println("\n✅ Parquet dir is content-identical to the Postgres-built DuckDB (transitively, so is any DuckDB materialized from it).")
        return 0
    else
        println("\n❌ Content mismatch between parquet dir and reference DuckDB.")
        return 1
    end
end

function verify_checksums(dir::String)
    sums = joinpath(dir, "SHA256SUMS")
    isfile(sums) || (println("  (no SHA256SUMS found — skipping checksum verification)"); return true)
    ok = true
    for line in eachline(sums)
        isempty(strip(line)) && continue
        parts = split(line, "  "; limit=2)
        length(parts) == 2 || continue
        expected, rel = parts[1], parts[2]
        path = joinpath(dir, rel)
        if !isfile(path)
            @printf("  MISSING  %s\n", rel); ok = false; continue
        end
        got = open(f -> bytes2hex(sha256(f)), path)
        if got != expected
            @printf("  MISMATCH %s\n", rel); ok = false
        end
    end
    println(ok ? "  checksums OK" : "  CHECKSUM VERIFICATION FAILED")
    return ok
end

function main()
    if PARITY_ONLY
        isempty(VERIFY_AGAINST) && error("PARITY_ONLY=true requires VERIFY_AGAINST=<reference.duckdb>")
        return parity_only(PARQUET_DIR, VERIFY_AGAINST)
    end
    t0 = time()
    println("Materializing DuckDB from parquet")
    println("  parquet : ", PARQUET_DIR)
    println("  duckdb  : ", OUT)
    isdir(PARQUET_DIR) || error("Parquet dir not found: $PARQUET_DIR")

    if VERIFY_CHECKSUMS
        println("Verifying checksums...")
        verify_checksums(PARQUET_DIR) || return 1
    end

    files = sort(filter(f -> endswith(f, ".parquet"), readdir(PARQUET_DIR)))
    isempty(files) && error("No .parquet files in $PARQUET_DIR")

    mkpath(dirname(OUT))
    isfile(OUT) && (println("Removing existing $OUT"); rm(OUT))
    db = DuckDB.DB(OUT); con = DBInterface.connect(db)

    schemas = unique(parse_fqtn(f)[1] for f in files)
    for s in schemas
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS \"$s\"")
    end

    built = Tuple{String,String}[]
    for f in files
        schema, table = parse_fqtn(f)
        pq = joinpath(PARQUET_DIR, f)
        DBInterface.execute(con,
            "CREATE TABLE \"$schema\".\"$table\" AS SELECT * FROM read_parquet('$pq')")
        n = DataFrame(DBInterface.execute(con,
            "SELECT count(*) AS c FROM \"$schema\".\"$table\"")).c[1]
        @printf("  %-58s %12d rows\n", "$schema.$table", n)
        push!(built, (schema, table))
    end

    DBInterface.close!(con); close(db)
    @printf("Built %s in %.0f s\n", OUT, time() - t0)

    # --- Optional: verify against a reference .duckdb (e.g. Postgres-built) ---
    if !isempty(VERIFY_AGAINST)
        println("\nVerifying content against reference: ", VERIFY_AGAINST)
        isfile(VERIFY_AGAINST) || error("Reference DuckDB not found: $VERIFY_AGAINST")
        dbA = DuckDB.DB(OUT); conA = DBInterface.connect(dbA)
        dbB = DuckDB.DB(VERIFY_AGAINST); conB = DBInterface.connect(dbB)
        allok = true
        for (schema, table) in built
            nA, hA = table_fingerprint(conA, schema, table)
            nB, hB = table_fingerprint(conB, schema, table)
            same = nA == nB && hA == hB
            allok &= same
            @printf("  %-58s %s  (parquet=%d ref=%d)\n",
                    "$schema.$table", same ? "MATCH" : "DIFFER", nA, nB)
        end
        DBInterface.close!(conA); close(dbA)
        DBInterface.close!(conB); close(dbB)
        if allok
            println("\n✅ Parquet-built DuckDB is content-identical to the reference.")
        else
            println("\n❌ Content mismatch — parquet-built DuckDB differs from the reference.")
            return 1
        end
    end
    return 0
end

exit(main())
