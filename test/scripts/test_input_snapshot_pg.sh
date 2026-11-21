#!/bin/bash
# Local synthetic PostgreSQL only: Unix socket, TCP disabled, never a user's DB.
set -euo pipefail
pgbin=${PG_TEST_BIN:-/usr/lib/postgresql/16/bin}
root=$(mktemp -d /tmp/retro-input-pg.XXXXXX)
export RETRO_TEST_PG_SOCKET="$root/socket"
mkdir "$RETRO_TEST_PG_SOCKET"
cleanup() {
  "$pgbin/pg_ctl" -D "$root/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$root"
}
trap cleanup EXIT
"$pgbin/initdb" -D "$root/data" -U snapshot_test -A trust --no-locale >/dev/null
"$pgbin/pg_ctl" -D "$root/data" -l "$root/server.log" -o "-k $RETRO_TEST_PG_SOCKET -p 55464 -c listen_addresses='' -c max_connections=20" start >/dev/null
"${JULIA_TEST_LAUNCHER:-julia}" --project=. test/scripts/test_input_snapshot_pg.jl
