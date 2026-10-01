#!/usr/bin/env bash
# Forward-only migrations (db/migrations, applied once, tracked in schema_migrations)
# + repeatable code (db/functions: functions, views, grants, config seed — re-applied on every run).
# Runs inside the postgres container as app_owner (objects are owned by app_owner).
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-app}
q() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -U postgres -d "$DB" -c 'set role app_owner' -c 'set client_min_messages = warning' "$@"; }
q -c "create table if not exists schema_migrations (version text primary key, applied_at timestamptz not null default now())"
for f in db/migrations/*.sql; do
  v=$(basename "$f" .sql)
  if [ -z "$(q -tA -c "select 1 from schema_migrations where version = '$v'")" ]; then
    echo "migrate $v"
    q --single-transaction -f "/$f" -c "insert into schema_migrations (version) values ('$v')"
  fi
done
for f in db/functions/*.sql; do
  q --single-transaction -f "/$f"
done
echo "db: up to date ($DB)"
