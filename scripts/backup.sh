#!/usr/bin/env bash
# Nightly backup (host cron, e.g. `15 3 * * * /srv/acf/scripts/backup.sh`): pg_dump of the app and n8n databases into
# backups/<UTC date>/, a restore check of the app dump into a scratch database, upload to object storage, 14 days kept
# locally. Off-site target: BACKUP_S3_ENDPOINT / BACKUP_S3_BUCKET / BACKUP_S3_ACCESS_KEY / BACKUP_S3_SECRET_KEY in .env
# (default: the local S3 bucket, prefix backups/). N8N_ENCRYPTION_KEY is not in the dumps: keep it separately.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
d=backups/$(date -u +%F); mkdir -p "$d"
pg() { docker compose exec -T postgres "$@"; }
for db in app n8n; do
  pg pg_dump -U postgres -Fc "$db" > "$d/$db.dump"
done
# restore check: the dump must load and contain the core tables
pg psql -q -X -U postgres -d postgres -c "set client_min_messages = warning" -c "drop database if exists restore_check with (force)" -c "create database restore_check" >/dev/null
pg pg_restore -U postgres -d restore_check --no-owner --no-privileges < "$d/app.dump" 2>/dev/null || true
n=$(pg psql -X -tA -U postgres -d restore_check -c "select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('materials', 'variants', 'jobs', 'audit_log')")
pg psql -q -X -U postgres -d postgres -c "drop database restore_check with (force)" >/dev/null
[ "$n" = 4 ] || { echo "backup: restore check failed ($d/app.dump)" >&2; exit 1; }
endpoint=${BACKUP_S3_ENDPOINT:-http://127.0.0.1:9000}; bucket=${BACKUP_S3_BUCKET:-${S3_BUCKET:-acf}}
for f in "$d"/*.dump; do
  curl -fsS -X PUT --aws-sigv4 "aws:amz:${BACKUP_S3_REGION:-us-east-1}:s3" \
    --user "${BACKUP_S3_ACCESS_KEY:-$S3_ACCESS_KEY}:${BACKUP_S3_SECRET_KEY:-$S3_SECRET_KEY}" \
    -T "$f" "$endpoint/$bucket/backups/$(basename "$d")/$(basename "$f")"
done
find backups -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
echo "backup: $d ok ($(du -sh "$d" | cut -f1))"
