#!/usr/bin/env julia
# =============================================================================
# Period-decomposition acceptance test (feat/15min-decompose)
#
# The coupled multi-zone MPCC has NO inter-temporal coupling, so solving each
# period independently must yield the SAME prices (the duals) as the monolithic
# solve, while making the 39-zone clear tractable for HiGHS (no license).
#
# Guard 1  (correctness): Gurobi monolithic == Gurobi decomposed, bit-exact
#          zonal/period PRICES (max|Δλ| ≤ 1e-9 €/MWh), at BOTH 60-min (24
#          periods) and 15-min (96 periods). Flows need NOT match (degenerate
#          primal / alternative optima), exactly as the repo documents for the
#          Postgres↔DuckDB residual.
# Guard 2  (payoff): with decomposition, optimizer="highs" solves the FULL
#          39-zone day — prices for all 39 zones, all periods — where monolithic
#          HiGHS finds no incumbent. Report MAE/max|Δ| vs Gurobi and wall time.
#
# Offline run:
#   EUPHEMIA_DATA_STORE=duckdb \
#   EUPHEMIA_DUCKDB_PATH=data/public/euphemia-public.duckdb \
#   GRB_LICENSE_FILE=/home/pgeorgakopoulos/gurobi.lic \
#     julia --project=. test/scripts/test_period_decomposition.jl
#
# Env knobs:
#   DAY=2026-04-03         market day
#   RES=both|60|15         which resolutions to test (default both)
#   SKIP_HIGHS=true        guard-1 only
#   SKIP_GUROBI=true       guard-2 only (no baseline to diff against)
# =============================================================================

using Euphemia, Dates, Printf

const DAY = Date(get(ENV, "DAY", "2026-04-03"))
const RES = get(ENV, "RES", "both")
const SKIP_HIGHS  = lowercase(get(ENV, "SKIP_HIGHS",  "false")) == "true"
const SKIP_GUROBI = lowercase(get(ENV, "SKIP_GUROBI", "false")) == "true"

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

resolutions = RES == "both" ? [60, 15] : [parse(Int, RES)]

# Max abs price difference across every (zone, period) present in BOTH results.
function price_stats(a::Dict{String,Dict{String,Float64}},
                     b::Dict{String,Dict{String,Float64}})
    maxabs = 0.0
    sumabs = 0.0
    n = 0
    missing_cells = 0
    for (z, pa) in a
        pb = get(b, z, nothing)
        pb === nothing && continue
        for (t, va) in pa
            haskey(pb, t) || (missing_cells += 1; continue)
            d = abs(va - pb[t])
            maxabs = max(maxabs, d)
            sumabs += d
            n += 1
        end
    end
    return (maxabs=maxabs, mae=(n == 0 ? NaN : sumabs / n), n=n, missing=missing_cells)
end

# Count fully-priced coverage: zones × periods present.
function coverage(p::Dict{String,Dict{String,Float64}}, zones, nperiods)
    zpriced = count(z -> haskey(p, z) && length(p[z]) == nperiods, zones)
    total_cells = sum(z -> haskey(p, z) ? length(p[z]) : 0, zones)
    return (zones_full=zpriced, cells=total_cells)
end

results = Dict{Int,Any}()

for res in resolutions
    nperiods = res == 60 ? 24 : 96
    println("\n" * "="^70)
    println("RESOLUTION $(res)-min  ($(nperiods) periods)  day=$DAY  zones=$(length(FOOTPRINT))")
    println("="^70)

    # Build the coupled EU-footprint book ONCE; both solves consume the same
    # book so guard-1 is a pure solve-equivalence comparison (no rebuild noise).
    println("\n📚 Building 39-zone enriched book ($(res)-min)...")
    tb = @elapsed book = Euphemia.mz_build_books(FOOTPRINT, DAY;
        enrich_network=true, apply_zone_profiles=true,
        clear_resolution_minutes=res)
    @printf("   book: %d orders, %d periods (%.1fs)\n",
            length(book.orders), length(book.periods), tb)

    entry = Dict{Symbol,Any}()

    # --- Gurobi monolithic + decomposed (guard 1) --------------------------
    if !SKIP_GUROBI
        println("\n🟦 Gurobi MONOLITHIC solve...")
        tm = @elapsed rmono = Euphemia.mz_solve_pass(book;
            optimizer="gurobi", decompose_periods=false)
        @printf("   status=%s  solve=%.1fs\n", rmono.status, tm)

        println("\n🟦 Gurobi DECOMPOSED solve...")
        td = @elapsed rdec = Euphemia.mz_solve_pass(book;
            optimizer="gurobi", decompose_periods=true)
        @printf("   status=%s  solve=%.1fs\n", rdec.status, td)

        st = price_stats(rmono.market_prices, rdec.market_prices)
        @printf("\n   GUARD 1  max|Δλ| = %.3e €/MWh   (mae=%.3e, n=%d, missing=%d)\n",
                st.maxabs, st.mae, st.n, st.missing)
        println("   GUARD 1 ", st.maxabs <= 1e-9 ? "PASS ✅" : "CHECK ⚠️",
                "  (bar: max|Δλ| ≤ 1e-9)")
        entry[:gurobi_mono] = rmono
        entry[:gurobi_dec]  = rdec
        entry[:guard1] = st
    end

    # --- HiGHS decomposed (guard 2) ----------------------------------------
    if !SKIP_HIGHS
        println("\n🟩 HiGHS DECOMPOSED solve (the open-solver option)...")
        th = @elapsed rhighs = Euphemia.mz_solve_pass(book;
            optimizer="highs", decompose_periods=true)
        @printf("   status=%s  wall=%.1fs\n", rhighs.status, th)
        cov = coverage(rhighs.market_prices, FOOTPRINT, nperiods)
        @printf("   coverage: %d/%d zones fully priced, %d/%d cells\n",
                cov.zones_full, length(FOOTPRINT), cov.cells, length(FOOTPRINT) * nperiods)
        solved_full = cov.zones_full == length(FOOTPRINT)
        println("   GUARD 2 ", solved_full ? "PASS ✅ — HiGHS solved the full 39-zone day" :
                                             "CHECK ⚠️ — some zones unpriced")
        entry[:highs_dec] = rhighs
        entry[:highs_time] = th
        entry[:highs_cov] = cov

        if haskey(entry, :gurobi_dec)
            st = price_stats(entry[:gurobi_dec].market_prices, rhighs.market_prices)
            @printf("   HiGHS vs Gurobi (decomp): mae=%.4f  max|Δ|=%.4f €/MWh  (n=%d)\n",
                    st.mae, st.maxabs, st.n)
            entry[:highs_vs_gurobi] = st
        end
    end

    results[res] = entry
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
println("\n" * "="^70)
println("SUMMARY")
println("="^70)
for res in resolutions
    e = results[res]
    print("  $(res)-min: ")
    if haskey(e, :guard1)
        @printf("guard1 max|Δλ|=%.2e ", e[:guard1].maxabs)
    end
    if haskey(e, :highs_cov)
        @printf(" | HiGHS %d/%d zones, %.1fs", e[:highs_cov].zones_full,
                length(FOOTPRINT), e[:highs_time])
        if haskey(e, :highs_vs_gurobi)
            @printf(", MAE vs Gurobi=%.4f", e[:highs_vs_gurobi].mae)
        end
    end
    println()
end
println("="^70)
