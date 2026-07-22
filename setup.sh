#!/usr/bin/env bash
# One-command setup for the Euphemia counterfactual — downloads the public
# data, instantiates Julia deps, verifies the install, and tells you what
# optional pieces are worth configuring. Safe to re-run (idempotent).
#
#   ./setup.sh             # frozen, checksummed artifact (recommended, ~623 MB)
#   ./setup.sh --live      # daily-refreshed living extract instead (~3 GB)
#   ./setup.sh --no-data   # deps + checks only, skip data download
set -euo pipefail
cd "$(dirname "$0")"

DATA_URL="https://data.philokalia.ai"
MODE="frozen"
case "${1:-}" in
    --live) MODE="live" ;;
    --no-data) MODE="none" ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    "") ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ✅ %s\n' "$*"; }
warn() { printf '   ⚠️  %s\n' "$*"; }

# ---------------------------------------------------------------- 1. Julia
say "Julia"
if ! command -v julia >/dev/null; then
    echo "Julia not found. Install via juliaup (recommended):" >&2
    echo "  curl -fsSL https://install.julialang.org | sh" >&2
    exit 1
fi
ok "$(julia --version)"

say "Julia package environment (first run takes a few minutes)"
julia --project=. -e 'using Pkg; Pkg.instantiate()'
ok "Project.toml environment instantiated"

# ---------------------------------------------------------------- 2. Data
if [ "$MODE" = "frozen" ]; then
    say "Public data — frozen artifact euphemia-data-v1.1 (39 zones, 2023-01-01…2026-06-30)"
    mkdir -p data/public data/extracts
    TARBALL=data/public/euphemia-data-v1.1.tar.zst
    if [ ! -d data/public/euphemia-data-v1.1 ]; then
        [ -f "$TARBALL" ] || curl -L --progress-bar -o "$TARBALL" \
            "$DATA_URL/euphemia-data-v1.1.tar.zst"
        EXPECT=$(curl -sL "$DATA_URL/euphemia-data-v1.1.tar.zst.sha256" | awk '{print $1}')
        GOT=$(sha256sum "$TARBALL" | awk '{print $1}')
        [ "$EXPECT" = "$GOT" ] || { echo "sha256 MISMATCH for $TARBALL" >&2; exit 1; }
        ok "tarball sha256 verified ($GOT)"
        tar --zstd -xf "$TARBALL" -C data/public
        (cd data/public/euphemia-data-v1.1 && sha256sum --quiet -c SHA256SUMS)
        ok "per-file SHA256SUMS verified"
    else
        ok "data/public/euphemia-data-v1.1 already present"
    fi
    if [ ! -f data/extracts/euphemia-public.duckdb ]; then
        say "Materializing the runtime DuckDB (~2.6 GB, several minutes)"
        PARQUET_DIR=data/public/euphemia-data-v1.1 \
            OUT=data/extracts/euphemia-public.duckdb \
            julia --project=. bin/build_duckdb_from_parquet.jl
    fi
    ok "runtime extract: data/extracts/euphemia-public.duckdb (auto-detected by the library)"
elif [ "$MODE" = "live" ]; then
    say "Public data — living extract (refreshed daily 02:00 UTC)"
    mkdir -p data/extracts
    curl -L --progress-bar -o data/extracts/euphemia-live.duckdb \
        "$DATA_URL/euphemia-live.duckdb"
    EXPECT=$(curl -sL "$DATA_URL/euphemia-live.duckdb.sha256" | awk '{print $1}')
    GOT=$(sha256sum data/extracts/euphemia-live.duckdb | awk '{print $1}')
    [ "$EXPECT" = "$GOT" ] || { echo "sha256 MISMATCH (mid-refresh download? retry)" >&2; exit 1; }
    ok "living extract verified; set EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-live.duckdb"
else
    warn "skipping data download (--no-data)"
fi

# ---------------------------------------------------------------- 3. Smoke test
if [ "$MODE" = "frozen" ]; then
    say "Smoke test — load the library + read one day from the extract"
    julia --project=. -e '
        using Euphemia, Dates
        df = Euphemia.sql2df_with_retry(
            "SELECT COUNT(*) AS n FROM entsoe.energy_prices WHERE map_code = \$1
             AND date_time_utc >= \$2::date::timestamp
             AND date_time_utc <  (\$2::date + 1)::timestamp", ["GR", Date(2026,1,26)])
        n = df.n[1]
        n > 0 || error("extract returned no rows")
        println("   ✅ Euphemia loads; extract answers (GR 2026-01-26: $n price rows)")'
fi

# ---------------------------------------------------------------- 4. What else
say "Optional — worth setting up"
if julia --project=. -e 'using Gurobi' >/dev/null 2>&1 && [ -n "${GRB_LICENSE_FILE:-$([ -f "$HOME/gurobi.lic" ] && echo y)}" ]; then
    ok "Gurobi available — full 39-zone multi-zone clears run in ~10 s/day"
else
    warn "Gurobi not configured: single-zone runs fine on the bundled HiGHS;"
    echo  "      the 39-zone multi-zone MILP effectively needs Gurobi (free academic"
    echo  "      licenses: https://www.gurobi.com/academia/ — put the license at ~/gurobi.lic)"
fi
[ -f .env ] && ok ".env present" || {
    warn "no .env — only needed by maintainers with live-Postgres access"
    echo  "      (ENERGY_CONN_STR=postgresql://… enables the live-DB backend & writers)"; }

say "Ready — try:"
cat <<'EOF'
   julia --project=. bin/reproduce.jl --quick        # reproduce 5 days, diff vs committed metrics
   julia --project=. test/scripts/eval_pricing_accuracy.jl merit_order "2026-01-26" GR
   # scenarios: docs/scenario-api.md  (Claude Code users: the "scenarios" skill)
EOF
