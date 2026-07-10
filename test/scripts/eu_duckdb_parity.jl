# DuckDB-vs-Postgres parity gate for the 39-zone EU multi-zone merit-order clear.
#
# Runs the SAME code against the live Postgres DB and against a self-contained
# DuckDB extract, then compares zone prices. Prices match to floating-point
# precision (the residual is last-ULP non-determinism in SQL SUM/AVG/percentile
# aggregates, which reaches the price only through a marginal tranche's scarcity
# factor — see CLAUDE.md "Multi-zone under DuckDB").
#
# Prereqs:
#   1. Live Postgres (.env / ENERGY_CONN_STR).
#   2. A 39-zone EU extract, e.g.:
#        ZONES="AT,BE,...,CH" START_DATE=2026-04-01 END_DATE=2026-04-05 \
#          AGEN_BACK_DAYS=90 OUT=data/extracts/euphemia_2026_eu.duckdb \
#          julia --project=. bin/build_duckdb_extract.jl
#
# Usage:
#   julia --project=. test/scripts/eu_duckdb_parity.jl [duckdb_path] [YYYY-MM-DD]

using Euphemia, Dates, Printf

const DUCK = length(ARGS) >= 1 ? ARGS[1] : "data/extracts/euphemia_2026_eu.duckdb"
const DAY  = length(ARGS) >= 2 ? Date(ARGS[2]) : Date(2026, 4, 3)
const EU39 = ["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU",
              "LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS",
              "SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH",
              "IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]

function clear_all_caches!()
    Euphemia.clear_generator_caches!()
    empty!(Euphemia.TTF_PRICE_CACHE)
    empty!(Euphemia.EUA_PRICE_CACHE)
end

function clear(day)
    res = Euphemia.run_multi_zone_market_clearing(day;
        zones=EU39, order_method=:merit_order, save_to_db=false,
        enrich_network=true, apply_zone_profiles=true, passes=2, optimizer="gurobi")
    return res.market_prices
end

println("=== Postgres clear ===")
Euphemia.configure_data_store!(backend=:postgres)
clear_all_caches!()
pg = clear(DAY)

println("\n=== DuckDB clear ($DUCK) ===")
Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=DUCK)
clear_all_caches!()
dk = clear(DAY)
Euphemia.configure_data_store!(backend=:postgres)

# Compare (wrapped in a function so loop-var scoping is unambiguous)
function compare(pg, dk)
    maxdiff = 0.0; nrows = 0; nbitexact = 0; argz = ""; argt = ""
    for z in sort(collect(keys(pg)))
        haskey(dk, z) || (println("MISSING in DuckDB: $z"); continue)
        for ts in sort(collect(keys(pg[z])))
            a = pg[z][ts]; b = get(dk[z], ts, NaN)
            nrows += 1
            reinterpret(UInt64, Float64(a)) == reinterpret(UInt64, Float64(b)) && (nbitexact += 1)
            d = abs(a - b)
            if d > maxdiff
                maxdiff = d; argz = z; argt = ts
            end
        end
    end
    return (; maxdiff, nrows, nbitexact, argz, argt)
end

r = compare(pg, dk)
@printf("\nrows=%d  bit-identical=%d (%.1f%%)  max|Δprice|=%.3e €/MWh  at %s %s\n",
        r.nrows, r.nbitexact, 100*r.nbitexact/r.nrows, r.maxdiff, r.argz, r.argt)
ok = r.maxdiff <= 1e-9
println(ok ? "PARITY OK (≤1e-9 €/MWh)" : "PARITY FAIL (>1e-9 €/MWh — investigate a real data difference)")
exit(ok ? 0 : 1)
