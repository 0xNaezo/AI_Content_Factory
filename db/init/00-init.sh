#!/bin/bash
# Runs once on first Postgres start (docker-entrypoint-initdb.d): roles, databases, extensions.
# Schema lives in db/migrations and db/functions (scripts/db-migrate.sh).
set -euo pipefail
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" \
  -v owner_pw="$APP_OWNER_PASSWORD" -v n8n_app_pw="$APP_N8N_PASSWORD" \
  -v web_pw="$APP_WEB_PASSWORD" -v n8n_db_pw="$N8N_DB_PASSWORD" <<'SQL'
CREATE ROLE app_owner LOGIN PASSWORD :'owner_pw';
CREATE ROLE app_n8n LOGIN PASSWORD :'n8n_app_pw';
CREATE ROLE app_web LOGIN PASSWORD :'web_pw';
CREATE ROLE n8n LOGIN PASSWORD :'n8n_db_pw';
CREATE DATABASE app OWNER app_owner;
CREATE DATABASE n8n OWNER n8n;
SQL
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d app <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
REVOKE ALL ON DATABASE app FROM PUBLIC;
GRANT CONNECT ON DATABASE app TO app_n8n, app_web;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
