#!/usr/bin/env bash
# DB scenario tests on a throwaway database (app_test): schema + functions + synced config,
# then db/tests/*.sql, each in its own rolled-back transaction as the n8n role (grants are tested too).
set -euo pipefail
cd "$(dirname "$0")/.."
T=app_test
su() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -U postgres "$@"; }
su -d postgres -c "set client_min_messages = warning" -c "drop database if exists $T with (force)" -c "create database $T owner app_owner" >/dev/null
su -d $T -c 'create extension pgcrypto' -c 'create extension pg_trgm' -c 'create extension vector' \
  -c "revoke all on database $T from public" -c "revoke create on schema public from public" \
  -c "grant connect on database $T to app_n8n, app_web" >/dev/null  # same database privileges as db/init (no TEMP for app roles)
DB=$T ./scripts/db-migrate.sh >/dev/null
DB=$T ./scripts/sync-config.sh >/dev/null
su -d $T -c 'set role app_owner' -c 'set client_min_messages = warning' -f /db/tests/00_helpers.sql >/dev/null
fail=0
for f in db/tests/[1-9]*.sql; do
  [ -n "${1:-}" ] && [[ "$f" != *"$1"* ]] && continue
  if out=$(su -d $T -c 'set client_min_messages = warning' -f "/$f" 2>&1); then
    echo "ok    $f"
  else
    echo "FAIL  $f"; echo "$out" | grep -v '^$' | tail -8 | sed 's/^/      /'; fail=1
  fi
done
exit $fail
