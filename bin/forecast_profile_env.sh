#!/bin/bash
# forecast_profile_env.sh PROFILE [REQUIRE_JAO] — the daily forecast's environment for one run profile, printed as
# KEY=VALUE lines. One source for .github/workflows/daily-forecast.yml (the runs) and measure-duckdb-path.yml
# (the same-input Postgres-vs-DuckDB check of a profile), so the two cannot drift. FORCE_RERUN is the caller's.
#   pregate  06:30: weather (ex-ante) track, leads 2..7, before the gate (degraded pre-gate network)
#   lead1    ceres jao_pregate (08:55 / 09:55): weather lead 1 only, pre-gate, JAO-aware (REQUIRE_JAO)
#   morning  ceres 08:00: weather track, leads 1..7
#   entsoe   ceres 12:30 / 17:30 / 19:30: reference (entsoe) track, leads 1..7
set -eu
case "${1:-}" in
  pregate) printf '%s\n' MIN_LEAD_DAYS=2 MAX_LEAD_DAYS=7 INPUT_MODE=weather EUPHEMIA_FORECAST_PREGATE=true ;;
  lead1)   rj="${2:-false}"; [ "$rj" = true ] || rj=false
           printf '%s\n' MIN_LEAD_DAYS=1 MAX_LEAD_DAYS=1 INPUT_MODE=weather EUPHEMIA_FORECAST_PREGATE=true \
                         "EUPHEMIA_REQUIRE_JAO=$rj" ;;
  morning) printf '%s\n' MIN_LEAD_DAYS=1 MAX_LEAD_DAYS=7 INPUT_MODE=weather EUPHEMIA_FORECAST_PREGATE=false ;;
  entsoe)  printf '%s\n' MIN_LEAD_DAYS=1 MAX_LEAD_DAYS=7 INPUT_MODE=entsoe EUPHEMIA_FORECAST_PREGATE=false ;;
  *) echo "forecast_profile_env.sh: unknown profile '${1:-}' (pregate | lead1 | morning | entsoe)" >&2; exit 2 ;;
esac
