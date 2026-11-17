#!/usr/bin/env bash
# Blackout guard for rescore-hourly.yml (#431 C2). Exit 0 = safe to write now; exit 1 = not.
#
#   bin/rescore_guard.sh [MARGIN_MIN]
#
# Refuses inside 06:15-08:30 UTC (daily-forecast) and 10:30-12:15 UTC (the 10:40 server
# cron), and within MARGIN_MIN minutes BEFORE either window (default 0), so a write that
# starts now cannot run into it. Also refuses while daily-forecast.yml or
# publish-web-data.yml has a queued/active run (needs GH_TOKEN and REPO; an API failure
# counts as active, i.e. fails closed). GUARD_NOW_UTC=HHMM overrides the clock (tests).
set -euo pipefail
margin=${1:-0}
[[ "$margin" =~ ^[0-9]+$ ]] || { echo "::error::bad margin '$margin'"; exit 1; }
hhmm=${GUARD_NOW_UTC:-$(date -u +%H%M)}
now=$((10#${hhmm:0:2} * 60 + 10#${hhmm:2:2}))
for w in "375 510 06:15-08:30" "630 735 10:30-12:15"; do
  set -- $w
  if [ "$now" -ge $(($1 - margin)) ] && [ "$now" -lt "$2" ]; then
    echo "::error::blackout: ${hhmm} UTC is inside or within ${margin} min of $3 UTC; suggested slot ~13:30 UTC"
    exit 1
  fi
done
if [ -n "${GH_TOKEN:-}" ] && [ -n "${REPO:-}" ]; then
  for wf in daily-forecast.yml publish-web-data.yml; do
    api="https://api.github.com/repos/$REPO/actions/workflows/$wf/runs"
    for st in queued in_progress waiting pending requested; do
      c=$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
            "$api?status=$st&per_page=1" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_count'])") || c=1
      if [ "$c" -ne 0 ]; then
        echo "::error::$wf has a $st run (or the API check failed); not writing now"
        exit 1
      fi
    done
  done
elif [ -z "${GUARD_NOW_UTC:-}" ]; then
  echo "::error::GH_TOKEN/REPO unset: cannot check active workflow runs"; exit 1
fi
echo "guard ok at ${hhmm} UTC (margin ${margin} min)"
